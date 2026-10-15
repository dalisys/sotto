import Foundation

/// Speaks whisper.cpp's native /inference protocol to a user-managed, warm local server.
/// It never starts processes, downloads weights, supplies API keys, or follows redirects.
final class LocalWhisperClient: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval
    private let redirectGuard = LocalWhisperRedirectGuard()

    init(session: URLSession? = nil, timeout: TimeInterval = 120) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration)
        }
        self.timeout = timeout
    }

    static func endpoint(baseURL: String, path: String) throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value),
              parts.scheme == "http" || parts.scheme == "https",
              let host = parts.host?.lowercased(), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw SottoError.message("Local Whisper requires a loopback URL such as http://127.0.0.1:8080. Remote servers, credentials, and query parameters are not supported.")
        }
        // Accept either the server base or its native inference URL, including a request-path prefix.
        var prefix = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix == "inference" { prefix = "" }
        else if prefix.hasSuffix("/inference") { prefix.removeLast("/inference".count) }
        parts.path = "/" + ([prefix, path].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = parts.url else { throw SottoError.message("The Local Whisper server URL is invalid.") }
        return url
    }

    func isReady(baseURL: String) async throws -> Bool {
        try Task.checkCancellation()
        var request = URLRequest(url: try Self.endpoint(baseURL: baseURL, path: "health"))
        request.timeoutInterval = min(3, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { return false }
        guard response.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return health.status == "ok"
    }

    func transcribe(audio: RecordedAudio, baseURL: String, language: String, vocabulary: [DictionaryEntry]) async throws -> String {
        try Task.checkCancellation()
        let endpoint = try Self.endpoint(baseURL: baseURL, path: "inference")
        guard audio.url.isFileURL,
              let size = try audio.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 64 * 1_024 * 1_024 else {
            throw SottoError.message("Local Whisper requires a nonempty WAV recording smaller than 64 MB.")
        }
        let audioData = try Data(contentsOf: audio.url)
        let boundary = "SottoLocal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("temperature", "0.0")
        let languageCode = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "auto"
        field("language", languageCode)
        let prompt = vocabulary.map(\.phrase).filter { !$0.isEmpty }.prefix(100).joined(separator: ", ")
        if !prompt.isEmpty { field("prompt", String(prompt.prefix(2_000))) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else {
            throw SottoError.message("The Local Whisper server returned an invalid response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            // Avoid reflecting arbitrary server output or transcript content into diagnostic strings.
            throw SottoError.message("Local Whisper returned HTTP \(response.statusCode). Check that whisper-server has a model loaded and exposes /inference.")
        }
        guard let decoded = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw SottoError.message("Local Whisper did not return a JSON transcript. Use a whisper.cpp server with its native /inference endpoint.")
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SottoError.message("Local Whisper did not recognize any speech. Try again closer to the microphone.") }
        try Task.checkCancellation()
        return text
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let response = try await session.data(for: request, delegate: redirectGuard)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? URLError {
                if error.code == .timedOut { throw SottoError.message("Local Whisper timed out. Use a smaller model or a shorter recording.") }
                throw SottoError.message("Could not reach Local Whisper. Start whisper-server on 127.0.0.1:8080 with a model loaded, then prepare it in Settings.")
            }
            throw error
        }
    }

    private struct Transcript: Decodable { let text: String }
    private struct Health: Decodable { let status: String }
}

private final class LocalWhisperRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
