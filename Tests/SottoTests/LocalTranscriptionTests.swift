import Foundation
import XCTest
@testable import Sotto

final class LocalWhisperClientTests: XCTestCase {
    private var session: URLSession!
    private var audioURL: URL!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalWhisperTestProtocol.self]
        session = URLSession(configuration: configuration)
        audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("RIFF-owned-test-audio".utf8).write(to: audioURL)
        LocalWhisperTestProtocol.configure(status: 200, body: #"{"text":" Local result. "}"#)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: audioURL)
        LocalWhisperTestProtocol.configure(status: 200, body: "{}")
    }

    func testLoopbackValidationRejectsRemoteCredentialsAndQuery() throws {
        for value in ["https://api.openai.com", "http://localhost.evil.test:8080", "http://192.168.1.2:8080", "file:///tmp/whisper", "http://user:secret@127.0.0.1:8080", "http://127.0.0.1:8080?token=secret", "http://127.0.0.1:8080/#fragment"] {
            XCTAssertThrowsError(try LocalWhisperClient.endpoint(baseURL: value, path: "inference"), value)
        }
        XCTAssertEqual(try LocalWhisperClient.endpoint(baseURL: "http://127.0.0.1:8080", path: "inference").absoluteString, "http://127.0.0.1:8080/inference")
        XCTAssertEqual(try LocalWhisperClient.endpoint(baseURL: "http://[::1]:8080/inference", path: "health").absoluteString, "http://[::1]:8080/health")
        XCTAssertEqual(try LocalWhisperClient.endpoint(baseURL: "http://localhost:8080/speech/inference/", path: "health").path, "/speech/health")
    }

    func testNativeWhisperMultipartDoesNotUseCloudAuthenticationOrModelReload() async throws {
        let client = LocalWhisperClient(session: session)
        let result = try await client.transcribe(audio: RecordedAudio(url: audioURL, duration: 1),
                                                 baseURL: "http://127.0.0.1:8080", language: "de-DE",
                                                 vocabulary: [DictionaryEntry(phrase: "Sotto", replacement: "")])
        XCTAssertEqual(result, "Local result.")
        let request = try XCTUnwrap(LocalWhisperTestProtocol.request)
        XCTAssertEqual(request.url?.path, "/inference")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(String(data: LocalWhisperTestProtocol.body, encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"recording.wav\""))
        XCTAssertTrue(body.contains("RIFF-owned-test-audio"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nSotto\r\n"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        XCTAssertFalse(body.contains("name=\"model\""))
    }

    func testHealthChecksServerModelReadiness() async throws {
        let client = LocalWhisperClient(session: session)
        LocalWhisperTestProtocol.configure(status: 200, body: #"{"status":"ok"}"#)
        let ready = try await client.isReady(baseURL: "http://127.0.0.1:8080")
        XCTAssertTrue(ready)
        XCTAssertEqual(LocalWhisperTestProtocol.request?.url?.path, "/health")
        LocalWhisperTestProtocol.configure(status: 503, body: #"{"status":"loading model"}"#)
        let loading = try await client.isReady(baseURL: "http://127.0.0.1:8080")
        XCTAssertFalse(loading)
    }

    func testInvalidEmptyAndErrorResponsesFailWithoutReflectingServerContent() async throws {
        for (status, body) in [(200, "not JSON"), (200, #"{"text":" "}"#), (500, "private transcript should not appear in error")] {
            LocalWhisperTestProtocol.configure(status: status, body: body)
            do {
                _ = try await LocalWhisperClient(session: session).transcribe(audio: RecordedAudio(url: audioURL, duration: 1),
                                                                             baseURL: "http://127.0.0.1:8080", language: "en-US", vocabulary: [])
                XCTFail("Expected invalid response failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private transcript")) }
        }
    }

    func testCancellationStopsRequestAndReturnsCancellationError() async throws {
        LocalWhisperTestProtocol.configure(status: 200, body: "{}", hold: true)
        let client = LocalWhisperClient(session: session)
        let audio = RecordedAudio(url: audioURL, duration: 1)
        let operation = Task { try await client.transcribe(audio: audio, baseURL: "http://127.0.0.1:8080", language: "en-US", vocabulary: []) }
        for _ in 0..<30 {
            if LocalWhisperTestProtocol.request != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor
final class LocalParakeetTests: XCTestCase {
    func testConfigurationSeparatesModelVariantsAndRequiresAbsoluteStorageRoot() throws {
        var settings = UserSettings()
        settings.localModelDirectory = "/tmp/sotto-owned-model-tests"
        settings.localParakeetVariant = "v3"
        let v3 = try LocalParakeetConfiguration(settings: settings)
        settings.localParakeetVariant = "redux"
        let redux = try LocalParakeetConfiguration(settings: settings)
        XCTAssertNotEqual(v3.directory, redux.directory)
        XCTAssertNotEqual(v3.key, redux.key)
        settings.localParakeetVariant = "unsupported"
        XCTAssertThrowsError(try LocalParakeetConfiguration(settings: settings))
        settings.localParakeetVariant = "v3"
        settings.localModelDirectory = "relative/path"
        XCTAssertThrowsError(try LocalParakeetConfiguration(settings: settings))
    }

    func testWarmUpMissingModelsFailsLocallyWithoutCreatingStorage() async throws {
        var settings = UserSettings()
        settings.backend = .localParakeet
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-no-download-\(UUID().uuidString)")
        settings.localModelDirectory = root.path
        let service = LocalTranscriptionService()
        let status = await service.status(settings: settings)
        XCTAssertEqual(status, .notPrepared)
        do { try await service.warmUp(settings: settings); XCTFail("Missing weights must not download") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not prepared")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// Opt-in only: weights and fixture must be explicitly supplied in an owned benchmark directory.
    func testParakeetFixtureBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOTTO_RUN_LOCAL_BENCHMARK"] == "1",
              let modelDirectory = environment["SOTTO_BENCHMARK_MODEL_DIR"],
              let fixture = environment["SOTTO_BENCHMARK_AUDIO"] else {
            throw XCTSkip("Set explicit model and audio fixture paths to run the real CoreML benchmark.")
        }
        var settings = UserSettings()
        settings.backend = .localParakeet
        settings.localParakeetVariant = environment["SOTTO_BENCHMARK_VARIANT"] ?? "v3"
        settings.localModelDirectory = modelDirectory
        settings.language = "en-US"
        let service = LocalTranscriptionService()
        let preparationStart = Date()
        try await service.prepare(settings: settings)
        print("SOTTO_BENCHMARK prepare/warm seconds=\(Date().timeIntervalSince(preparationStart)) variant=\(settings.localParakeetVariant)")
        let audio = RecordedAudio(url: URL(fileURLWithPath: fixture), duration: 11)
        for iteration in 1...3 {
            let start = Date()
            let text = try await service.transcribe(audio: audio, settings: settings, vocabulary: [])
            print("SOTTO_BENCHMARK warm run=\(iteration) seconds=\(Date().timeIntervalSince(start)) text=\(text)")
            XCTAssertFalse(text.isEmpty)
        }
    }
}

private final class LocalWhisperTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedRequest: URLRequest?
    private static var storedBody = Data()
    private static var status = 200
    private static var responseBody = Data()
    private static var hold = false
    static var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return storedRequest }
    static var body: Data { lock.lock(); defer { lock.unlock() }; return storedBody }

    static func configure(status: Int, body: String, hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.responseBody = Data(body.utf8)
        self.storedRequest = nil
        self.storedBody = Data()
        self.hold = hold
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var capturedBody = request.httpBody ?? Data()
        if capturedBody.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                capturedBody.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.lock.lock()
        Self.storedRequest = request
        Self.storedBody = capturedBody
        let code = Self.status
        let data = Self.responseBody
        let shouldHold = Self.hold
        Self.lock.unlock()
        guard !shouldHold else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
