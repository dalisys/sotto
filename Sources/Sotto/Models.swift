import Foundation

enum AppRoute: String, CaseIterable, Identifiable {
    case dictate, history, dictionary, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .dictate: return "waveform"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum DictationPhase: String {
    case idle, requestingPermission, recording, transcribing, inserting, failed
    var title: String {
        switch self {
        case .idle: return "Ready to dictate"
        case .requestingPermission: return "Preparing dictation"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .inserting: return "Inserting text"
        case .failed: return "Needs attention"
        }
    }
    var isBusy: Bool { self != .idle && self != .failed }
}

enum TranscriptionBackend: String, Codable, CaseIterable, Identifiable {
    case localParakeet, openRouter, localWhisper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localParakeet: return "Local Parakeet"
        case .openRouter: return "OpenRouter"
        case .localWhisper: return "Local Whisper server"
        }
    }
    var isLocal: Bool { self != .openRouter }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "appleOnDevice", "localParakeet": self = .localParakeet
        case "openAICompatible", "openRouter": self = .openRouter
        case "localWhisper": self = .localWhisper
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown transcription backend"))
        }
    }
}

struct FloatingBarPosition: Codable, Equatable {
    var x: Double
    var y: Double
}

struct UserSettings: Codable, Equatable {
    var backend: TranscriptionBackend = .localParakeet
    var language: String = "en-US"
    var apiBaseURL: String = "https://openrouter.ai/api/v1"
    var transcriptionModel: String = "nvidia/parakeet-tdt-0.6b-v3"
    var polishEnabled: Bool = false
    var polishModel: String = "google/gemini-3.1-flash-lite"
    var polishInstruction: String = "Clean up punctuation and remove filler words. Preserve meaning, tone, and language. Return only the edited text."
    var includeAppContext: Bool = false
    var insertAutomatically: Bool = true
    var keepRecordings: Bool = false
    var shortcut: SottoShortcut = .defaultShortcut
    var maximumRecordingSeconds: Int = 60
    var showFloatingBar: Bool = true
    var floatingBarPosition: FloatingBarPosition?
    var localModelDirectory: String = ""
    var localParakeetVariant: String = "v3"
    var localWhisperURL: String = "http://127.0.0.1:8080"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case backend, language, apiBaseURL, transcriptionModel, polishEnabled, polishModel, polishInstruction
        case includeAppContext, insertAutomatically, keepRecordings, shortcut, maximumRecordingSeconds
        case showFloatingBar, floatingBarPosition, localModelDirectory, localParakeetVariant, localWhisperURL
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decodeIfPresent(TranscriptionBackend.self, forKey: .backend) ?? backend
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        // Remote requests now use OpenRouter exclusively. Old provider keys are not reused.
        apiBaseURL = "https://openrouter.ai/api/v1"
        if let model = try values.decodeIfPresent(String.self, forKey: .transcriptionModel), model.contains("/") { transcriptionModel = model }
        if let model = try values.decodeIfPresent(String.self, forKey: .polishModel), model.contains("/") { polishModel = model }
        polishEnabled = try values.decodeIfPresent(Bool.self, forKey: .polishEnabled) ?? polishEnabled
        polishInstruction = try values.decodeIfPresent(String.self, forKey: .polishInstruction) ?? polishInstruction
        includeAppContext = try values.decodeIfPresent(Bool.self, forKey: .includeAppContext) ?? includeAppContext
        insertAutomatically = try values.decodeIfPresent(Bool.self, forKey: .insertAutomatically) ?? insertAutomatically
        keepRecordings = try values.decodeIfPresent(Bool.self, forKey: .keepRecordings) ?? keepRecordings
        shortcut = try values.decodeIfPresent(SottoShortcut.self, forKey: .shortcut) ?? shortcut
        maximumRecordingSeconds = try values.decodeIfPresent(Int.self, forKey: .maximumRecordingSeconds) ?? maximumRecordingSeconds
        showFloatingBar = try values.decodeIfPresent(Bool.self, forKey: .showFloatingBar) ?? showFloatingBar
        floatingBarPosition = try values.decodeIfPresent(FloatingBarPosition.self, forKey: .floatingBarPosition)
        localModelDirectory = try values.decodeIfPresent(String.self, forKey: .localModelDirectory) ?? localModelDirectory
        localParakeetVariant = try values.decodeIfPresent(String.self, forKey: .localParakeetVariant) ?? localParakeetVariant
        localWhisperURL = try values.decodeIfPresent(String.self, forKey: .localWhisperURL) ?? localWhisperURL
    }
}

struct RouterModel: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

struct DictationTiming: Codable, Equatable {
    var transcriptionMilliseconds: Double
    var polishMilliseconds: Double
    var insertionMilliseconds: Double
    var totalMilliseconds: Double
}

struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var phrase: String
    var replacement: String
}

struct DictationRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var originalText: String
    var text: String
    var duration: TimeInterval
    var language: String
    var applicationName: String?
    var audioPath: String?
    var timing: DictationTiming?
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

struct FocusedAppContext: Sendable {
    var applicationName: String
    var bundleIdentifier: String?
    var processIdentifier: Int32
    var selectedText: String?
    var surroundingText: String?
}

struct RecordedAudio: Sendable {
    let url: URL
    let duration: TimeInterval
}

enum InsertionOutcome: Equatable {
    case inserted
    case copiedToClipboard
}

enum SottoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
