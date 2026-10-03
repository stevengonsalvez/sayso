import Foundation
import SpeakCore

public struct OpenAICompatibleAudioTranscriptionConfiguration: Sendable {
    public let baseURL: URL
    public let apiKey: String
    public let model: String
    public let providerId: String

    public init(baseURL: URL, apiKey: String, model: String, providerId: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        if !providerId.isEmpty {
            self.providerId = providerId
        } else if let prefix = model.split(separator: "/").first, !prefix.isEmpty {
            self.providerId = String(prefix)
        } else {
            self.providerId = "openai"
        }
    }

    public init(providerId: String, baseURL: URL, apiKey: String, model: String) {
        self.providerId = providerId
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
        let provider = configuration.providerId.lowercased()
        if provider == "deepgram" || configuration.model.contains("deepgram") {
            return try await transcribeDeepgram(fileURL: fileURL, language: language)
        } else if provider == "assemblyai" || configuration.model.contains("assemblyai") {
            return try await transcribeAssemblyAI(fileURL: fileURL, language: language)
        } else if provider == "elevenlabs" || configuration.model.contains("elevenlabs") {
            return try await transcribeElevenLabs(fileURL: fileURL, language: language)
        } else if provider == "mistral" || configuration.model.contains("mistral") || configuration.model.contains("voxtral") {
            return try await transcribeMistral(fileURL: fileURL, language: language)
        } else if provider == "cartesia" || configuration.model.contains("cartesia") {
            let lang = Self.languageCode(for: language)
            let res = try await CartesiaBatchClient(session: session).transcribeFile(at: fileURL, apiKey: configuration.apiKey, language: lang)
            return res.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else if provider == "gladia" || configuration.model.contains("gladia") {
            let lang = Self.languageCode(for: language)
            let model = configuration.model.isEmpty ? "default" : configuration.model
            let res = try await GladiaBatchClient(session: session).transcribeFile(at: fileURL, apiKey: configuration.apiKey, model: model, language: lang)
            return res.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else if provider == "speechmatics" || configuration.model.contains("speechmatics") {
            let lang = Self.languageCode(for: language)
            let res = try await SpeechmaticsBatchClient(session: session).transcribeFile(at: fileURL, apiKey: configuration.apiKey, model: configuration.model, language: lang)
            return res.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else if provider == "xai" || configuration.model.contains("xai") {
            let lang = Self.languageCode(for: language)
            let res = try await XAIBatchTranscriptionClient(session: session).transcribeFile(at: fileURL, apiKey: configuration.apiKey, language: lang)
            return res.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else if provider == "azure" || configuration.model.contains("azure") {
            let lang = Self.languageCode(for: language)
            let endpoint = configuration.baseURL.absoluteString
            let res = try await AzureBatchTranscriptionClient(session: session).transcribeFile(
                at: fileURL,
                credentials: configuration.apiKey,
                endpoint: endpoint,
                model: configuration.model.isEmpty ? "default" : configuration.model,
                language: lang
            )
            return res.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else {
            return try await transcribeOpenAICompatible(fileURL: fileURL, language: language)
        }
    }

    private func transcribeOpenAICompatible(fileURL: URL, language: DictationLanguage) async throws -> String {
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

    private func transcribeDeepgram(fileURL: URL, language: DictationLanguage) async throws -> String {
        let cleanModel = configuration.model
            .replacingOccurrences(of: "deepgram/", with: "")
            .replacingOccurrences(of: "-streaming", with: "")
        var components = URLComponents(url: configuration.baseURL.appending(path: "listen"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "model", value: cleanModel.isEmpty ? "nova-3" : cleanModel),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "numerals", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ]
        if let langCode = Self.languageCode(for: language) {
            queryItems.append(URLQueryItem(name: "language", value: langCode))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw SaysoError.unavailable("Deepgram endpoint URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: fileURL)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SaysoError.unavailable("Deepgram returned HTTP \(code): \(body)")
        }
        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        guard let transcript = decoded.results?.channels.first?.alternatives.first?.transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct DeepgramResponse: Decodable {
        struct Results: Decodable {
            struct Channel: Decodable {
                struct Alternative: Decodable {
                    let transcript: String
                }
                let alternatives: [Alternative]
            }
            let channels: [Channel]
        }
        let results: Results?
    }

    private func transcribeAssemblyAI(fileURL: URL, language: DictationLanguage) async throws -> String {
        var uploadReq = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue(configuration.apiKey, forHTTPHeaderField: "Authorization")
        uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadReq.httpBody = try Data(contentsOf: fileURL)
        let (upData, upResp) = try await session.data(for: uploadReq)
        guard let httpUp = upResp as? HTTPURLResponse, (200 ..< 300).contains(httpUp.statusCode) else {
            throw SaysoError.unavailable("AssemblyAI audio upload failed")
        }
        struct AssemblyUpload: Decodable { let upload_url: String }
        let uploadResult = try JSONDecoder().decode(AssemblyUpload.self, from: upData)

        var subReq = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        subReq.httpMethod = "POST"
        subReq.setValue(configuration.apiKey, forHTTPHeaderField: "Authorization")
        subReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var params: [String: Any] = ["audio_url": uploadResult.upload_url]
        if let lang = Self.languageCode(for: language) {
            params["language_code"] = lang
        }
        subReq.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (subData, subResp) = try await session.data(for: subReq)
        guard let httpSub = subResp as? HTTPURLResponse, (200 ..< 300).contains(httpSub.statusCode) else {
            throw SaysoError.unavailable("AssemblyAI transcript submit failed")
        }
        struct AssemblyInit: Decodable { let id: String }
        let initResult = try JSONDecoder().decode(AssemblyInit.self, from: subData)

        struct AssemblyPoll: Decodable {
            let status: String
            let text: String?
            let error: String?
        }
        let pollURL = URL(string: "https://api.assemblyai.com/v2/transcript/\(initResult.id)")!
        var pollReq = URLRequest(url: pollURL)
        pollReq.setValue(configuration.apiKey, forHTTPHeaderField: "Authorization")
        for _ in 0 ..< 40 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let (pData, pResp) = try await session.data(for: pollReq)
            guard let httpP = pResp as? HTTPURLResponse, (200 ..< 300).contains(httpP.statusCode) else { continue }
            let poll = try JSONDecoder().decode(AssemblyPoll.self, from: pData)
            if poll.status == "completed" {
                return poll.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else if poll.status == "error" {
                throw SaysoError.unavailable("AssemblyAI error: \(poll.error ?? "unknown")")
            }
        }
        throw SaysoError.unavailable("AssemblyAI transcription timed out")
    }

    private func transcribeElevenLabs(fileURL: URL, language: DictationLanguage) async throws -> String {
        let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let boundary = "Sayso-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")

        var body = Data()
        Self.appendField(named: "model_id", value: "scribe_v2", boundary: boundary, to: &body)
        if let lang = Self.languageCode(for: language) {
            Self.appendField(named: "language_code", value: lang, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL, options: .mappedIfSafe))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SaysoError.unavailable("ElevenLabs returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(bodyStr)")
        }
        struct ElevenLabsResp: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(ElevenLabsResp.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeMistral(fileURL: URL, language: DictationLanguage) async throws -> String {
        let endpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let boundary = "Sayso-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        var body = Data()
        Self.appendField(named: "model", value: "voxtral-mini-latest", boundary: boundary, to: &body)
        if let lang = Self.languageCode(for: language) {
            Self.appendField(named: "language", value: lang, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL, options: .mappedIfSafe))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SaysoError.unavailable("Mistral returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(bodyStr)")
        }
        struct MistralResp: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(MistralResp.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
