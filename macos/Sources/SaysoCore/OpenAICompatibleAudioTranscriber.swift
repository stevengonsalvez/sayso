import Foundation

public struct OpenAICompatibleAudioTranscriptionConfiguration: Sendable {
    public let baseURL: URL
    public let apiKey: String
    public let model: String

    public init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

public struct OpenAICompatibleAudioTranscriber: Sendable {
    private static let maximumAudioBytes = 512 * 1024 * 1024

    private let configuration: OpenAICompatibleAudioTranscriptionConfiguration
    private let session: URLSession

    public init(
        configuration: OpenAICompatibleAudioTranscriptionConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func transcribe(fileURL: URL, language: DictationLanguage) async throws -> String {
        guard ProviderEndpointPolicy.allows(configuration.baseURL) else {
            throw SaysoError.unavailable("Transcription provider must use HTTPS")
        }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw SaysoError.unavailable("Transcription model") }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SaysoError.invalidAction("Choose an audio file, not a folder.")
        }
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumAudioBytes {
            throw SaysoError.invalidAction("Audio file exceeds \(Self.maximumAudioBytes) bytes")
        }

        let boundary = "Sayso-\(UUID().uuidString)"
        var request = URLRequest(url: configuration.baseURL.appending(path: "audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeBody(
            boundary: boundary,
            model: model,
            language: language,
            fileURL: fileURL
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw SaysoError.unavailable("Transcription provider")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SaysoError.unavailable("Transcription response") }
        return text
    }

    private static func makeBody(
        boundary: String,
        model: String,
        language: DictationLanguage,
        fileURL: URL
    ) throws -> Data {
        var body = Data()
        appendField(named: "model", value: model, boundary: boundary, to: &body)
        if let languageCode = languageCode(for: language) {
            appendField(named: "language", value: languageCode, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL, options: .mappedIfSafe))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func appendField(named name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }

    private static func languageCode(for language: DictationLanguage) -> String? {
        switch language {
        case .automatic: nil
        case .english: "en"
        case .hindi: "hi"
        case .tamil: "ta"
        case .malayalam: "ml"
        case .bengali: "bn"
        case .gujarati: "gu"
        case .kannada: "kn"
        case .marathi: "mr"
        case .punjabi: "pa"
        case .telugu: "te"
        case .urdu: "ur"
        }
    }

    private struct Response: Decodable {
        let text: String
    }
}
