import Foundation
import XCTest
@testable import Sotto

final class OpenRouterClientTests: XCTestCase {
    private var session: URLSession!
    private var audioURL: URL!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderURLProtocol.self]
        session = URLSession(configuration: configuration)
        audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("RIFF-test-audio-bytes".utf8).write(to: audioURL)
        ProviderURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: audioURL)
        ProviderURLProtocol.reset()
    }

    private var audio: RecordedAudio { RecordedAudio(url: audioURL, duration: 1) }
    private var client: CloudTranscriptionClient { CloudTranscriptionClient(session: session, timeout: 0.2) }

    private func routerSettings() -> UserSettings {
        var settings = UserSettings()
        settings.apiBaseURL = "https://openrouter.ai/api/v1"
        settings.transcriptionModel = "nvidia/parakeet-tdt-0.6b-v3"
        settings.polishModel = "google/gemini-3.1-flash-lite"
        return settings
    }

    func testTranscriptionJSONContainsBase64AudioVendorModelAndLanguage() async throws {
        ProviderURLProtocol.configure(status: 200, body: #"{"text":"  Hello Sotto.  "}"#)
        var settings = routerSettings()
        settings.language = "de-DE"
        settings.apiBaseURL = "https://openrouter.ai/api/v1/"
        let result = try await client.transcribe(audio: audio, settings: settings, apiKey: "test-placeholder", vocabulary: [DictionaryEntry(phrase: "Sotto", replacement: "")])
        XCTAssertEqual(result, "Hello Sotto.")
        let request = try XCTUnwrap(ProviderURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "nvidia/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(json["language"] as? String, "de")
        let input = try XCTUnwrap(json["input_audio"] as? [String: String])
        XCTAssertEqual(input["format"], "wav")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(input["data"])), try Data(contentsOf: audioURL))
        XCTAssertFalse(try XCTUnwrap(input["data"]).hasPrefix("data:"))
        XCTAssertNil(json["prompt"], "A generic prompt is not part of OpenRouter's STT contract")
        XCTAssertNil(json["file"])
    }

    func testHTTPFailureDoesNotExposeServerBodyOrCredentials() async throws {
        ProviderURLProtocol.configure(status: 401, body: #"{"error":"private transcript secret test-placeholder"}"#)
        do {
            _ = try await client.transcribe(audio: audio, settings: routerSettings(), apiKey: "test-placeholder", vocabulary: [])
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("key or permissions"))
            XCTAssertFalse(error.localizedDescription.contains("private transcript"))
            XCTAssertFalse(error.localizedDescription.contains("test-placeholder"))
        }
    }

    func testWhitespaceOnlySpeechProducesUsefulError() async throws {
        ProviderURLProtocol.configure(status: 200, body: #"{"text":" \n "}"#)
        do {
            _ = try await client.transcribe(audio: audio, settings: routerSettings(), apiKey: "test-placeholder", vocabulary: [])
            XCTFail("Expected empty speech error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No speech was recognized")) }
    }

    func testMalformedResponseProducesUsefulError() async throws {
        ProviderURLProtocol.configure(status: 200, body: "not json")
        do {
            _ = try await client.transcribe(audio: audio, settings: routerSettings(), apiKey: "test-placeholder", vocabulary: [])
            XCTFail("Expected malformed response error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalid transcription JSON")) }
    }

    func testTimeoutProducesUsefulError() async throws {
        ProviderURLProtocol.configure(error: URLError(.timedOut))
        do {
            _ = try await client.transcribe(audio: audio, settings: routerSettings(), apiKey: "test-placeholder", vocabulary: [])
            XCTFail("Expected timeout error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    func testCancellationStopsPendingURLRequest() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request cancelled")
        ProviderURLProtocol.configurePending(started: { started.fulfill() }, stopped: { stopped.fulfill() })
        let localClient = client
        let localAudio = audio
        let task = Task { try await localClient.transcribe(audio: localAudio, settings: routerSettings(), apiKey: "test-placeholder", vocabulary: []) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testUnsafeEndpointRejectedBeforeRequest() async throws {
        for endpoint in ["https://api.openai.com/v1", "http://localhost:8000/v1", "http://openrouter.ai/api/v1", "https://user:pass@openrouter.ai/api/v1", "https://openrouter.ai.evil.example/api/v1", "https://openrouter.ai/api/v1?key=secret", "https://openrouter.ai/api/v1/other", "file:///tmp/test"] {
            var settings = routerSettings()
            settings.apiBaseURL = endpoint
            do {
                _ = try await client.transcribe(audio: audio, settings: settings, apiKey: "test-placeholder", vocabulary: [])
                XCTFail("Expected invalid endpoint error for \(endpoint)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Cloud models must use OpenRouter")) }
        }
        XCTAssertNil(ProviderURLProtocol.lastRequest)
    }

    func testMissingKeyRejectedBeforeRequest() async throws {
        do {
            _ = try await client.transcribe(audio: audio, settings: routerSettings(), apiKey: " \n", vocabulary: [])
            XCTFail("Expected missing key error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Save a valid OpenRouter API key")) }
        XCTAssertNil(ProviderURLProtocol.lastRequest)
    }

    func testPolishOmitsAppContextUntilEnabled() async throws {
        ProviderURLProtocol.configure(status: 200, body: #"{"choices":[{"message":{"content":"Edited text."}}]}"#)
        var settings = routerSettings()
        let context = FocusedAppContext(applicationName: "Private App", bundleIdentifier: nil, processIdentifier: 1, selectedText: "PRIVATE SELECTED", surroundingText: "PRIVATE SURROUNDING")
        let result = try await client.polish(text: "Edit me", settings: settings, apiKey: "test-placeholder", context: context)
        XCTAssertEqual(result, "Edited text.")
        var request = try XCTUnwrap(ProviderURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
        var body = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertFalse(body.contains("PRIVATE"))
        XCTAssertFalse(body.contains("Private App"))
        settings.includeAppContext = true
        _ = try await client.polish(text: "Edit me", settings: settings, apiKey: "test-placeholder", context: context)
        request = try XCTUnwrap(ProviderURLProtocol.lastRequest)
        body = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertTrue(body.contains("PRIVATE SELECTED"))
        XCTAssertTrue(body.contains("PRIVATE SURROUNDING"))
    }

    func testLegacyUnqualifiedModelIDsAreRejectedBeforeRequest() async throws {
        for model in ["gpt-4o-mini-transcribe", "", "nvidia/", "/model", "vendor/model?token=secret", "vendor/model/extra"] {
            var settings = routerSettings()
            settings.transcriptionModel = model
            do {
                _ = try await client.transcribe(audio: audio, settings: settings, apiKey: "test-placeholder", vocabulary: [])
                XCTFail("Expected vendor/model validation")
            } catch { XCTAssertTrue(error.localizedDescription.contains("vendor/model")) }
        }
        XCTAssertNil(ProviderURLProtocol.lastRequest)
    }

    func testLegacyPolishModelIsRejectedBeforeRequest() async throws {
        var settings = routerSettings()
        settings.polishModel = "gpt-4.1-mini"
        do {
            _ = try await client.polish(text: "Private", settings: settings, apiKey: "test-placeholder", context: nil)
            XCTFail("Expected vendor/model validation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("vendor/model")) }
        XCTAssertNil(ProviderURLProtocol.lastRequest)
    }

    func testAutomaticLanguageOmitsHint() async throws {
        ProviderURLProtocol.configure(body: #"{"text":"Hello"}"#)
        var settings = routerSettings()
        settings.language = "auto"
        _ = try await client.transcribe(audio: audio, settings: settings, apiKey: "test-placeholder", vocabulary: [])
        let request = try XCTUnwrap(ProviderURLProtocol.lastRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertNil(json["language"])
    }

    func testTranscriptionDiscoveryUsesPublicModalityFilterAndQualifiedIDs() async throws {
        ProviderURLProtocol.configure(body: #"{"data":[{"id":"nvidia/parakeet-tdt-0.6b-v3","name":"Parakeet"},{"id":"unqualified-old-model","name":"Old"}]}"#)
        let models = try await client.fetchTranscriptionModels()
        XCTAssertEqual(models.map(\.id), ["nvidia/parakeet-tdt-0.6b-v3"])
        let request = try XCTUnwrap(ProviderURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models?output_modalities=transcription")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
    }

    func testPolishDiscoveryFiltersModelsWithoutTextInput() async throws {
        ProviderURLProtocol.configure(body: #"{"data":[{"id":"vendor/audio","name":"Audio","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},{"id":"google/gemini-3.1-flash-lite","name":"Gemini","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}"#)
        let models = try await client.fetchPolishModels()
        XCTAssertEqual(models.map(\.id), ["google/gemini-3.1-flash-lite"])
        XCTAssertEqual(ProviderURLProtocol.lastRequest?.url?.query, "output_modalities=text")
        XCTAssertNil(ProviderURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testKeyVerificationUsesReadOnlyKeyEndpoint() async throws {
        ProviderURLProtocol.configure(body: #"{"data":{"limit_remaining":12.5,"is_free_tier":false,"usage":0.25}}"#)
        let status = try await client.verifyAPIKey("test-placeholder")
        XCTAssertEqual(status.limitRemaining, 12.5)
        XCTAssertEqual(status.isFreeTier, false)
        XCTAssertEqual(status.usage, 0.25)
        let request = try XCTUnwrap(ProviderURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
        XCTAssertNil(request.httpBody)
    }

    func testExhaustedCreditsProduceUsefulErrorWithoutEchoingBody() async throws {
        ProviderURLProtocol.configure(status: 402, body: #"{"error":"secret"}"#)
        do { _ = try await client.verifyAPIKey("test-placeholder"); XCTFail("Expected exhausted credits") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("credits"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

}

private final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseStatus = 200
    private static var responseBody = Data()
    private static var responseError: Error?
    private static var isPending = false
    private static var startedHandler: (() -> Void)?
    private static var stoppedHandler: (() -> Void)?
    private static var capturedRequest: URLRequest?

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequest
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responseStatus = 200; responseBody = Data(); responseError = nil
        isPending = false; startedHandler = nil; stoppedHandler = nil; capturedRequest = nil
    }
    static func configure(status: Int = 200, body: String = "", error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        responseStatus = status; responseBody = Data(body.utf8); responseError = error
    }
    static func configurePending(started: @escaping () -> Void, stopped: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        isPending = true; startedHandler = started; stoppedHandler = stopped
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession delivers request bodies as streams to URLProtocol on macOS.
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.capturedRequest = captured
        let status = Self.responseStatus, body = Self.responseBody, error = Self.responseError
        let pending = Self.isPending, started = Self.startedHandler
        Self.lock.unlock()
        started?()
        if pending { return }
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock()
        let stopped = Self.stoppedHandler
        Self.lock.unlock()
        stopped?()
    }
}
