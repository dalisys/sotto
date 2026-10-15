import AppKit
import Combine
import SwiftUI

private final class DictationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A fixed native canvas prevents resizing the tracking region during hover.
/// Only the capsule inside this canvas animates; transparent space passes clicks through.
struct FloatingBarGeometry {
    static let canvas = NSSize(width: 728, height: 160)
    static let bottomInset: CGFloat = 72
    static let standby = NSSize(width: 60, height: 22)
    static let expandedIdle = NSSize(width: 188, height: 42)

    static func capsule(in frame: NSRect, size: NSSize, offset: NSPoint = .zero) -> NSRect {
        NSRect(x: frame.midX - size.width / 2 + offset.x, y: frame.minY + bottomInset + offset.y, width: size.width, height: size.height)
    }

    static func contains(_ point: NSPoint, capsule rect: NSRect) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = rect.height / 2
        let centerX = min(rect.maxX - radius, max(rect.minX + radius, point.x))
        return hypot(point.x - centerX, point.y - rect.midY) <= radius
    }

    static func frame(anchor: NSPoint, visible: NSRect) -> NSRect {
        // Clamp the visible standby capsule, not the transparent backing window.
        let x = min(visible.maxX - standby.width / 2 - 4, max(visible.minX + standby.width / 2 + 4, anchor.x))
        let y = min(visible.maxY - standby.height - 4, max(visible.minY + 4, anchor.y))
        return NSRect(x: x - canvas.width / 2, y: y - bottomInset, width: canvas.width, height: canvas.height)
    }

    static func offset(frame: NSRect, size: NSSize, visible: NSRect) -> NSPoint {
        let rect = capsule(in: frame, size: size)
        let x = min(visible.maxX - size.width - 4, max(visible.minX + 4, rect.minX))
        let y = min(visible.maxY - size.height - 4, max(visible.minY + 4, rect.minY))
        return NSPoint(x: x - rect.minX, y: y - rect.minY)
    }
}

struct FloatingBarDrag {
    let windowOrigin: NSPoint
    let pointerOrigin: NSPoint
    func origin(at pointer: NSPoint) -> NSPoint {
        NSPoint(x: windowOrigin.x + pointer.x - pointerOrigin.x,
                y: windowOrigin.y + pointer.y - pointerOrigin.y)
    }
}

struct FloatingBarHover {
    private(set) var hovered = false
    private var outsideSince: TimeInterval?

    mutating func update(inside: Bool, now: TimeInterval) -> Bool {
        if inside { hovered = true; outsideSince = nil }
        else if hovered {
            if outsideSince == nil { outsideSince = now }
            if now - (outsideSince ?? now) >= 0.18 { hovered = false; outsideSince = nil }
        }
        return hovered
    }
}

@MainActor
private final class FloatingBarState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var hovered = false
    @Published var success = false
    @Published var width: CGFloat = FloatingBarGeometry.standby.width
    @Published var height: CGFloat = FloatingBarGeometry.standby.height
    @Published var offset: NSPoint = .zero
}

private final class FloatingHostingView: NSHostingView<FloatingDictationBar> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Nonactivating controls leave the insertion target's keyboard focus intact.
@MainActor
final class FloatingDictationPanel {
    private let panel: DictationOverlayPanel
    private let model: AppModel
    private let state = FloatingBarState()
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var completionWork: DispatchWorkItem?
    private var awaitingSuccess = false
    private var showWhileIdle: Bool
    private var activeScreen: NSScreen?
    private var pointerTimer: Timer?
    private var hover = FloatingBarHover()
    private var dragging = false

