import AppKit
import ApplicationServices

/// Owns only the application/element selected when dictation begins.
@MainActor
final class NativeIntegration {
    private var rememberedElement: AXUIElement?
    private var rememberedPID: pid_t?
    private var insertionInProgress = false
    private var pendingClipboardRestore: (snapshot: ClipboardSnapshot, changeCount: Int)?
    private var clipboardRestoreTask: Task<Void, Never>?

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func revealAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func captureFocusedApp(includeTextContext: Bool = false) -> FocusedAppContext? {
        rememberedElement = nil
        rememberedPID = nil
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated else { return nil }
        let pid = app.processIdentifier
        var selected: String?
        var surrounding: String?
        if isAccessibilityTrusted, let element = focusedElement(pid: pid), !isSecure(element) {
            rememberedElement = element
            rememberedPID = pid
            if includeTextContext {
                selected = stringAttribute(kAXSelectedTextAttribute, element: element).map { String($0.prefix(2_000)) }
                surrounding = stringAttribute(kAXValueAttribute, element: element).map { String($0.prefix(4_000)) }
            }
        }
        return FocusedAppContext(applicationName: app.localizedName ?? "Application",
                                 bundleIdentifier: app.bundleIdentifier,
                                 processIdentifier: pid,
                                 selectedText: selected,
                                 surroundingText: surrounding)
    }

    func copyText(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func insert(text: String, into context: FocusedAppContext?) async throws -> InsertionOutcome {
        // A previous paste may still be consuming the clipboard. Only a second
        // insertion waits for that cleanup; the first returns as soon as its event is posted.
        if let cleanup = clipboardRestoreTask { await cleanup.value }
        try Task.checkCancellation()
        guard !text.isEmpty else { return .copiedToClipboard }
        guard !insertionInProgress else { throw SottoError.message("Another insertion is still finishing. Try again in a moment.") }
        insertionInProgress = true
        let capturedElement = rememberedPID == context?.processIdentifier ? rememberedElement : nil
        defer { insertionInProgress = false }
        guard let context,
              context.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: context.processIdentifier),
              !app.isTerminated,
              context.bundleIdentifier == nil || app.bundleIdentifier == context.bundleIdentifier,
              isAccessibilityTrusted else {
            copyText(text)
            return .copiedToClipboard
        }

        // Prepare events before changing the clipboard. Cmd+V follows the target's native paste behavior.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw SottoError.message("macOS could not create a paste event. Copy the transcript and paste it manually.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        app.activate(options: [])
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier else {
            copyText(text)
            return .copiedToClipboard
        }
        if let element = capturedElement {
            // An AX focus setter can fail for an expired element or unsupported control.
            // Proceed only if the retained field is actually focused afterward.
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == context.processIdentifier else {
                copyText(text)
                return .copiedToClipboard
            }
            if let current = focusedElement(pid: pid), !CFEqual(current, element) {
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            guard let current = focusedElement(pid: pid), CFEqual(current, element) else {
                copyText(text)
                return .copiedToClipboard
            }
        }
        guard let currentElement = focusedElement(pid: context.processIdentifier),
              !isSecure(currentElement), isTextInput(currentElement) else {
            copyText(text)
            return .copiedToClipboard
        }
        let board = NSPasteboard.general
        // Promised or concealed content cannot be losslessly snapshotted. Leave paste as an explicit user action.
        guard let snapshot = clipboardSnapshot(board) else {
            copyText(text)
            return .copiedToClipboard
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier else {
            copyText(text)
            return .copiedToClipboard
        }
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            restore(snapshot, board: board)
            throw SottoError.message("The clipboard could not accept the transcript.")
        }
        let ourChangeCount = board.changeCount
        // No suspension between the final PID verification and the keyboard event.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier,
              let finalElement = focusedElement(pid: context.processIdentifier), CFEqual(finalElement, currentElement) else {
            if board.changeCount == ourChangeCount { restore(snapshot, board: board) }
            throw SottoError.message("The focused application changed before insertion. Try inserting again.")
        }
        pendingClipboardRestore = (snapshot, ourChangeCount)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // macOS provides no paste-completion acknowledgement. Give ordinary consumers time to read it.
        // Restore even on cancellation, and never overwrite clipboard changes made by another app/user.
        clipboardRestoreTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.restorePendingClipboard()
        }
        return .inserted
    }

    /// Call before normal application termination; an in-flight paste cannot await cleanup after exit.
    func restorePendingClipboard() {
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        let board = NSPasteboard.general
        if board.changeCount == pending.changeCount { restore(pending.snapshot, board: board) }
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    private func stringAttribute(_ name: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func isTextInput(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, element: element)
        if role == kAXTextFieldRole || role == kAXTextAreaRole { return true }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let value = editable as? Bool, value { return true }
        // Some custom editors expose text ranges without a standard text-field role.
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attributes = names as? [String] else { return false }
        return attributes.contains(kAXSelectedTextRangeAttribute)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        if stringAttribute(kAXSubroleAttribute, element: element) == kAXSecureTextFieldSubrole { return true }
        var protected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected) == .success,
           let value = protected as? Bool, value { return true }
        return false
    }

    private typealias ClipboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private func clipboardSnapshot(_ board: NSPasteboard) -> ClipboardSnapshot? {
        let initialChangeCount = board.changeCount
        var result: ClipboardSnapshot = []
        var totalBytes = 0
        for item in board.pasteboardItems ?? [] {
            if item.types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return nil }
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= 16 * 1_024 * 1_024 else { return nil }
                values[type] = data
            }
            result.append(values)
        }
        guard board.changeCount == initialChangeCount else { return nil }
        return result
    }

    private func restore(_ snapshot: ClipboardSnapshot, board: NSPasteboard) {
        let items = snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}
