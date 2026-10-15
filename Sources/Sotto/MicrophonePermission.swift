import AVFoundation

enum MicrophonePermission {
    static func request(status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
                        prompt: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) async -> Bool {
        switch status {
        case .authorized: return true
        case .notDetermined: return await prompt()
        default: return false
        }
    }

    static func requireAccess() async throws {
        let granted = await request()
        try Task.checkCancellation()
        guard granted else {
            throw SottoError.message("Microphone access is required. Click Enable Microphone in Settings, then allow Sotto in macOS Privacy & Security → Microphone.")
        }
    }
}
