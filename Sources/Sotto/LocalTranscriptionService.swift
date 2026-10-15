import Foundation
import FluidAudio

// A ready model can be stored on disk or already warm; warmUp never downloads.
enum LocalModelStatus: Equatable, Sendable {
    case ready, notPrepared, preparing, unavailable
    var title: String {
        switch self {
        case .ready: return "Ready"
        case .notPrepared: return "Model preparation required"
        case .preparing: return "Preparing local model"
        case .unavailable: return "Local engine unavailable"
        }
    }
}

@MainActor
final class LocalTranscriptionService {
    private let parakeet = LocalParakeetEngine()
    private let whisper: LocalWhisperClient

    init(whisper: LocalWhisperClient = LocalWhisperClient()) { self.whisper = whisper }

    func status(settings: UserSettings) async -> LocalModelStatus {
        switch settings.backend {
        case .localParakeet:
            guard let configuration = try? LocalParakeetConfiguration(settings: settings) else { return .unavailable }
            return await parakeet.status(configuration: configuration)
        case .localWhisper:
            return (try? await whisper.isReady(baseURL: settings.localWhisperURL)) == true ? .ready : .unavailable
        case .openRouter: return .unavailable
        }
    }

    /// The only operation allowed to acquire Parakeet weights from the network.
    func prepare(settings: UserSettings) async throws {
        switch settings.backend {
        case .localParakeet:
            try await parakeet.prepare(configuration: LocalParakeetConfiguration(settings: settings))
        case .localWhisper:
            guard try await whisper.isReady(baseURL: settings.localWhisperURL) else {
                throw SottoError.message("Local Whisper is not ready. Start a whisper.cpp server with a model loaded; Sotto connects to it without downloading or reloading its model.")
            }
        case .openRouter: throw SottoError.message("Select a local speech engine before preparing it.")
        }
    }

    /// Load once and retain the CoreML manager across recordings. This operation stays offline.
    func warmUp(settings: UserSettings) async throws {
        switch settings.backend {
        case .localParakeet:
            try await parakeet.warmUp(configuration: LocalParakeetConfiguration(settings: settings))
        case .localWhisper: try await prepare(settings: settings)
        case .openRouter: return
        }
    }

    func transcribe(audio: RecordedAudio, settings: UserSettings, vocabulary: [DictionaryEntry]) async throws -> String {
        try Task.checkCancellation()
        switch settings.backend {
        case .localParakeet:
            let configuration = try LocalParakeetConfiguration(settings: settings)
            let language = settings.language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "en"
            return try await parakeet.transcribe(audio: audio, configuration: configuration, languageCode: language)
        case .localWhisper:
            return try await whisper.transcribe(audio: audio, baseURL: settings.localWhisperURL,
                                                language: settings.language, vocabulary: vocabulary)
        case .openRouter: throw SottoError.message("The local transcription service cannot call cloud providers.")
        }
    }
}

struct LocalParakeetConfiguration: Sendable {
    let variant: String
    let version: AsrModelVersion
    let directory: URL
    var key: String { "\(variant)|\(directory.path)" }

    init(settings: UserSettings) throws {
        variant = settings.localParakeetVariant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let repo: Repo
        switch variant {
        case "v3": version = .v3; repo = .parakeetV3
        case "redux":
            guard #available(macOS 15.0, *) else { throw SottoError.message("Parakeet Redux requires macOS 15 or later. Choose v3 or Ultra.") }
            version = .redux; repo = .parakeetRedux
        case "ultra": version = .ultra; repo = .parakeetUltra
        default: throw SottoError.message("Choose a supported Parakeet model: v3, Redux, or Ultra.")
        }
        let path = settings.localModelDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL
        if path.isEmpty {
            let portableRoot = Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("Models", isDirectory: true)
            let portableVariant = portableRoot.appendingPathComponent(repo.folderName, isDirectory: true)
            if AsrModels.modelsExist(at: portableVariant, version: version) {
                // An optional Models sibling makes an already-prepared app folder portable.
                // Missing or incomplete weights fall back to normal per-user storage.
                root = portableRoot
            } else {
                guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    throw SottoError.message("The local model storage directory could not be located.")
                }
                root = support.appendingPathComponent("Sotto/Models", isDirectory: true)
            }
        } else {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw SottoError.message("The model storage directory must be an absolute path.") }
            root = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        // FluidAudio stores each variant in its repository-named subdirectory.
        directory = root.lastPathComponent == repo.folderName ? root : root.appendingPathComponent(repo.folderName, isDirectory: true)
    }
}

