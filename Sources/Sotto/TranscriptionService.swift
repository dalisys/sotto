import Foundation

@MainActor
final class TranscriptionService {
    private let cloud: CloudTranscriptionClient
    private let local: LocalTranscriptionService

    init(cloud: CloudTranscriptionClient = CloudTranscriptionClient(), local: LocalTranscriptionService? = nil) {
        self.cloud = cloud
        self.local = local ?? LocalTranscriptionService()
    }

    func transcribe(audio: RecordedAudio, settings: UserSettings, apiKey: String?, vocabulary: [DictionaryEntry]) async throws -> String {
        try Task.checkCancellation()
        if settings.backend == .openRouter {
            return try await cloud.transcribe(audio: audio, settings: settings, apiKey: apiKey ?? "", vocabulary: vocabulary)
        }
        return try await local.transcribe(audio: audio, settings: settings, vocabulary: vocabulary)
    }

    func onDeviceModelStatus(settings: UserSettings) async -> LocalModelStatus { await local.status(settings: settings) }
    func prepareOnDevice(settings: UserSettings) async throws { try await local.prepare(settings: settings) }
    func warmUp(settings: UserSettings) async throws { try await local.warmUp(settings: settings) }

    func polish(text: String, settings: UserSettings, apiKey: String?, context: FocusedAppContext?) async throws -> String {
        guard settings.polishEnabled else { return text }
        return try await cloud.polish(text: text, settings: settings, apiKey: apiKey ?? "", context: context)
    }
}
