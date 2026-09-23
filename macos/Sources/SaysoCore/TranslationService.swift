import Foundation
import SpeakCore

public protocol Translating: Sendable {
    func translate(_ text: String, from: DictationLanguage, to: DictationLanguage) async throws -> String
}

public struct OpenAICompatibleTranslator: Translating {
    private let client: OpenAICompatibleChatClient

    public init(baseURL: URL, apiKey: String, model: String, session: URLSession = .shared) {
        client = .init(baseURL: baseURL, apiKey: apiKey, model: model, session: session)
    }

    public func translate(_ text: String, from: DictationLanguage, to: DictationLanguage) async throws -> String {
        guard from != to, !text.isEmpty else { return text }
        return try await client.complete(
            systemPrompt: "Translate exactly. Preserve meaning, punctuation, names, code, and line breaks. Return only translated text.",
            userPrompt: "From \(from.displayName) to \(to.displayName):\n\(text)",
            failureLabel: "Translation"
        )
    }
}

public struct OpenAICompatibleRewriter: Sendable {
    private let client: OpenAICompatibleChatClient

    public init(baseURL: URL, apiKey: String, model: String, session: URLSession = .shared) {
        client = .init(baseURL: baseURL, apiKey: apiKey, model: model, session: session)
    }

    public func rewrite(selection: String, instruction: String) async throws -> String {
        let instruction = VoiceEditPolicy.normalizedInstruction(instruction)
        guard !selection.isEmpty, !instruction.isEmpty else {
            throw SaysoError.unavailable("Voice edit instruction")
        }
        let reply = try await client.complete(
            systemPrompt: VoiceEditPolicy.systemPrompt,
            userPrompt: VoiceEditPolicy.userMessage(selection: selection, instruction: instruction),
            failureLabel: "Voice edit"
        )
        let rewrite = VoiceEditPolicy.normalizedRewrite(reply, original: selection, instruction: instruction)
        guard !rewrite.isEmpty else { throw SaysoError.unavailable("Voice edit response") }
        return rewrite
    }
}

private struct OpenAICompatibleChatClient: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String, model: String, session: URLSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func complete(systemPrompt: String, userPrompt: String, failureLabel: String) async throws -> String {
        let body = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: systemPrompt), .init(role: "user", content: userPrompt)],
            temperature: 0
        )
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw SaysoError.unavailable("\(failureLabel) provider")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let result = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw SaysoError.unavailable("\(failureLabel) response")
        }
        return result
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Int
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
        let choices: [Choice]
    }
}
