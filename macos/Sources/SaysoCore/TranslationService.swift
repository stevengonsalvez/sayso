import Foundation

public protocol Translating: Sendable {
    func translate(_ text: String, from: DictationLanguage, to: DictationLanguage) async throws -> String
}

public struct OpenAICompatibleTranslator: Translating {
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func translate(_ text: String, from: DictationLanguage, to: DictationLanguage) async throws -> String {
        guard from != to, !text.isEmpty else { return text }
        let endpoint = baseURL.appending(path: "chat/completions")
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "Translate exactly. Preserve meaning, punctuation, names, code, and line breaks. Return only translated text."),
                .init(role: "user", content: "From \(from.displayName) to \(to.displayName):\n\(text)"),
            ],
            temperature: 0
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw SaysoError.unavailable("Translation provider")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let result = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw SaysoError.unavailable("Translation response")
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
