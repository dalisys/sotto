import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioRecorderService: ObservableObject {
    @Published private(set) var level: Double = 0
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var recordingURL: URL?

    func start() async throws {
        cancel()
        try await MicrophonePermission.requireAccess()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SottoAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        do {
            let audioRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            audioRecorder.isMeteringEnabled = true
            guard audioRecorder.prepareToRecord() else {
                throw SottoError.message("Recording could not start. Check that a microphone is connected and selected in Sound settings.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard audioRecorder.record() else {
                throw SottoError.message("Recording could not start. Check that a microphone is connected and selected in Sound settings.")
            }
            recordingURL = url
            recorder = audioRecorder
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let decibels = Double(recorder.averagePower(forChannel: 0))
                    let measured = min(1, max(0, (decibels + 55) / 55))
                    let smoothing = measured > self.level ? 0.65 : 0.25
                    self.level += smoothing * (measured - self.level)
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() throws -> RecordedAudio {
        guard let recorder, let url = recordingURL else {
            throw SottoError.message("There is no active recording.")
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        recordingURL = nil
        meterTask?.cancel()
        meterTask = nil
        level = 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard duration >= 0.1, bytes > 44 else {
            try? FileManager.default.removeItem(at: url)
            throw SottoError.message("The recording was empty. Record a little longer and try again.")
        }
        return RecordedAudio(url: url, duration: duration)
    }

    func cancel() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        level = 0
    }
}
