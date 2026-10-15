import AppKit
import AVFoundation
import Foundation

enum SottoDiagnostics {
    @MainActor
    static func run() -> Never {
        let result: [String: Any] = [
            "app": "Sotto", "version": "0.3.1",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "microphoneAuthorization": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "backends": TranscriptionBackend.allCases.map(\.rawValue),
            "cloudEndpoint": CloudTranscriptionClient.baseURL,
            "recordingPerformed": false, "cloudRequestPerformed": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(0)
    }
}
