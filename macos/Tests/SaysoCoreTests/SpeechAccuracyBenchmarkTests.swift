import Foundation
import Testing
@testable import SaysoCore

@Test func exactMatchReturnsZeroWERAndCER() {
    let reference = "The quick brown fox jumps over the lazy dog."
    let hypothesisIdentical = "The quick brown fox jumps over the lazy dog."

    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: hypothesisIdentical) == 0.0)
    #expect(TranscriptErrorRate.characterErrorRate(reference: reference, hypothesis: hypothesisIdentical) == 0.0)

    let hypothesisCaseAndPunctuation = "the quick brown fox jumps over the lazy dog"
    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: hypothesisCaseAndPunctuation) == 0.0)
    #expect(TranscriptErrorRate.characterErrorRate(reference: reference, hypothesis: hypothesisCaseAndPunctuation) == 0.0)

    #expect(TranscriptErrorRate.wordErrorRate(reference: "", hypothesis: "") == 0.0)
    #expect(TranscriptErrorRate.characterErrorRate(reference: "", hypothesis: "") == 0.0)
}

@Test func completeMismatchReturnsOneWER() {
    let reference = "one two three four"
    let hypothesis = "alpha beta gamma delta"

    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: hypothesis) == 1.0)

    let singleRef = "apple"
    let singleHyp = "banana"
    #expect(TranscriptErrorRate.wordErrorRate(reference: singleRef, hypothesis: singleHyp) == 1.0)

    let emptyHyp = ""
    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: emptyHyp) == 1.0)
}

@Test func substitutionInsertionDeletionCalculationsMatchExpectedWER() {
    let reference = "the quick brown fox"

    // Substitution: 1 word changed out of 4 (WER = 0.25)
    let substitutionHyp = "the fast brown fox"
    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: substitutionHyp) == 0.25)

    // Deletion: 1 word omitted out of 4 (WER = 0.25)
    let deletionHyp = "the brown fox"
    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: deletionHyp) == 0.25)

    // Insertion: 1 word added to 4 words (WER = 0.25)
    let insertionHyp = "the really quick brown fox"
    #expect(TranscriptErrorRate.wordErrorRate(reference: reference, hypothesis: insertionHyp) == 0.25)

    // Combined: 2 substitutions + 1 deletion out of 5 words (WER = 3/5 = 0.6)
    let longerRef = "the quick brown fox jumps"
    let combinedHyp = "a quick brown dog"
    #expect(TranscriptErrorRate.wordErrorRate(reference: longerRef, hypothesis: combinedHyp) == 0.6)
}

@Test func normalizationStripsPunctuationHandlesCaseInsensitivityAndDiacritics() {
    let text = "Café, résumé! (Naïve: façade; schön / über / straße?)"

    let words = TranscriptErrorRate.normalizedWords(text)
    #expect(words == ["cafe", "resume", "naive", "facade", "schon", "uber", "strasse"])

    let simple = "Hello, World!"
    #expect(TranscriptErrorRate.normalizedWords(simple) == ["hello", "world"])
    #expect(TranscriptErrorRate.normalizedCharacters(simple) == ["h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d"])

    let diacriticPhrase = "Café naïve!"
    #expect(TranscriptErrorRate.normalizedCharacters(diacriticPhrase) == ["c", "a", "f", "e", " ", "n", "a", "i", "v", "e"])

    // Verify WER and CER are 0.0 when comparing diacritics and mixed casing
    #expect(TranscriptErrorRate.wordErrorRate(reference: "Café naïve!", hypothesis: "cafe naive") == 0.0)
    #expect(TranscriptErrorRate.characterErrorRate(reference: "Café naïve!", hypothesis: "cafe naive") == 0.0)
}

@Test func editDistanceCalculatesCorrectly() {
    #expect(TranscriptErrorRate.editDistance([1, 2, 3], [1, 2, 3]) == 0)
    #expect(TranscriptErrorRate.editDistance([1, 2, 3], [1, 4, 3]) == 1)
    #expect(TranscriptErrorRate.editDistance([1, 2, 3], [1, 2]) == 1)
    #expect(TranscriptErrorRate.editDistance([1, 2], [1, 2, 3]) == 1)
    #expect(TranscriptErrorRate.editDistance([], [1, 2]) == 2)
    #expect(TranscriptErrorRate.editDistance([1, 2], []) == 2)
}

@Test func aggregateWERAcrossMultipleMeasurementsIsCorrectlyCalculated() {
    let m1 = SpeechAccuracyBenchmarkMeasurement(
        id: "m1",
        model: "whisper-tiny",
        audioPath: "/audio/sample1.wav",
        referenceTranscript: "the quick brown fox",
        hypothesisTranscript: "the quick brown fox",
        language: "en",
        durationSeconds: 2.5
    )
    #expect(m1.wer == 0.0)

    let m2 = SpeechAccuracyBenchmarkMeasurement(
        id: "m2",
        model: "whisper-tiny",
        audioPath: "/audio/sample2.wav",
        referenceTranscript: "jumped over a lazy dog",
        hypothesisTranscript: "jumped over the lazy dog",
        language: "en",
        durationSeconds: 3.0
    )
    // 1 substitution out of 5 words = 0.2
    #expect(m2.wer == 0.2)

    // Total reference words: 4 + 5 = 9. Total errors: 0 + 1 = 1. Expected aggregate WER: 1/9.
    let expectedAggregateWER = 1.0 / 9.0
    let calculatedAggregateWER = TranscriptErrorRate.aggregateWordErrorRate(for: [m1, m2])
    #expect(abs(calculatedAggregateWER - expectedAggregateWER) < 0.0001)

    // Equal length measurements:
    // m3: 2 words, 0 errors -> WER 0.0
    // m4: 2 words, 1 error -> WER 0.5
    // Aggregate: 1 error out of 4 words = 0.25
    let m3 = SpeechAccuracyBenchmarkMeasurement(
        id: "m3",
        model: "whisper-tiny",
        audioPath: "/audio/sample3.wav",
        referenceTranscript: "apple banana",
        hypothesisTranscript: "apple banana",
        language: "en",
        durationSeconds: 1.5
    )
    let m4 = SpeechAccuracyBenchmarkMeasurement(
        id: "m4",
        model: "whisper-tiny",
        audioPath: "/audio/sample4.wav",
        referenceTranscript: "cherry date",
        hypothesisTranscript: "cherry fig",
        language: "en",
        durationSeconds: 1.8
    )
    let equalLengthWER = TranscriptErrorRate.aggregateWordErrorRate(for: [m3, m4])
    #expect(equalLengthWER == 0.25)

    // Test SpeechAccuracyBenchmarkReport automatic aggregation
    let report = SpeechAccuracyBenchmarkReport(
        engine: "fluid-audio",
        model: "whisper-tiny",
        measurements: [m3, m4]
    )
    #expect(report.engine == "fluid-audio")
    #expect(report.model == "whisper-tiny")
    #expect(report.aggregateWER == 0.25)
    #expect(report.measurements.count == 2)
}
