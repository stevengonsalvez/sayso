import Foundation
import Testing
@testable import SaysoCore

@Test func correctionStoresKeepLearnedVocabularyOwnerOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let lexicon = SaysoPersonalLexiconStore(baseDirectory: root)
    try await lexicon.save([
        .init(
            displayName: "Maya Patel",
            canonical: "Maya Patel",
            aliases: ["Meyer Patel"],
            activation: .automatic,
            contextTags: [],
            confidence: .high,
            notes: nil
        )
    ])
    let corrections = SaysoAutoCorrectionStore(baseDirectory: root)
    try await corrections.save([.init(original: "Sayso", corrected: "Sayso Notch")])

    #expect(permissions(at: root.appending(path: "PersonalLexicon", directoryHint: .isDirectory)) == 0o700)
    #expect(permissions(at: root.appending(path: "PersonalLexicon/lexicon.json")) == 0o600)
    #expect(permissions(at: root.appending(path: "AutoCorrections", directoryHint: .isDirectory)) == 0o700)
    #expect(permissions(at: root.appending(path: "AutoCorrections/candidates.json")) == 0o600)
}

@Test func correctionStoresHardenExistingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "PersonalLexicon", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let fileURL = directory.appending(path: "lexicon.json")
    try Data("[]".utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

    _ = SaysoPersonalLexiconStore(baseDirectory: root)

    #expect(permissions(at: directory) == 0o700)
    #expect(permissions(at: fileURL) == 0o600)
}

private func permissions(at url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
}

@MainActor
@Test func correctionLearningMigratesAndPromotesRepeatedEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let learning = SaysoCorrectionLearning(baseDirectory: root, promotionThreshold: 2)
    await learning.waitUntilLoaded()

    try await learning.importLegacy(["jon": "John"])
    #expect(learning.apply(to: "Jon arrived.").transformedText == "John arrived.")

    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    #expect(learning.candidates.count == 1)
    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")

    #expect(learning.candidates.isEmpty)
    #expect(learning.apply(to: "Alen arrived.").transformedText == "Allen arrived.")
}

@MainActor
@Test func correctionLearningDismissalSuppressesFuturePromotion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let learning = SaysoCorrectionLearning(baseDirectory: root, promotionThreshold: 2)
    await learning.waitUntilLoaded()

    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    let candidate = try #require(learning.candidates.first)
    try await learning.dismiss(id: candidate.id)
    #expect(learning.candidates.isEmpty)

    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    try await learning.recordEdit(original: "Alen", edited: "Allen", sourceApplication: "Mail")
    #expect(!learning.rules.contains { $0.canonical == "Allen" })
}
