import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(SottoAppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--self-check") { SottoDiagnostics.run() }
        var directory: URL?
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        _model = StateObject(wrappedValue: AppModel(persistence: Persistence(directory: directory),
                                                   smokeTest: arguments.contains("--smoke-test")))
    }

    var body: some Scene {
        WindowGroup("Sotto", id: "main") {
            SottoRootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .frame(minWidth: 960, minHeight: 680)
                .onAppear { delegate.connect(model); model.runOverlayPreviewIfRequested() }
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.route = .settings
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        MenuBarExtra {
            SottoMenuView().environmentObject(model)
        } label: {
            Image(nsImage: SottoBrand.menuImage)
                .accessibilityLabel(model.phase == .recording ? "Sotto is recording" : "Sotto")
        }
    }
}

@MainActor
final class SottoAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var hud: FloatingDictationPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func connect(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        hud = FloatingDictationPanel(model: model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

