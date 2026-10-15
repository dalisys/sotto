import Carbon
import AppKit
import Foundation

private let sottoHotKeySignature: OSType = 0x5354544F // STTO

@MainActor
final class ShortcutService {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var activeID: UInt32?
    private var carbonHeld = false
    private var handler: (@MainActor () -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var matcher: ShortcutChordMatcher?
    private var pending: [CGEvent] = []
    private var prefixTimer: Timer?
    private let replayMarker: Int64 = 0x5354544F4B4559

    func register(shortcut: SottoShortcut, handler: @escaping @MainActor () -> Void) throws {
        unregister()
        guard shortcut.isValid else { throw SottoError.message("Record at least one key for your shortcut.") }
        let ordinary = shortcut.keys.filter { !$0.isModifier }
        let standardModifiers: Set<UInt16> = [55, 56, 58, 59]
        if ordinary.count == 1, ordinary[0].code != 57,
           shortcut.keys.filter(\.isModifier).allSatisfy({ standardModifiers.contains($0.code) }) {
            var modifiers: UInt32 = 0
            for key in shortcut.keys {
                switch key.code {
                case 55: modifiers |= UInt32(cmdKey)
                case 56: modifiers |= UInt32(shiftKey)
                case 58: modifiers |= UInt32(optionKey)
                case 59: modifiers |= UInt32(controlKey)
                default: break
                }
            }
            try registerCarbon(code: ordinary[0].code, modifiers: modifiers, handler: handler)
        } else {
            try registerTap(shortcut: shortcut, handler: handler)
        }
    }

    private func registerCarbon(code: UInt16, modifiers: UInt32, handler: @escaping @MainActor () -> Void) throws {
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == sottoHotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon dispatches application events on the main thread. Queue rather than reenter recording state.
            let service = Unmanaged<ShortcutService>.fromOpaque(context).takeUnretainedValue()
            let eventID = identifier.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            Task { @MainActor [weak service] in
                guard let service, service.activeID == eventID else { return }
                if released { service.carbonHeld = false; return }
                guard !service.carbonHeld else { return }
                service.carbonHeld = true
                service.handler?()
            }
            return noErr
        }, 2, &eventTypes, context, &eventHandler)
        guard installStatus == noErr else {
            throw SottoError.message("The global shortcut handler could not be installed (macOS \(installStatus)).")
        }
        let registrationID = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        let status = RegisterEventHotKey(UInt32(code), modifiers,
                                         EventHotKeyID(signature: sottoHotKeySignature, id: registrationID),
                                         GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            unregister()
            throw SottoError.message("This shortcut is unavailable or already used by another app. Choose another shortcut in Settings (macOS \(status)).")
        }
        self.activeID = registrationID
        self.handler = handler
    }

    private func registerTap(shortcut: SottoShortcut, handler: @escaping @MainActor () -> Void) throws {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<ShortcutService>.fromOpaque(context).takeUnretainedValue().receive(proxy: proxy, type: type, event: event)
                }
            }, userInfo: context) else {
            throw SottoError.message("This custom chord needs keyboard access. Enable Sotto in System Settings → Privacy & Security → Accessibility (and Input Monitoring if macOS requests it), then click Retry shortcut.")
        }
        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let tapSource else { unregister(); throw SottoError.message("Could not start the custom shortcut listener.") }
        let held = Set((0..<128).compactMap { value -> UInt16? in
            let code = UInt16(value)
            return code != 57 && CGEventSource.keyState(.combinedSessionState, key: code) ? code : nil
        })
        matcher = ShortcutChordMatcher(target: shortcut.codes, initiallyPressed: held)
        self.handler = handler
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func receive(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            flushPending(proxy: proxy)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let target = matcher?.target { matcher = ShortcutChordMatcher(target: target) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == replayMarker { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let down: Bool
        if type == .flagsChanged {
            if code == 57 {
                // Caps Lock generates a toggle event instead of a normal down/up pair.
                let result = matcher?.process(code: code, down: true)
                _ = matcher?.process(code: code, down: false)
                if result?.fire == true { handler?() }
                return Unmanaged.passUnretained(event)
            }
            down = ShortcutKey.modifierIsDown(code: code, flags: event.flags, held: matcher?.pressed ?? [])
        } else { down = type == .keyDown }
        guard let decision = matcher?.process(code: code, down: down,
            repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) else { return Unmanaged.passUnretained(event) }
        if decision.flush { flushPending(proxy: proxy) }
        if decision.discard { pending.removeAll(); prefixTimer?.invalidate(); prefixTimer = nil }
        if decision.buffer, let copy = event.copy() {
            pending.append(copy)
            if prefixTimer == nil {
                prefixTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.matcher?.expirePrefix()
                        self?.flushPending(proxy: nil)
                    }
                }
            }
        }
        if decision.fire { handler?() }
        return decision.suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func flushPending(proxy: CGEventTapProxy?) {
        prefixTimer?.invalidate()
        prefixTimer = nil
        let events = pending
        pending.removeAll()
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            if let proxy { event.tapPostEvent(proxy) }
            else { event.post(tap: .cgSessionEventTap) }
        }
    }

    func unregister() {
        flushPending(proxy: nil)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        matcher = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        handler = nil
        activeID = nil
        carbonHeld = false
    }

    deinit {
        prefixTimer?.invalidate()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