    init(model: AppModel) {
        self.model = model
        showWhileIdle = model.settings.showFloatingBar
        panel = DictationOverlayPanel(
            contentRect: NSRect(origin: .zero, size: FloatingBarGeometry.canvas),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "Sotto floating dictation bar"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.setAccessibilityLabel("Sotto floating dictation bar")
        panel.contentView = FloatingHostingView(rootView: FloatingDictationBar(model: model, state: state,
            beginDrag: { [weak self] in self?.dragging = true },
            endDrag: { [weak self] in self?.finishDragging() }))
        state.phase = model.phase
        model.$phase.dropFirst().sink { [weak self] phase in self?.updatePhase(phase) }.store(in: &subscriptions)
        model.$settings.dropFirst().sink { [weak self] settings in
            guard let self else { return }
            let visibilityChanged = self.showWhileIdle != settings.showFloatingBar
            self.showWhileIdle = settings.showFloatingBar
            // Published settings arrive before AppModel stores the new value.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layout()
                if visibilityChanged { self.updatePointer() }
            }
        }.store(in: &subscriptions)
        model.$lastTiming.dropFirst().sink { [weak self] timing in
            guard let self, timing != nil else { return }
            if self.state.phase == .idle { self.showSuccess() }
            else { self.awaitingSuccess = true }
        }.store(in: &subscriptions)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.state.phase.isBusy, !self.dragging else { return }
                self.activeScreen = self.screenForPointer()
                self.layout()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeScreen = self?.screenForPointer()
                self?.layout()
            }
        })
        activeScreen = screenForPointer()
        layout()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePointer() }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePhase(_ phase: DictationPhase) {
        completionWork?.cancel()
        completionWork = nil
        if phase == .requestingPermission || phase == .recording {
            awaitingSuccess = false
            state.success = false
            if model.settings.floatingBarPosition == nil { activeScreen = screenForPointer() }
        }
        state.phase = phase
        if phase == .idle && awaitingSuccess { showSuccess() }
        else if phase != .idle { state.success = false }
        layout()
    }

    private func showSuccess() {
        completionWork?.cancel()
        state.success = true
        awaitingSuccess = false
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.success = false
                self.layout()
            }
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
        layout()
    }

    private func screenForPointer() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func updatePointer() {
        guard panel.isVisible, !dragging else { return }
        let pointer = NSEvent.mouseLocation
        let rect = FloatingBarGeometry.capsule(in: panel.frame, size: NSSize(width: state.width, height: state.height), offset: state.offset)
        let inside = FloatingBarGeometry.contains(pointer, capsule: rect)
        // The stable transparent canvas must never block another app's controls.
        panel.ignoresMouseEvents = !inside
        let hovered = hover.update(inside: inside, now: ProcessInfo.processInfo.systemUptime)
        if state.hovered != hovered {
            state.hovered = hovered
            layout()
        }
    }

    private func finishDragging() {
        dragging = false
        let capsule = FloatingBarGeometry.capsule(in: panel.frame, size: NSSize(width: state.width, height: state.height), offset: state.offset)
        model.settings.floatingBarPosition = FloatingBarPosition(x: capsule.midX, y: capsule.minY)
        layout()
    }

    private func layout() {
        guard !dragging else { return }
        guard state.phase.isBusy || state.phase == .failed || state.success || showWhileIdle else {
            panel.orderOut(nil)
            return
        }
        let size: NSSize
        if state.success { size = NSSize(width: 272, height: 60) }
        else {
            switch state.phase {
            case .recording: size = NSSize(width: 352, height: 68)
            case .requestingPermission, .transcribing, .inserting: size = NSSize(width: 308, height: 64)
            case .failed: size = NSSize(width: 288, height: 60)
            case .idle: size = state.hovered ? FloatingBarGeometry.expandedIdle : FloatingBarGeometry.standby
            }
        }
        let saved = model.settings.floatingBarPosition
        let anchor = saved.map { NSPoint(x: $0.x, y: $0.y) }
        let screen = anchor.flatMap { point in NSScreen.screens.first(where: { $0.frame.contains(point) }) }
            ?? activeScreen ?? screenForPointer()
        guard let visible = screen?.visibleFrame else { return }
        let position = anchor ?? NSPoint(x: visible.midX, y: visible.minY + 14)
        let frame = FloatingBarGeometry.frame(anchor: position, visible: visible)
        state.width = size.width
        state.height = size.height
        state.offset = FloatingBarGeometry.offset(frame: frame, size: size, visible: visible)
        // Native bounds never depend on hover or phase and have no competing animation.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--floating-bar-diagnostics"),
           ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            var report: [String: Any] = ["windowId": panel.windowNumber,
                "frame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height]]
            if let position = model.settings.floatingBarPosition { report["savedPosition"] = [position.x, position.y] }
            if let data = try? JSONSerialization.data(withJSONObject: report) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
        #endif
    }

    deinit {
        pointerTimer?.invalidate()
        completionWork?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

/// Follow explicit drag/up events. performDrag(with:) can return before release,
/// so saving immediately after it would restore the old anchor mid-drag.
private struct FloatingDragGrip: NSViewRepresentable {
    let beginDrag: () -> Void
    let endDrag: () -> Void
    func makeNSView(context: Context) -> GripView { GripView(beginDrag: beginDrag, endDrag: endDrag) }
    func updateNSView(_ view: GripView, context: Context) {}

    final class GripView: NSView {
        let beginDrag: () -> Void
        let endDrag: () -> Void
        private var drag: FloatingBarDrag?
        init(beginDrag: @escaping () -> Void, endDrag: @escaping () -> Void) {
            self.beginDrag = beginDrag
            self.endDrag = endDrag
            super.init(frame: .zero)
            toolTip = "Drag to move Sotto"
            setAccessibilityLabel("Move floating dictation bar")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            drag = FloatingBarDrag(windowOrigin: window.frame.origin, pointerOrigin: NSEvent.mouseLocation)
            beginDrag()
            NSCursor.closedHand.push()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let drag else { return }
            window?.setFrameOrigin(drag.origin(at: NSEvent.mouseLocation))
        }
        override func mouseUp(with event: NSEvent) {
            guard drag != nil else { return }
            if let drag { window?.setFrameOrigin(drag.origin(at: NSEvent.mouseLocation)) }
            drag = nil
            NSCursor.pop()
            endDrag()
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
            for x: CGFloat in [3, 7] {
                for y: CGFloat in [-4, 0, 4] {
                    NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 5, y: bounds.midY + y - 1, width: 2, height: 2)).fill()
                }
            }
        }
    }
}

