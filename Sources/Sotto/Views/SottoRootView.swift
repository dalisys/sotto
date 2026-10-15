import AppKit
import SwiftUI

struct SottoRootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 216)
            Rectangle().fill(SottoTheme.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(SottoTheme.line).frame(height: 1)
                if let error = model.errorMessage {
                    message(error, isError: true)
                } else if let notice = model.notice {
                    message(notice, isError: false)
                }
                routeContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SottoTheme.surface)
        .foregroundStyle(SottoTheme.ink)
        .font(SottoTheme.font(14))
        .tint(SottoTheme.orange)
        .preferredColorScheme(.light)
        .frame(minWidth: 960, minHeight: 680)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(nsImage: SottoBrand.appImage).resizable().frame(width: 28, height: 28)
                    .accessibilityHidden(true).padding(.trailing, 5)
                Text("sotto").font(SottoTheme.font(34, weight: .bold)).tracking(-1.6)
                Text(".").font(SottoTheme.font(34, weight: .bold)).foregroundStyle(SottoTheme.orange)
            }.padding(.top, 38).padding(.bottom, 8)
            Text("A little less typing.").font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                .padding(.bottom, 44)
            VStack(spacing: 5) {
                ForEach(AppRoute.allCases) { route in
                    Button { model.route = route } label: {
                        HStack(spacing: 13) {
                            Image(systemName: route.symbol).font(.system(size: 16)).frame(width: 20)
                            Text(route.title).font(SottoTheme.font(14, weight: model.route == route ? .semibold : .regular))
                            Spacer()
                            if model.route == route { Rectangle().fill(SottoTheme.orange).frame(width: 4, height: 16) }
                        }
                        .foregroundStyle(model.route == route ? SottoTheme.ink : SottoTheme.muted)
                        .padding(.vertical, 13).padding(.horizontal, 12)
                        .background(model.route == route ? SottoTheme.surface : .clear)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(route.title)
                }
            }.padding(.horizontal, -12)
            Spacer()
            Rectangle().fill(SottoTheme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                Label(model.settings.backend.title, systemImage: model.settings.backend == .openRouter ? "cloud" : "laptopcomputer")
                    .font(SottoTheme.font(12))
                Text(model.settings.shortcut.compactTitle)
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                if !model.shortcutReady {
                    Text("Shortcut unavailable").font(SottoTheme.font(11)).foregroundStyle(SottoTheme.orange)
                }
            }.padding(.vertical, 22)
        }
        .padding(.horizontal, 28).background(Color.white)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.route.title).font(SottoTheme.font(21, weight: .semibold)).tracking(-0.5)
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.phase == .recording ? SottoTheme.orange : SottoTheme.muted.opacity(0.5)).frame(width: 6, height: 6)
                Text(model.phase.title).font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
            }
        }.padding(.horizontal, 32).padding(.top, 35).padding(.bottom, 22)
    }

    @ViewBuilder private var routeContent: some View {
        switch model.route {
        case .dictate: DictateView()
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .settings: SettingsView()
        }
    }

    private func message(_ text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
            Text(text).font(SottoTheme.font(13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if isError && model.canRetry {
                Button("Retry") { model.retryTranscription() }.buttonStyle(.plain).font(SottoTheme.font(12, weight: .semibold))
            }
            Button { if isError { model.dismissError() } else { model.notice = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.foregroundStyle(isError ? SottoTheme.orange : SottoTheme.ink)
            .padding(14).background(Color.white)
            .overlay(alignment: .bottom) { Rectangle().fill(SottoTheme.line).frame(height: 1) }
    }
}

struct SottoMenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sotto").font(.headline)
            Text(model.phase.title).font(.caption).foregroundStyle(.secondary)
            Button(model.phase == .recording ? "Stop dictation" : "Start dictation") { model.toggleRecording() }
                .disabled(model.phase.isBusy && model.phase != .recording)
            if model.phase.isBusy { Button("Cancel") { model.cancelRecording() } }
            Divider()
            Button("Open Sotto") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Settings") { model.route = .settings; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit Sotto") { NSApp.terminate(nil) }
        }.padding(8).frame(width: 220)
    }
}
