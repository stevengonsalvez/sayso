import Foundation

public enum TranscriptErrorRate: Sendable {
    public static func wordErrorRate(
        reference: String,
        hypothesis: String,
        language: String? = nil
    ) -> Double {
        let refWords = normalizedWords(reference)
        let hypWords = normalizedWords(hypothesis)
        guard !refWords.isEmpty else {
            return hypWords.isEmpty ? 0.0 : 1.0
        }
        let distance = editDistance(refWords, hypWords)
        return Double(distance) / Double(refWords.count)
    }

    public static func wordErrorRate(
        reference: String,
        hypothesis: String,
        language: DictationLanguage
    ) -> Double {
        wordErrorRate(reference: reference, hypothesis: hypothesis, language: language.rawValue)
    }

    public static func characterErrorRate(
        reference: String,
        hypothesis: String
    ) -> Double {
        let refChars = normalizedCharacters(reference)
        let hypChars = normalizedCharacters(hypothesis)
        guard !refChars.isEmpty else {
            return hypChars.isEmpty ? 0.0 : 1.0
        }
        let distance = editDistance(refChars, hypChars)
        return Double(distance) / Double(refChars.count)
    }

    public static func normalizedWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let cleaned = folded.replacingOccurrences(of: "[\u{0027}\u{2019}\u{0060}]", with: "", options: .regularExpression)
        return cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    public static func normalizedCharacters(_ text: String) -> [Character] {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return [] }
        return Array(words.joined(separator: " "))
    }

    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j], current[j - 1], previous[j - 1])
                }
            }
            previous = current
        }

        return previous[b.count]
    }

    public static func aggregateWordErrorRate(for measurements: [SpeechAccuracyBenchmarkMeasurement]) -> Double {
        guard !measurements.isEmpty else { return 0.0 }
        let totalReferenceWords = measurements.reduce(0) { $0 + normalizedWords($1.referenceTranscript).count }
        guard totalReferenceWords > 0 else {
            return measurements.reduce(0.0) { $0 + $1.wer } / Double(measurements.count)
        }
        let totalDistance = measurements.reduce(0) {
            $0 + editDistance(normalizedWords($1.referenceTranscript), normalizedWords($1.hypothesisTranscript))
        }
        return Double(totalDistance) / Double(totalReferenceWords)
    }

    public static func aggregateCharacterErrorRate(for measurements: [SpeechAccuracyBenchmarkMeasurement]) -> Double {
        guard !measurements.isEmpty else { return 0.0 }
        let totalReferenceChars = measurements.reduce(0) { $0 + normalizedCharacters($1.referenceTranscript).count }
        guard totalReferenceChars > 0 else {
            return measurements.reduce(0.0) { $0 + $1.cer } / Double(measurements.count)
        }
        let totalDistance = measurements.reduce(0) {
            $0 + editDistance(normalizedCharacters($1.referenceTranscript), normalizedCharacters($1.hypothesisTranscript))
        }
        return Double(totalDistance) / Double(totalReferenceChars)
    }
}

public struct SpeechAccuracyBenchmarkMeasurement: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let model: String
    public let audioPath: String
    public let referenceTranscript: String
    public let hypothesisTranscript: String
    public let language: String
    public let wer: Double
    public let cer: Double
    public let durationSeconds: Double

    public init(
        id: String = UUID().uuidString,
        model: String,
        audioPath: String,
        referenceTranscript: String,
        hypothesisTranscript: String,
        language: String,
        wer: Double,
        cer: Double,
        durationSeconds: Double
    ) {
        self.id = id
        self.model = model
        self.audioPath = audioPath
        self.referenceTranscript = referenceTranscript
        self.hypothesisTranscript = hypothesisTranscript
        self.language = language
        self.wer = wer
        self.cer = cer
        self.durationSeconds = durationSeconds
    }

    public init(
        id: String = UUID().uuidString,
        model: String,
        audioPath: String,
        referenceTranscript: String,
        hypothesisTranscript: String,
        language: String,
        durationSeconds: Double
    ) {
        self.id = id
        self.model = model
        self.audioPath = audioPath
        self.referenceTranscript = referenceTranscript
        self.hypothesisTranscript = hypothesisTranscript
        self.language = language
        self.wer = TranscriptErrorRate.wordErrorRate(reference: referenceTranscript, hypothesis: hypothesisTranscript, language: language)
        self.cer = TranscriptErrorRate.characterErrorRate(reference: referenceTranscript, hypothesis: hypothesisTranscript)
        self.durationSeconds = durationSeconds
    }

    public init(
        id: UUID,
        model: String,
        audioPath: String,
        referenceTranscript: String,
        hypothesisTranscript: String,
        language: String,
        wer: Double,
        cer: Double,
        durationSeconds: Double
    ) {
        self.init(
            id: id.uuidString,
            model: model,
            audioPath: audioPath,
            referenceTranscript: referenceTranscript,
            hypothesisTranscript: hypothesisTranscript,
            language: language,
            wer: wer,
            cer: cer,
            durationSeconds: durationSeconds
        )
    }

    public init(
        id: UUID,
        model: String,
        audioPath: String,
        referenceTranscript: String,
        hypothesisTranscript: String,
        language: String,
        durationSeconds: Double
    ) {
        self.init(
            id: id.uuidString,
            model: model,
            audioPath: audioPath,
            referenceTranscript: referenceTranscript,
            hypothesisTranscript: hypothesisTranscript,
            language: language,
            durationSeconds: durationSeconds
        )
    }
}

public struct SpeechAccuracyBenchmarkReport: Codable, Equatable, Sendable {
    public let engine: String
    public let model: String
    public let generatedAt: Date
    public let aggregateWER: Double
    public let aggregateCER: Double
    public let measurements: [SpeechAccuracyBenchmarkMeasurement]

    public init(
        engine: String,
        model: String,
        generatedAt: Date = Date(),
        aggregateWER: Double,
        aggregateCER: Double,
        measurements: [SpeechAccuracyBenchmarkMeasurement]
    ) {
        self.engine = engine
        self.model = model
        self.generatedAt = generatedAt
        self.aggregateWER = aggregateWER
        self.aggregateCER = aggregateCER
        self.measurements = measurements
    }

    public init(
        engine: String,
        model: String,
        generatedAt: Date = Date(),
        measurements: [SpeechAccuracyBenchmarkMeasurement]
    ) {
        self.engine = engine
        self.model = model
        self.generatedAt = generatedAt
        self.measurements = measurements
        self.aggregateWER = TranscriptErrorRate.aggregateWordErrorRate(for: measurements)
        self.aggregateCER = TranscriptErrorRate.aggregateCharacterErrorRate(for: measurements)
    }
}
