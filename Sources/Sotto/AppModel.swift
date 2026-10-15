import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var route: AppRoute = .dictate
    @Published var settings: UserSettings {
        didSet {
            persist()
            if settings.shortcut != oldValue.shortcut { registerShortcut() }
            if settings.language != oldValue.language || settings.backend != oldValue.backend ||
                settings.localModelDirectory != oldValue.localModelDirectory || settings.localParakeetVariant != oldValue.localParakeetVariant ||
                settings.localWhisperURL != oldValue.localWhisperURL { refreshOnDeviceModel() }
        }
    }
    @Published var transcript = ""
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var apiKeyInput = ""
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var history: [DictationRecord]
    @Published private(set) var dictionary: [DictionaryEntry]
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var speechGranted = false
    @Published private(set) var shortcutReady = false
    @Published private(set) var hasAPIKey = false
    @Published private(set) var targetAppName: String?
    @Published private(set) var canRetry = false
    @Published private(set) var onDeviceStatus: LocalModelStatus = .unavailable
    @Published private(set) var checkingModel = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var lastTiming: DictationTiming?
    @Published private(set) var availableTranscriptionModels: [RouterModel] = []
    @Published private(set) var availableEditingModels: [RouterModel] = []
    @Published private(set) var checkingOpenRouter = false
    @Published private(set) var routerStatus: String?
    @Published private(set) var isOverlayPreview = false

    var wordCount: Int { transcript.split(whereSeparator: { $0.isWhitespace }).count }
    var totalWords: Int { history.reduce(0) { $0 + $1.wordCount } }
    var todayCount: Int { history.filter { Calendar.current.isDateInToday($0.createdAt) }.count }
    var dataDirectory: URL { persistence.directory }
    var latestPipelineLabel: String {
        switch settings.backend {
        case .localParakeet: return "Local Parakeet"
        case .localWhisper: return "Whisper on localhost"
        case .openRouter: return "OpenRouter · \(settings.transcriptionModel)"
        }
    }

    private let persistence: Persistence
    private let recorder = AudioRecorderService()
    private let transcription = TranscriptionService()
    private let cloud = CloudTranscriptionClient()
    private let native = NativeIntegration()
    private let shortcut = ShortcutService()
    private var cancellables = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var modelCheckTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var routerTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var startedAt: Date?
    private var pendingAudio: RecordedAudio?
    private var attemptSettings = UserSettings()
    private var attemptWarning: String?
    private var recordingContext: FocusedAppContext?
    private var lastExternalContext: FocusedAppContext?
    private var persistenceAvailable = true
    private var shortcutError: String?
    private let smokeTest: Bool

    init(persistence: Persistence? = nil, smokeTest: Bool = false) {
        self.persistence = persistence ?? Persistence()
        self.smokeTest = smokeTest
        let archive: AppArchive
        var loadError: String?
        do { archive = try self.persistence.load() }
        catch {
            archive = AppArchive()
            persistenceAvailable = false
            loadError = "Could not open your local library. Existing data was left untouched. \(error.localizedDescription)"
        }
        settings = archive.settings
        history = archive.history
        dictionary = archive.dictionary
        errorMessage = loadError
        if !smokeTest {
            hasAPIKey = (try? KeychainService.readAPIKey()) != nil
            registerShortcut()
        }
        refreshPermissions()
        refreshOnDeviceModel()
        rememberFrontmostApplication()
        recorder.$level.sink { [weak self] value in self?.audioLevel = value }.store(in: &cancellables)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.remember(application) }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }
    }

    func toggleRecording() {
        switch phase {
        case .recording: finishRecording()
        case .idle, .failed: beginRecording()
        default: break
        }
    }

    /// Explicit developer preview: replay levels from the public fixture and run
    /// real local ASR, without opening the microphone, inserting text or saving history.
    func runOverlayPreviewIfRequested() {
        guard smokeTest, !isOverlayPreview,
              ProcessInfo.processInfo.arguments.contains("--preview-floating-bar") else { return }
        isOverlayPreview = true
        notice = "Animation preview uses public sample audio. The microphone is off."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = Bundle.main.url(forResource: "SottoTest", withExtension: "wav") else {
                    throw SottoError.message("The public preview sample is unavailable.")
                }
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw SottoError.message("Could not decode the preview sample.")
                }
                try file.read(into: buffer)
                guard let samples = buffer.floatChannelData?[0] else { throw SottoError.message("Preview audio is unavailable.") }
                self.phase = .recording
                let window = max(1, Int(file.processingFormat.sampleRate / 20))
                let count = min(Int(buffer.frameLength), window * 100)
                for offset in stride(from: 0, to: count, by: window) {
                    try Task.checkCancellation()
                    let end = min(count, offset + window)
                    var energy = 0.0
                    for index in offset..<end { energy += Double(samples[index] * samples[index]) }
                    let rms = sqrt(energy / Double(end - offset))
                    self.audioLevel = min(1, max(0, (20 * log10(max(0.000001, rms)) + 55) / 55))
                    self.elapsed = Double(offset) / file.processingFormat.sampleRate
                    try await Task.sleep(for: .milliseconds(50))
                }
                self.audioLevel = 0
                self.phase = .transcribing
                var local = self.settings
                local.backend = .localParakeet
                let start = ProcessInfo.processInfo.systemUptime
                self.transcript = try await self.transcription.transcribe(audio: RecordedAudio(url: url, duration: 11), settings: local,
                                                                       apiKey: nil, vocabulary: [])
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.lastTiming = DictationTiming(transcriptionMilliseconds: milliseconds, polishMilliseconds: 0,
                                                  insertionMilliseconds: 0, totalMilliseconds: milliseconds)
                self.phase = .idle
            } catch is CancellationError { self.phase = .idle }
            catch { self.fail(error) }
        }
    }

    private func beginRecording() {
        if smokeTest {
            notice = "Preview mode: launch Sotto normally to record."
            return
        }
        discardPendingAudio()
        let id = UUID()
        sessionID = id
        errorMessage = nil
        notice = nil
        elapsed = 0
        canRetry = false
        attemptSettings = settings
        attemptWarning = nil
        recordingContext = native.captureFocusedApp(includeTextContext:
            attemptSettings.polishEnabled && attemptSettings.includeAppContext && hasAPIKey
        ) ?? lastExternalContext
        targetAppName = recordingContext?.applicationName
        phase = .requestingPermission
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Permission is independent of model readiness and cloud credentials.
                try await MicrophonePermission.requireAccess()
                self.refreshPermissions()
                let key: String?
                if self.attemptSettings.backend == .openRouter { key = try KeychainService.readAPIKey() }
                else { key = self.attemptSettings.polishEnabled ? (try? KeychainService.readAPIKey()) : nil }
                let plan = try DictationPlan(settings: self.attemptSettings, apiKey: key)
                self.attemptSettings = plan.settings
                self.attemptWarning = plan.notice
                self.notice = plan.notice
                if self.attemptSettings.backend.isLocal {
                    let status = await self.transcription.onDeviceModelStatus(settings: self.attemptSettings)
                    try Task.checkCancellation()
                    self.onDeviceStatus = status
                    guard status == .ready else {
                        self.route = .settings
                        throw SottoError.message("\(status.title). Check your local speech engine in Settings before recording.")
                    }
                    try await self.transcription.warmUp(settings: self.attemptSettings)
                }
                try await self.recorder.start()
                guard self.sessionID == id, !Task.isCancelled else {
                    self.recorder.cancel()
                    if self.sessionID == nil { self.phase = .idle }
                    return
                }
                self.transcript = ""
                self.phase = .recording
                self.startedAt = Date()
                self.refreshPermissions()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.updateRecordingTime() }
                }
            } catch {
                guard self.sessionID == id else {
                    if self.sessionID == nil { self.phase = .idle }
                    return
                }
                self.fail(error)
            }
        }
    }

    private func updateRecordingTime() {
        guard phase == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        let limit = min(300, max(10, attemptSettings.maximumRecordingSeconds))
        if elapsed >= Double(limit) { finishRecording() }
    }

    private func finishRecording() {
        guard phase == .recording, let id = sessionID else { return }
        timer?.invalidate()
        timer = nil
        do {
            let audio = try recorder.stop()
            pendingAudio = audio
            elapsed = audio.duration
            runTranscription(audio, session: id)
        } catch { fail(error) }
    }

    func retryTranscription() {
        guard canRetry, let audio = pendingAudio else { return }
        let id = UUID()
        sessionID = id
        attemptSettings = settings
        attemptWarning = nil
        errorMessage = nil
        runTranscription(audio, session: id)
    }

    private func runTranscription(_ audio: RecordedAudio, session id: UUID) {
        phase = .transcribing
        canRetry = false
        let requestSettings = attemptSettings
        let requestVocabulary = dictionary
        let context = recordingContext
        let processingStart = ProcessInfo.processInfo.systemUptime
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let savedKey: String?
                if requestSettings.backend == .openRouter { savedKey = try KeychainService.readAPIKey() }
                else { savedKey = requestSettings.polishEnabled ? (try? KeychainService.readAPIKey()) : nil }
                let plan = try DictationPlan(settings: requestSettings, apiKey: savedKey)
                let key = plan.apiKey
                if let warning = plan.notice { self.attemptWarning = warning }
                let asrStart = ProcessInfo.processInfo.systemUptime
                let raw = try await self.transcription.transcribe(
                    audio: audio, settings: requestSettings, apiKey: key, vocabulary: requestVocabulary
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let asrMilliseconds = (ProcessInfo.processInfo.systemUptime - asrStart) * 1000
                var polishMilliseconds = 0.0
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                guard !raw.isEmpty else { throw SottoError.message("No speech was recognized. Try again closer to the microphone.") }
                var text = TextProcessor.applyingDictionary(requestVocabulary, to: raw)
                if plan.settings.polishEnabled {
                    let polishStart = ProcessInfo.processInfo.systemUptime
                    do {
                        text = try await self.transcription.polish(
                            text: text, settings: requestSettings, apiKey: key,
                            context: requestSettings.includeAppContext ? context : nil
                        )
                    } catch {
                        try Task.checkCancellation()
                        self.notice = "Transcription was kept; cleanup failed. \(error.localizedDescription)"
                    }
                    polishMilliseconds = (ProcessInfo.processInfo.systemUptime - polishStart) * 1000
                }
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.transcript = text
                var record = DictationRecord(originalText: raw, text: text, duration: audio.duration,
                                             language: requestSettings.language, applicationName: context?.applicationName)
                if requestSettings.keepRecordings {
                    do { record.audioPath = try self.persistence.retainRecording(audio, id: record.id) }
                    catch { self.notice = "Text saved, but the audio recording could not be retained. \(error.localizedDescription)" }
                }
                self.history.insert(record, at: 0)
                if self.history.count > 500 {
                    self.history.suffix(from: 500).forEach { self.persistence.removeRecording(path: $0.audioPath) }
                    self.history = Array(self.history.prefix(500))
                }
                self.persist()
                self.discardPendingAudio()
                var insertionMilliseconds = 0.0
                if requestSettings.insertAutomatically {
                    self.phase = .inserting
                    let insertionStart = ProcessInfo.processInfo.systemUptime
                    let outcome = try await self.native.insert(text: text, into: context)
                    insertionMilliseconds = (ProcessInfo.processInfo.systemUptime - insertionStart) * 1000
                    guard self.sessionID == id else { return }
                    switch outcome {
                    case .inserted: self.notice = "Paste sent to \(context?.applicationName ?? "your app"). Transcript saved."
                    case .copiedToClipboard: self.notice = "Copied to clipboard. Enable Accessibility and focus a text field to insert automatically."
                    }
                } else if self.notice == nil { self.notice = "Transcript saved locally." }
                let timing = DictationTiming(transcriptionMilliseconds: asrMilliseconds,
                                             polishMilliseconds: polishMilliseconds,
                                             insertionMilliseconds: insertionMilliseconds,
                                             totalMilliseconds: (ProcessInfo.processInfo.systemUptime - processingStart) * 1000)
                self.lastTiming = timing
                if let warning = self.attemptWarning {
                    self.notice = [self.notice, warning].compactMap { $0 }.joined(separator: " ")
                }
                if let index = self.history.firstIndex(where: { $0.id == record.id }) { self.history[index].timing = timing }
                self.persist()
                self.phase = .idle
                self.sessionID = nil
                self.refreshPermissions()
            } catch {
                guard self.sessionID == id else { return }
                if error is CancellationError { self.phase = .idle }
                else { self.fail(error) }
            }
        }
    }

    func cancelRecording() {
        let waitingForPermission = phase == .requestingPermission
        let inserting = phase == .inserting
        task?.cancel()
        sessionID = nil
        timer?.invalidate()
        timer = nil
        recorder.cancel()
        discardPendingAudio()
        audioLevel = 0
        if !waitingForPermission { phase = .idle }
        errorMessage = nil
        notice = inserting ? "Insertion stopped. A paste already sent may have reached your app." : "Dictation cancelled."
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        native.copyText(transcript)
        notice = "Copied to clipboard."
    }

    func insertTranscript() {
        guard !phase.isBusy, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phase = .inserting
        let id = UUID()
        sessionID = id
        let text = transcript
        let context = native.captureFocusedApp() ?? lastExternalContext
        task = Task {
            do {
                let outcome = try await native.insert(text: text, into: context)
                guard sessionID == id, !Task.isCancelled else { return }
                notice = outcome == .inserted ? "Paste sent to \(context?.applicationName ?? "your app")." : "Copied to clipboard."
                phase = .idle
                sessionID = nil
            } catch {
                guard sessionID == id, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func refreshPermissions() {
        accessibilityGranted = native.isAccessibilityTrusted
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = true // Local engines do not use Apple's legacy Speech service.
    }

    func requestAccessibility() {
        native.requestAccessibilityPermission()
        native.revealAccessibilitySettings()
        refreshPermissions()
    }

    func requestMicrophonePermission() {
        guard !requestingMicrophone, !smokeTest else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
            refreshPermissions()
            return
        }
        requestingMicrophone = true
        Task { [weak self] in
            guard let self else { return }
            let granted = await MicrophonePermission.request(status: status)
            self.requestingMicrophone = false
            self.refreshPermissions()
            if granted {
                self.notice = "Microphone access is enabled. You can start dictation."
                if self.errorMessage?.localizedCaseInsensitiveContains("microphone") == true { self.dismissError() }
            } else {
                self.errorMessage = "Microphone access was not allowed. Enable Sotto in macOS Privacy & Security → Microphone."
            }
        }
    }

    func refreshOnDeviceModel() {
        modelCheckTask?.cancel()
        let snapshot = settings
        checkingModel = true
        modelCheckTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.transcription.onDeviceModelStatus(settings: snapshot)
            guard !Task.isCancelled else { return }
            self.onDeviceStatus = status
            self.checkingModel = false
            if status == .ready && snapshot.backend == .localParakeet {
                do { try await self.transcription.warmUp(settings: snapshot) }
                catch { if !Task.isCancelled { self.errorMessage = "Could not warm the local model. \(error.localizedDescription)" } }
            }
        }
    }

    func prepareOnDeviceModel() {
        guard !isPreparingModel, !phase.isBusy else { return }
        let snapshot = settings
        isPreparingModel = true
        errorMessage = nil
        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparingModel = false; self.refreshOnDeviceModel() }
            do {
                try await self.transcription.prepareOnDevice(settings: snapshot)
                try Task.checkCancellation()
                self.notice = "\(snapshot.backend.title) is ready."
            } catch is CancellationError { self.notice = "Model preparation cancelled." }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    func cancelModelPreparation() { modelPreparationTask?.cancel() }

    func refreshOpenRouterModels() {
        guard !checkingOpenRouter else { return }
        checkingOpenRouter = true
        routerStatus = "Loading OpenRouter models…"
        routerTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkingOpenRouter = false }
            do {
                async let transcriptionModels = self.cloud.fetchTranscriptionModels()
                async let editingModels = self.cloud.fetchPolishModels()
                let (speech, text) = try await (transcriptionModels, editingModels)
                try Task.checkCancellation()
                self.availableTranscriptionModels = speech
                self.availableEditingModels = text
                self.routerStatus = "Loaded \(speech.count) speech models and \(text.count) text models from OpenRouter."
            } catch is CancellationError { self.routerStatus = nil }
            catch { self.routerStatus = error.localizedDescription }
        }
    }

    func verifyOpenRouterKey() {
        guard !checkingOpenRouter else { return }
        checkingOpenRouter = true
        routerStatus = "Checking OpenRouter key…"
        routerTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkingOpenRouter = false }
            do {
                guard let key = try KeychainService.readAPIKey(), !key.isEmpty else {
                    throw SottoError.message("Save your OpenRouter key first.")
                }
                let status = try await self.cloud.verifyAPIKey(key)
                try Task.checkCancellation()
                self.routerStatus = status.isFreeTier
                    ? "OpenRouter key verified. This key uses the free tier; model access may be limited."
                    : "OpenRouter key verified. No model inference was run."
            } catch is CancellationError { self.routerStatus = nil }
            catch { self.routerStatus = error.localizedDescription }
        }
    }

    /// Explicit user-triggered paid smoke test, using a public sample instead of microphone audio.
    func testOpenRouterTranscription() {
        guard !checkingOpenRouter else { return }
        var snapshot = settings
        snapshot.backend = .openRouter
        snapshot.language = "en-US"
        checkingOpenRouter = true
        routerStatus = "Transcribing the public English sample with OpenRouter…"
        routerTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkingOpenRouter = false }
            do {
                guard let key = try KeychainService.readAPIKey(), !key.isEmpty else {
                    throw SottoError.message("Save your OpenRouter key first.")
                }
                guard let fixture = Bundle.main.url(forResource: "SottoTest", withExtension: "wav") else {
                    throw SottoError.message("The public test sample is unavailable in this bundle.")
                }
                let start = ProcessInfo.processInfo.systemUptime
                let text = try await self.cloud.transcribe(audio: RecordedAudio(url: fixture, duration: 11),
                                                          settings: snapshot, apiKey: key, vocabulary: [])
                try Task.checkCancellation()
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.routerStatus = String(format: "OpenRouter transcription succeeded in %.0f ms. ", milliseconds) + text
            } catch is CancellationError { self.routerStatus = nil }
            catch { self.routerStatus = error.localizedDescription }
        }
    }

    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { errorMessage = "Enter an API key first."; return }
        do {
            try KeychainService.saveAPIKey(key)
            apiKeyInput = ""
            hasAPIKey = true
            notice = "OpenRouter key saved in macOS Keychain."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAPIKey() {
        do {
            try KeychainService.deleteAPIKey()
            hasAPIKey = false
            routerStatus = nil
            apiKeyInput = ""
            notice = "API key removed."
        } catch { errorMessage = error.localizedDescription }
    }

    func addDictionaryEntry(phrase: String, replacement: String) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 200, replacement.count <= 2000 else {
            errorMessage = "Use a phrase up to 200 characters and a replacement up to 2,000 characters."
            return
        }
        if let index = dictionary.firstIndex(where: { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }) {
            dictionary[index].replacement = replacement
            dictionary[index].phrase = phrase
        } else { dictionary.append(DictionaryEntry(phrase: phrase, replacement: replacement)) }
        dictionary.sort { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
        persist()
        errorMessage = nil
        notice = "Dictionary updated."
    }

    func removeDictionaryEntry(id: UUID) { dictionary.removeAll { $0.id == id }; persist() }
    func deleteHistory(id: UUID) {
        history.filter { $0.id == id }.forEach { persistence.removeRecording(path: $0.audioPath) }
        history.removeAll { $0.id == id }
        persist()
    }
    func clearHistory() {
        history.forEach { persistence.removeRecording(path: $0.audioPath) }
        history.removeAll()
        persist()
    }
    func loadHistory(_ record: DictationRecord) {
        guard !phase.isBusy else { return }
        transcript = record.text
        route = .dictate
        notice = "Loaded a saved transcript."
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sotto-history.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(history).write(to: url, options: .atomic)
            notice = "History exported."
        } catch { errorMessage = "Could not export history. \(error.localizedDescription)" }
    }

    func dismissError() { errorMessage = nil; if phase == .failed { phase = .idle } }

    func shutdown() {
        cancelRecording()
        native.restorePendingClipboard()
        shortcut.unregister()
        modelPreparationTask?.cancel()
        modelCheckTask?.cancel()
        routerTask?.cancel()
        permissionTimer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    func suspendShortcutForEditing() {
        shortcut.unregister()
        shortcutReady = false
    }

    func resumeShortcutAfterEditing() { registerShortcut() }

    func retryShortcut() { registerShortcut() }

    private func registerShortcut() {
        guard !smokeTest else { return }
        do {
            try shortcut.register(shortcut: settings.shortcut) { [weak self] in self?.toggleRecording() }
            shortcutReady = true
            if errorMessage == shortcutError { errorMessage = nil }
            shortcutError = nil
        } catch {
            shortcutReady = false
            errorMessage = "Could not register the shortcut. Choose another in Settings. \(error.localizedDescription)"
            shortcutError = errorMessage
        }
    }

    private func rememberFrontmostApplication() {
        if let application = NSWorkspace.shared.frontmostApplication { remember(application) }
    }
    private func remember(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular else { return }
        lastExternalContext = FocusedAppContext(applicationName: application.localizedName ?? "Application",
                                                bundleIdentifier: application.bundleIdentifier,
                                                processIdentifier: application.processIdentifier,
                                                selectedText: nil, surroundingText: nil)
        if !phase.isBusy { targetAppName = application.localizedName }
    }

    private func persist() {
        guard persistenceAvailable, !smokeTest else { return }
        do { try persistence.save(AppArchive(settings: settings, history: history, dictionary: dictionary)) }
        catch { errorMessage = "Could not save the local library. \(error.localizedDescription)" }
    }
    private func fail(_ error: Error) {
        timer?.invalidate()
        timer = nil
        phase = .failed
        errorMessage = error.localizedDescription
        canRetry = pendingAudio != nil
        refreshPermissions()
    }
    private func discardPendingAudio() {
        if let pendingAudio { try? FileManager.default.removeItem(at: pendingAudio.url) }
        pendingAudio = nil
        canRetry = false
    }
}