/// All load/warm/inference work joins one task chain. Actor isolation alone would allow
/// reentrancy while CoreML awaits, which could overlap decoder sessions on one manager.
private actor LocalParakeetEngine {
    private var manager: AsrManager?
    private var loadedKey: String?
    private var warmedKey: String?
    private var preparationCounts: [String: Int] = [:]
    private var tail: Task<Void, Never>?

    func status(configuration: LocalParakeetConfiguration) -> LocalModelStatus {
        #if !arch(arm64)
        return .unavailable
        #else
        if preparationCounts[configuration.key, default: 0] > 0 { return .preparing }
        if loadedKey == configuration.key || AsrModels.modelsExist(at: configuration.directory, version: configuration.version) { return .ready }
        return .notPrepared
        #endif
    }

    func prepare(configuration: LocalParakeetConfiguration) async throws {
        try requireAppleSilicon()
        preparationCounts[configuration.key, default: 0] += 1
        defer { preparationCounts[configuration.key, default: 1] -= 1 }
        try await serially {
            try await self.acquireAndLoad(configuration: configuration, allowDownload: true)
            try await self.prime(configuration: configuration)
        }
    }

    func warmUp(configuration: LocalParakeetConfiguration) async throws {
        try requireAppleSilicon()
        preparationCounts[configuration.key, default: 0] += 1
        defer { preparationCounts[configuration.key, default: 1] -= 1 }
        try await serially {
            try await self.acquireAndLoad(configuration: configuration, allowDownload: false)
            try await self.prime(configuration: configuration)
        }
    }

    func transcribe(audio: RecordedAudio, configuration: LocalParakeetConfiguration, languageCode: String) async throws -> String {
        try requireAppleSilicon()
        // Parakeet v3-family supports these 25 European languages; don't silently misrecognize others.
        let supported = Set(["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"])
        guard supported.contains(languageCode) else {
            throw SottoError.message("This Parakeet model does not support \(languageCode). Choose one of its 25 European languages, or use Local Whisper for broader language support.")
        }
        return try await serially {
            try await self.acquireAndLoad(configuration: configuration, allowDownload: false)
            return try await self.decode(audio: audio, languageCode: languageCode)
        }
    }

    private func acquireAndLoad(configuration: LocalParakeetConfiguration, allowDownload: Bool) async throws {
        try Task.checkCancellation()
        if loadedKey == configuration.key, manager != nil { return }
        if !AsrModels.modelsExist(at: configuration.directory, version: configuration.version) {
            guard allowDownload else {
                throw SottoError.message("Parakeet is not prepared. In Settings, choose Prepare local model to download it once before dictating.")
            }
            try await AsrModels.download(to: configuration.directory, version: configuration.version)
        }
        try Task.checkCancellation()
        // loadLocal is deliberately used instead of load/downloadAndLoad: a dictation
        // must never repair, resolve, or fetch missing weights in the background.
        let models = try AsrModels.loadLocal(from: configuration.directory, version: configuration.version)
        let freshManager = AsrManager(config: .default)
        try await freshManager.loadModels(models)
        try Task.checkCancellation()
        manager = freshManager
        loadedKey = configuration.key
        warmedKey = nil
    }

    private func prime(configuration: LocalParakeetConfiguration) async throws {
        guard warmedKey != configuration.key, let manager else { return }
        var state = try TdtDecoderState()
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
        try Task.checkCancellation()
        warmedKey = configuration.key
    }

    private func decode(audio: RecordedAudio, languageCode: String) async throws -> String {
        guard let manager else { throw SottoError.message("The local speech engine is not loaded.") }
        try Task.checkCancellation()
        // Each recording gets fresh LSTM state; earlier text never conditions another session.
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(audio.url, decoderState: &decoderState,
                                                  language: Language(rawValue: languageCode))
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SottoError.message("Parakeet did not recognize any speech. Try again closer to the microphone.") }
        return text
    }

    private func serially<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let predecessor = tail
        let job = Task {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await job.value }
        return try await withTaskCancellationHandler {
            let value = try await job.value
            try Task.checkCancellation()
            return value
        } onCancel: { job.cancel() }
    }

    private func requireAppleSilicon() throws {
        #if !arch(arm64)
        throw SottoError.message("Embedded Parakeet requires an Apple Silicon Mac. Local Whisper can be used with a separately managed server.")
        #endif
    }
}
