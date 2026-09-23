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
    let cleaner = OpenAICompatibleTranscriptCleaner(
        baseURL: try #require(URL(string: "https://api.example.com/v1")),
        apiKey: "test-key",
        model: "test-model",
        session: URLSession(configuration: configuration)
    )

    let cleaned = try await cleaner.clean("rough draft", language: .english, lexiconDirectives: ["Sayso"])

    #expect(cleaned == "Crisp draft.")
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
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"Crisp draft.\"}}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
