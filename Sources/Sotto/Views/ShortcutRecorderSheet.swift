import AppKit
import SwiftUI

struct ShortcutRecorderSheet: View {
    let current: SottoShortcut
    let save: (SottoShortcut) -> Void
    let cancel: () -> Void
    @State private var captured: [ShortcutKey] = []
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Your dictation shortcut", systemImage: "keyboard")
                .font(SottoTheme.font(23, weight: .bold))
            Text("Press one key or hold your keys together. Release them to finish recording. You can use modifier keys on their own too.")
                .font(SottoTheme.font(13)).foregroundStyle(SottoTheme.muted)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(SottoTheme.surface)
                if captured.isEmpty {
                    Text("Press your keys…").font(SottoTheme.font(18)).foregroundStyle(SottoTheme.muted)
                } else {
                    HStack(spacing: 8) {
                        ForEach(captured) { key in
                            Text(key.name).font(SottoTheme.font(16, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(.white, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(SottoTheme.line))
                        }
                    }.padding(12)
                }
                ShortcutCaptureView { captured = $0 }.id(generation).opacity(0.01)
            }.frame(height: 94)
            Text("Current: \(current.title)").font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
            Text("Single letter or number shortcuts replace that key while Sotto is running. Function keys or modifier combinations keep ordinary typing available. Some macOS shortcuts are reserved.")
                .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
            HStack {
                Button("Cancel", action: cancel).buttonStyle(SottoButtonStyle())
                Button("Record again") { captured = []; generation = UUID() }.buttonStyle(SottoButtonStyle())
                Spacer()
                Button("Save shortcut") { save(SottoShortcut(keys: captured)) }
                    .buttonStyle(SottoButtonStyle(prominent: true))
                    .disabled(!SottoShortcut(keys: captured).isValid)
            }
        }.padding(30).frame(width: 540).foregroundStyle(SottoTheme.ink).background(.white)
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let captured: ([ShortcutKey]) -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView(captured: captured) }
    func updateNSView(_ view: CaptureView, context: Context) { view.captured = captured }

    final class CaptureView: NSView {
        var captured: ([ShortcutKey]) -> Void
        private var held: [UInt16: ShortcutKey] = [:]
        private var best: [ShortcutKey] = []
        private var finished = false
        init(captured: @escaping ([ShortcutKey]) -> Void) { self.captured = captured; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            update(event, down: true)
        }
        override func keyUp(with event: NSEvent) { update(event, down: false) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
        override func flagsChanged(with event: NSEvent) {
            if event.keyCode == 57 { update(event, down: true); update(event, down: false); return }
            let down = ShortcutKey.modifierIsDown(code: event.keyCode,
                flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)), held: Set(held.keys))
            update(event, down: down)
        }
        private func update(_ event: NSEvent, down: Bool) {
            guard !finished else { return }
            if event.type == .keyDown || event.type == .keyUp {
                // Also read flags from the key event itself: menu dispatch and
                // synthetic keyboard events may not deliver preceding flagsChanged events.
                let modifiers = ShortcutKey.modifiers(in: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)), preserving: Set(held.keys))
                for code in Set(held.keys).intersection(ShortcutKey.modifierCodes).subtracting(modifiers) { held.removeValue(forKey: code) }
                for code in modifiers where held[code] == nil { held[code] = ShortcutKey(code: code, name: ShortcutKey.label(code: code)) }
            }
            if down {
                let characters = event.type == .keyDown || event.type == .keyUp ? event.charactersIgnoringModifiers : nil
                held[event.keyCode] = ShortcutKey(code: event.keyCode, name: ShortcutKey.label(code: event.keyCode, characters: characters))
            }
            else { held.removeValue(forKey: event.keyCode) }
            if held.count > best.count {
                best = held.values.sorted {
                    if $0.isModifier != $1.isModifier { return $0.isModifier }
                    return $0.code < $1.code
                }
                captured(best)
            }
            if held.isEmpty && !best.isEmpty { finished = true }
        }
    }
}
