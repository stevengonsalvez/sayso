import Foundation
import Testing
@testable import SaysoCore

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
