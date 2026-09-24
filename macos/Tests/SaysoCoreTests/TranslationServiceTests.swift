import Foundation
import Testing
@testable import SaysoCore

@Test func compatibleRewriterNormalizesProviderReply() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VoiceEditURLProtocol.self]
    let rewriter = OpenAICompatibleRewriter(
        baseURL: try #require(URL(string: "https://api.example.com/v1")),
        apiKey: "test-key",
        model: "test-model",
        session: URLSession(configuration: configuration)
    )

    let rewrite = try await rewriter.rewrite(selection: "rough draft", instruction: "Make it crisp")

    #expect(rewrite == "Crisp draft.")
}

@Test func compatibleCleanerReturnsProviderCleanup() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CleanupURLProtocol.self]
    CleanupURLProtocol.recordedBody = nil
    let cleaner = OpenAICompatibleTranscriptCleaner(
        baseURL: try #require(URL(string: "https://api.example.com/v1")),
        apiKey: "test-key",
        model: "test-model",
        session: URLSession(configuration: configuration)
    )

    let cleaned = try await cleaner.clean("rough draft", language: .english, lexiconDirectives: ["Sayso"])

    #expect(cleaned == "Crisp draft.")
    let requestBody = try #require(CleanupURLProtocol.recordedBody)
    let request = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    let messages = try #require(request["messages"] as? [[String: String]])
    #expect(messages[0]["content"]?.contains("untrusted data") == true)
    #expect(messages[1]["content"]?.contains("{\"transcript\":\"rough draft\"}") == true)
}

@Test func compatibleCleanerRejectsImplausiblyLongReply() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VerboseCleanupURLProtocol.self]
    let cleaner = OpenAICompatibleTranscriptCleaner(
        baseURL: try #require(URL(string: "https://api.example.com/v1")),
        apiKey: "test-key",
        model: "test-model",
        session: URLSession(configuration: configuration)
    )

    await #expect(throws: SaysoError.self) {
        try await cleaner.clean("short", language: .english)
    }
}

@Test func compatibleAudioTranscriberPostsMultipartAudioWithLanguage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AudioTranscriptionURLProtocol.self]
    AudioTranscriptionURLProtocol.recordedRequest = nil
    AudioTranscriptionURLProtocol.recordedBody = nil
    let fileURL = FileManager.default.temporaryDirectory.appending(path: "sayso-audio-\(UUID().uuidString).m4a")
    try Data([0x01, 0x02, 0x03]).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let transcriber = OpenAICompatibleAudioTranscriber(
        configuration: .init(
            baseURL: try #require(URL(string: "https://api.example.com/v1")),
            apiKey: "test-key",
            model: "test-transcriber"
        ),
        session: URLSession(configuration: configuration)
    )

    let text = try await transcriber.transcribe(fileURL: fileURL, language: .hindi)

    #expect(text == "नमस्ते")
    let request = try #require(AudioTranscriptionURLProtocol.recordedRequest)
    #expect(request.url?.path == "/v1/audio/transcriptions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let body = String(decoding: try #require(AudioTranscriptionURLProtocol.recordedBody), as: UTF8.self)
    #expect(body.contains("name=\"model\""))
    #expect(body.contains("test-transcriber"))
    #expect(body.contains("name=\"language\""))
    #expect(body.contains("\r\nhi\r\n"))
    #expect(body.contains("filename=\"dictation.m4a\""))
}

private final class VoiceEditURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"\\\"Crisp draft.\\\"\"}}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CleanupURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recordedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedBody = Self.body(of: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"Crisp draft.\"}}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class VerboseCleanupURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = String(repeating: "x", count: 40)
        client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"\(text)\"}}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AudioTranscriptionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recordedRequest: URLRequest?
    nonisolated(unsafe) static var recordedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.example.com" && request.url?.path == "/v1/audio/transcriptions"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequest = request
        Self.recordedBody = Self.body(of: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"नमस्ते\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
