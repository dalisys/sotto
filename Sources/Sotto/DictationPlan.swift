import Foundation

struct DictationPlan {
    let settings: UserSettings
    let apiKey: String?
    let notice: String?

    init(settings: UserSettings, apiKey: String?) throws {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableKey = key?.isEmpty == false ? key : nil
        guard settings.backend != .openRouter || availableKey != nil else {
            throw SottoError.message("OpenRouter transcription needs an API key. Add one in Settings, or choose local Parakeet.")
        }
        var effective = settings
        if settings.backend.isLocal && settings.polishEnabled && availableKey == nil {
            effective.polishEnabled = false
            notice = "Local dictation is ready. Optional OpenRouter cleanup was skipped because no API key is saved."
        } else { notice = nil }
        self.settings = effective
        self.apiKey = availableKey
    }
}