private struct FloatingDictationBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: FloatingBarState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let beginDrag: () -> Void
    let endDrag: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                Capsule().fill(.white)
                Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                HStack(spacing: state.phase == .idle && !state.success ? 6 : 10) {
                    FloatingDragGrip(beginDrag: beginDrag, endDrag: endDrag)
                        .frame(width: 12)
                    content
                }
                .padding(.horizontal, state.phase == .idle && !state.success ? 8 : 14)
            }
            .frame(width: state.width, height: state.height)
            .contentShape(Capsule())
            .shadow(color: .black.opacity(0.13), radius: 8, y: 3)
            .padding(.bottom, FloatingBarGeometry.bottomInset)
            .offset(x: state.offset.x, y: -state.offset.y)
        }
        .frame(width: FloatingBarGeometry.canvas.width, height: FloatingBarGeometry.canvas.height, alignment: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: state.width)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: state.phase)
        .foregroundStyle(SottoTheme.ink)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private var content: some View {
        if state.success { successContent.transition(.opacity.combined(with: .scale(scale: 0.94))) }
        else {
            switch state.phase {
            case .idle: idleContent
            case .recording: recordingContent.transition(.opacity)
            case .requestingPermission, .transcribing, .inserting: processingContent.transition(.opacity)
            case .failed: errorContent.transition(.opacity)
            }
        }
    }

    private var idleContent: some View {
        Button(action: model.toggleRecording) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(SottoTheme.orange)
                if state.hovered {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start dictation").font(SottoTheme.font(11, weight: .semibold))
                        Text(model.settings.shortcut.compactTitle).font(SottoTheme.font(9)).foregroundStyle(SottoTheme.muted)
                    }.transition(.opacity)
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Start Sotto dictation")
            .help("Start dictation · \(model.settings.shortcut.title)")
    }

    private var recordingContent: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(SottoTheme.orange).frame(width: 5, height: 5)
                    Text(model.isOverlayPreview ? "Sample playback" : "Listening").font(SottoTheme.font(12, weight: .semibold))
                }
                Text(sottoDuration(model.elapsed)).font(SottoTheme.font(11)).monospacedDigit().foregroundStyle(SottoTheme.muted)
            }.frame(width: 72, alignment: .leading)
            FloatingAudioWave(level: model.audioLevel).frame(width: 90, height: 29)
            Spacer(minLength: 0)
            Button(action: model.toggleRecording) {
                Image(systemName: "stop.fill").font(.system(size: 12)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(SottoTheme.orange, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Stop and transcribe").help("Stop and transcribe")
            cancelButton
        }
    }

    private var processingContent: some View {
        HStack(spacing: 13) {
            ProcessingOrbit().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.phase.title).font(SottoTheme.font(12, weight: .semibold))
                Text(state.phase == .requestingPermission ? "Preparing microphone and model" : model.settings.backend.title)
                    .font(SottoTheme.font(10)).foregroundStyle(SottoTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            cancelButton
        }
    }

    private var successContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SottoTheme.orange).frame(width: 30, height: 30)
                .background(SottoTheme.orange.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isOverlayPreview ? "Sample preview complete" : "Dictation complete").font(SottoTheme.font(12, weight: .semibold))
                if let timing = model.lastTiming {
                    Text(String(format: "%.2f sec · %d words", timing.totalMilliseconds / 1_000, model.wordCount))
                        .font(SottoTheme.font(10)).foregroundStyle(SottoTheme.muted).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var errorContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(SottoTheme.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dictation needs attention").font(SottoTheme.font(12, weight: .semibold))
                Text("Open Sotto for details").font(SottoTheme.font(10)).foregroundStyle(SottoTheme.muted)
            }
            Spacer(minLength: 0)
            Button(action: model.dismissError) { Image(systemName: "xmark").frame(width: 24, height: 28) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss dictation error")
        }
    }

    private var cancelButton: some View {
        Button(action: model.cancelRecording) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(SottoTheme.muted).frame(width: 22, height: 30)
        }.buttonStyle(.plain).accessibilityLabel("Cancel dictation").help("Cancel dictation")
    }
}

/// Every bar comes from a real microphone measurement. No generated waveform.
private struct FloatingAudioWave: View {
    let level: Double
    @State private var samples = Array(repeating: 0.0, count: 15)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule().fill(SottoTheme.orange.opacity(0.35 + 0.65 * Double(index) / Double(samples.count)))
                    .frame(width: 3, height: max(3, samples[index] * 29))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.68), value: samples)
        .onChange(of: level) { _, value in
            samples.removeFirst()
            samples.append(min(1, max(0, value)))
        }
        .accessibilityLabel("Live microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

private struct ProcessingOrbit: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var body: some View {
        ZStack {
            Circle().stroke(SottoTheme.orange.opacity(0.12), lineWidth: 2)
            Circle().trim(from: 0.05, to: 0.72).stroke(
                AngularGradient(colors: [SottoTheme.orange.opacity(0.1), SottoTheme.orange], center: .center),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            ).rotationEffect(.degrees(rotating ? 360 : 0))
        }
        .onAppear { if !reduceMotion { rotating = true } }
        .animation(reduceMotion ? nil : .linear(duration: 1.15).repeatForever(autoreverses: false), value: rotating)
        .accessibilityLabel("Processing dictation")
    }
}
