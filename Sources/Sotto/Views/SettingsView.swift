import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingShortcut = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set your flow.").font(SottoTheme.font(32, weight: .bold)).tracking(-1)
                    Text("Choose a local model or OpenRouter. Keep the rest of your workflow.")
                        .font(SottoTheme.font(14)).foregroundStyle(SottoTheme.muted)
                }
                transcriptionSection
                if model.settings.backend != .openRouter { localSection }
                if model.settings.backend == .openRouter || model.settings.polishEnabled { routerSection }
                polishSection
                workflowSection
                permissionSection
                storageSection
            }.padding(32)
        }.onAppear { model.refreshPermissions() }
        .sheet(isPresented: $editingShortcut) {
            ShortcutRecorderSheet(current: model.settings.shortcut) { shortcut in
                model.settings.shortcut = shortcut
                editingShortcut = false
            } cancel: { editingShortcut = false }
            .onDisappear { model.resumeShortcutAfterEditing() }
        }
    }

    private var transcriptionSection: some View {
        RuledSection("Transcription", detail: "Local engines keep audio on the computer. OpenRouter sends audio to your selected model’s provider.") {
            VStack(alignment: .leading, spacing: 17) {
                settingRow("Speech engine") {
                    Picker("Speech engine", selection: $model.settings.backend) {
                        ForEach(TranscriptionBackend.allCases) { backend in Text(backend.title).tag(backend) }
                    }.labelsHidden().frame(width: 250)
                }
                settingRow("Language") {
                    TextField("en-US", text: $model.settings.language).textFieldStyle(.roundedBorder).frame(width: 220).accessibilityLabel("Language locale")
                }
                Text("Use a locale such as en-US, de-DE, or fr-FR. Language support depends on your chosen model.")
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
                if model.settings.backend == .openRouter {
                    modelSelector("Speech model", text: $model.settings.transcriptionModel, models: model.availableTranscriptionModels, prompt: "nvidia/parakeet-tdt-0.6b-v3")
                    Text("Model IDs use vendor/name. Refresh the OpenRouter catalog below to see models that accept audio.")
                        .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                }
            }
        }
    }

    private var localSection: some View {
        RuledSection(model.settings.backend == .localParakeet ? "Local Parakeet" : "Local Whisper", detail: model.settings.backend == .localParakeet ? "Run NVIDIA Parakeet locally using the configured model runtime. Setup downloads model weights; dictation audio stays local." : "Connect to a Whisper-compatible server running locally. Sotto does not bundle the Whisper server.") {
            VStack(alignment: .leading, spacing: 18) {
                if model.settings.backend == .localParakeet {
                    labeledField("Model directory", text: $model.settings.localModelDirectory, prompt: "Local model directory")
                    settingRow("Parakeet version") {
                        Picker("Parakeet version", selection: $model.settings.localParakeetVariant) {
                            Text("V3 · multilingual").tag("v3")
                            Text("V2 · English").tag("v2")
                        }.labelsHidden().frame(width: 220)
                    }
                } else {
                    labeledField("Local Whisper server", text: $model.settings.localWhisperURL, prompt: "http://127.0.0.1:8080")
                    Text("Use a loopback address. Start your local server before checking its status.")
                        .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                }
                HStack(spacing: 10) {
                    Image(systemName: model.onDeviceStatus == .ready ? "checkmark.circle" : "arrow.down.circle")
                        .foregroundStyle(model.onDeviceStatus == .ready ? SottoTheme.ink : SottoTheme.orange)
                    Text(model.checkingModel ? "Checking local engine…" : model.onDeviceStatus.title).font(SottoTheme.font(13))
                    Spacer()
                    if model.checkingModel || model.isPreparingModel { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 14) {
                    if model.settings.backend == .localParakeet && model.onDeviceStatus != .ready {
                        Button(model.isPreparingModel ? "Preparing model…" : "Prepare Parakeet") { model.prepareOnDeviceModel() }
                            .buttonStyle(SottoButtonStyle(prominent: true))
                            .disabled(model.phase.isBusy || model.checkingModel || model.isPreparingModel)
                    }
                    Button("Check status") { model.refreshOnDeviceModel() }
                        .buttonStyle(SottoButtonStyle()).disabled(model.checkingModel || model.isPreparingModel)
                }
            }
        }
    }

    private var routerSection: some View {
        RuledSection("OpenRouter", detail: "The only cloud connection. Audio transcription and optional text editing use OpenRouter, with your own key and selected models. Provider charges may apply.") {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Endpoint").font(SottoTheme.font(12, weight: .semibold))
                    Spacer()
                    Text("openrouter.ai/api/v1").font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).textSelection(.enabled)
                    Image(systemName: "lock").foregroundStyle(SottoTheme.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("OpenRouter key").font(SottoTheme.font(12, weight: .semibold))
                        Spacer()
                        Text(model.hasAPIKey ? "Saved in macOS Keychain" : "No key saved").font(SottoTheme.font(11)).foregroundStyle(SottoTheme.muted)
                    }
                    HStack(spacing: 10) {
                        SecureField(model.hasAPIKey ? "Enter a replacement OpenRouter key" : "Enter your OpenRouter key", text: $model.apiKeyInput)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("OpenRouter key")
                        Button("Save key") { model.saveAPIKey() }.buttonStyle(SottoButtonStyle())
                            .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.hasAPIKey {
                            Button("Remove") { model.removeAPIKey() }.buttonStyle(.plain).font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button("Verify key") { model.verifyOpenRouterKey() }.buttonStyle(SottoButtonStyle()).disabled(!model.hasAPIKey || model.checkingOpenRouter)
                    Button("Refresh models") { model.refreshOpenRouterModels() }.buttonStyle(SottoButtonStyle()).disabled(model.checkingOpenRouter)
                    Button("Test transcription") { model.testOpenRouterTranscription() }.buttonStyle(SottoButtonStyle()).disabled(!model.hasAPIKey || model.checkingOpenRouter)
                    if model.checkingOpenRouter { ProgressView().controlSize(.small) }
                }
                Text("Test transcription sends a public 11-second English audio sample to OpenRouter and uses provider credits. It does not record your microphone.")
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
                if let status = model.routerStatus {
                    Text(status).font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).textSelection(.enabled)
                }
            }
        }
    }

    private var polishSection: some View {
        RuledSection("AI editing", detail: "Optional cleanup through OpenRouter. With a local speech engine, enabling this sends the finished transcript to OpenRouter; the audio remains local.") {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Polish transcripts with OpenRouter", isOn: $model.settings.polishEnabled).toggleStyle(.switch)
                if model.settings.backend.isLocal && model.settings.polishEnabled && !model.hasAPIKey {
                    Text("Local dictation needs no API key. Optional OpenRouter cleanup will be skipped until you save a key.")
                        .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                }
                if model.settings.polishEnabled {
                    modelSelector("Editing model", text: $model.settings.polishModel, models: model.availableEditingModels, prompt: "google/gemini-3.1-flash-lite")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Editing instructions").font(SottoTheme.font(12, weight: .semibold))
                        TextEditor(text: $model.settings.polishInstruction).font(SottoTheme.font(13))
                            .frame(height: 85).padding(8).overlay(Rectangle().strokeBorder(SottoTheme.line))
                            .accessibilityLabel("AI editing instructions")
                    }
                    Toggle("Include context from the active app", isOn: $model.settings.includeAppContext).toggleStyle(.switch)
                    Text("When enabled, the active app’s name and available selected or surrounding text may be sent to OpenRouter with the transcript and your editing instructions.")
                        .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
                }
            }
        }
    }

    private var workflowSection: some View {
        RuledSection("Recording & insertion") {
            VStack(alignment: .leading, spacing: 18) {
                settingRow("Global shortcut") {
                    HStack(spacing: 12) {
                        Label(model.settings.shortcut.compactTitle, systemImage: "keyboard")
                            .font(SottoTheme.font(12, weight: .semibold))
                        Button("Record shortcut") {
                            model.suspendShortcutForEditing()
                            editingShortcut = true
                        }.buttonStyle(SottoButtonStyle())
                    }
                }
                Text("Choose one key or press multiple keys together. Modifier-only and custom chords are supported. Press the saved shortcut once to start and again to stop.")
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                if !model.shortcutReady {
                    Button("Retry shortcut") { model.retryShortcut() }.buttonStyle(SottoButtonStyle())
                }
                Rectangle().fill(SottoTheme.line).frame(height: 1)
                Toggle("Show floating dictation bar", isOn: $model.settings.showFloatingBar).toggleStyle(.switch)
                Text("Drag the dotted grip to place the bar anywhere. Your position is remembered. It expands while recording and keeps keyboard focus in your app.")
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
                if model.settings.floatingBarPosition != nil {
                    Button("Reset bar position") { model.settings.floatingBarPosition = nil }
                        .buttonStyle(.plain).foregroundStyle(SottoTheme.orange)
                }
                Toggle("Insert finished text into the active app", isOn: $model.settings.insertAutomatically).toggleStyle(.switch)
                Text("Accessibility permission is required. If insertion is unavailable, Sotto copies your transcript to the clipboard.")
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
                Stepper(value: recordingLimit, in: 10...300, step: 10) {
                    HStack { Text("Maximum recording length"); Spacer(); Text("\(recordingLimit.wrappedValue) sec").foregroundStyle(SottoTheme.muted) }
                }
            }
        }
    }

    private var recordingLimit: Binding<Int> {
        Binding(get: { min(300, max(10, model.settings.maximumRecordingSeconds)) }, set: { model.settings.maximumRecordingSeconds = $0 })
    }

    private var permissionSection: some View {
        RuledSection("macOS permissions", detail: "Enable microphone access here or when you start dictation. This does not require a model download or API key. If access was denied, the button opens macOS Microphone settings.") {
            VStack(alignment: .leading, spacing: 16) {
                permissionRow("Microphone", symbol: "mic", granted: model.microphoneGranted)
                permissionRow("Accessibility", symbol: "hand.point.up.left", granted: model.accessibilityGranted)
                HStack(spacing: 12) {
                    Button(model.requestingMicrophone ? "Requesting microphone…" : "Enable Microphone") { model.requestMicrophonePermission() }
                        .buttonStyle(SottoButtonStyle()).disabled(model.microphoneGranted || model.requestingMicrophone || model.phase.isBusy)
                    Button("Enable Accessibility") { model.requestAccessibility() }.buttonStyle(SottoButtonStyle())
                    Button("Refresh status") { model.refreshPermissions() }.buttonStyle(.plain).font(SottoTheme.font(12))
                }
            }
        }
    }

    private var storageSection: some View {
        RuledSection("Local storage", detail: "Transcripts and your dictionary are saved locally. Your OpenRouter key is stored separately in macOS Keychain.") {
            VStack(alignment: .leading, spacing: 15) {
                Toggle("Keep audio recordings", isOn: $model.settings.keepRecordings).toggleStyle(.switch)
                Text("Off by default. Previously retained audio stays until its history entry is deleted.")
                    .font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).lineSpacing(3)
                Button { NSWorkspace.shared.open(model.dataDirectory) } label: { Label("Open data folder", systemImage: "folder") }
                    .buttonStyle(SottoButtonStyle())
            }
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(label).font(SottoTheme.font(13)); Spacer(); content() }
    }
    private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SottoTheme.font(12, weight: .semibold))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
    private func modelSelector(_ title: String, text: Binding<String>, models: [RouterModel], prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SottoTheme.font(12, weight: .semibold))
            HStack(spacing: 10) {
                TextField(prompt, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
                if !models.isEmpty {
                    Menu("Choose model") {
                        ForEach(models) { item in Button(item.name) { text.wrappedValue = item.id } }
                    }.frame(width: 130)
                }
            }
        }
    }
    private func permissionRow(_ title: String, symbol: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(SottoTheme.muted)
            Text(title).font(SottoTheme.font(13))
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? SottoTheme.ink : SottoTheme.muted)
            Text(granted ? "Allowed" : "Not granted").font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).frame(width: 82, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
}
