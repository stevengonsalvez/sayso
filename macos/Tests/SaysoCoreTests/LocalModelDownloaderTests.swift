import CryptoKit
import Foundation
import Testing
@testable import SaysoCore

@Test func installerVerifiesArtifactsBeforeAtomicallyPublishingModel() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("verified model".utf8)
    let model = testModel(artifact: artifact(data: data, path: "nested/model.int8.onnx"))
    let downloader = LocalModelDownloader(fetch: { _ in data })

    let installation = try await downloader.install(model, in: root, environment: readyEnvironment)

    #expect(installation.modelID == model.id)
    #expect(installation.byteCount == Int64(data.count))
    #expect(FileManager.default.contentsEqual(
        atPath: installation.directory.appending(path: "nested/model.int8.onnx").path,
        andPath: root.appending(path: model.id).appending(path: "nested/model.int8.onnx").path
    ))
    #expect(FileManager.default.fileExists(atPath: installation.directory.appending(path: ".sayso-install-complete").path))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".staging").path))
}

@Test func installerLeavesNoPublishedModelAfterChecksumFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("corrupt model".utf8)
    var incorrectArtifact = artifact(data: data, path: "model.int8.onnx")
    incorrectArtifact = .init(
        url: incorrectArtifact.url,
        relativePath: incorrectArtifact.relativePath,
        byteCount: incorrectArtifact.byteCount,
        sha256: String(repeating: "0", count: 64)
    )
    let model = testModel(artifact: incorrectArtifact)
    let downloader = LocalModelDownloader(fetch: { _ in data })

    await #expect(throws: LocalModelInstallError.checksumMismatch(path: "model.int8.onnx")) {
        try await downloader.install(model, in: root, environment: readyEnvironment)
    }

    #expect(!FileManager.default.fileExists(atPath: root.appending(path: model.id).path))
}

@Test func installerReplacesOnlyAfterNewArtifactsVerify() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("fresh model".utf8)
    let model = testModel(artifact: artifact(data: data, path: "model.int8.onnx"))
    let oldInstall = root.appending(path: model.id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: oldInstall, withIntermediateDirectories: true)
    try Data("old model".utf8).write(to: oldInstall.appending(path: "old.onnx"))
    let downloader = LocalModelDownloader(fetch: { _ in data })

    _ = try await downloader.install(model, in: root, environment: readyEnvironment)

    #expect(FileManager.default.fileExists(atPath: oldInstall.appending(path: "model.int8.onnx").path))
    #expect(!FileManager.default.fileExists(atPath: oldInstall.appending(path: "old.onnx").path))
}

@Test func installerRejectsUnapprovedTermsAndMissingRuntimeBeforeDownload() async throws {
    let data = Data("model".utf8)
    let approved = testModel(artifact: artifact(data: data, path: "model.int8.onnx"))
    let customTerms = LocalModelManifest(
        id: approved.id,
        displayName: approved.displayName,
        summary: approved.summary,
        engine: approved.engine,
        architecture: approved.architecture,
        supportedLanguages: approved.supportedLanguages,
        license: .custom(name: "Terms", url: URL(string: "https://example.com/terms")!),
        artifacts: approved.artifacts,
        expectedSizeBytes: approved.expectedSizeBytes
    )
    let downloader = LocalModelDownloader(fetch: { _ in data })
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    await #expect(throws: LocalModelInstallError.modelLicenseRequiresReview) {
        try await downloader.install(customTerms, in: root, environment: readyEnvironment)
    }
    await #expect(throws: LocalModelInstallError.requiredRuntimeUnavailable) {
        try await downloader.install(
            approved,
            in: root,
            environment: .init(hostArchitecture: .appleSilicon, availableEngines: [])
        )
    }
}

private let readyEnvironment = LocalModelEnvironment(
    hostArchitecture: .appleSilicon,
    availableEngines: [.sherpaONNX]
)

private func testModel(artifact: LocalModelArtifact) -> LocalModelManifest {
    .init(
        id: "test-model",
        displayName: "Test Model",
        summary: "Fixture",
        engine: .sherpaONNX,
        architecture: .whisperEncoderDecoder,
        supportedLanguages: [.english],
        license: .mit,
        artifacts: [artifact],
        expectedSizeBytes: artifact.byteCount
    )
}

private func artifact(data: Data, path: String) -> LocalModelArtifact {
    .init(
        url: URL(string: "https://example.com/\(path)")!,
        relativePath: path,
        byteCount: Int64(data.count),
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
}
