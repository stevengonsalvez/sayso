import Foundation
import Testing
@testable import SaysoCore

@Test func localModelManifestPinsEveryArtifact() {
    let allIDs = LocalModelCatalog.all.map(\.id)

    #expect(allIDs.count == Set(allIDs).count)
    #expect(LocalModelCatalog.all.filter(\.isRecommended).map(\.id) == [
        "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8",
        "ai4bharat-indicconformer-pa",
    ])
    for model in LocalModelCatalog.all {
        #expect(!model.displayName.isEmpty)
        #expect(!model.summary.isEmpty)
        #expect(!model.artifacts.isEmpty)
        #expect(model.expectedSizeBytes > 0)
        for artifact in model.artifacts {
            #expect(artifact.url.scheme == "https")
            #expect(artifact.byteCount > 0)
            #expect(artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        }
    }
}

@Test func localModelRecommendationsMatchLanguageContracts() {
    #expect(LocalModelCatalog.recommendedEnglishModel.id == "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8")
    #expect(LocalModelCatalog.recommendedModel(for: .english).id == LocalModelCatalog.recommendedEnglishModel.id)
    #expect(LocalModelCatalog.recommendedModel(for: .tamil).id == "ai4bharat-indicconformer-ta")
    #expect(LocalModelCatalog.recommendedModel(for: .hindi).id == "ai4bharat-indicconformer-hi")
    #expect(LocalModelCatalog.recommendedModel(for: .malayalam).id == "ai4bharat-indicconformer-ml")
    #expect(LocalModelCatalog.recommendedModel(for: .punjabi).id == "ai4bharat-indicconformer-pa")
    #expect(LocalModelCatalog.recommendedModel(for: .telugu).id == "sherpa-onnx-whisper-tiny")
    #expect(LocalModelCatalog.recommendedModel(for: .automatic).id == "sherpa-onnx-whisper-tiny")
}

@Test func modelsOnlyBecomeSelectableAfterInstallationAndRuntime() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let model = LocalModelCatalog.recommendedEnglishModel
    let readyRuntime = LocalModelEnvironment(hostArchitecture: .appleSilicon, availableEngines: [.sherpaONNX])

    #expect(LocalModelCatalog.state(for: model, in: root) == .notDownloaded)
    #expect(LocalModelCatalog.availability(for: model, in: root, environment: readyRuntime) == .downloadRequired)
    #expect(LocalModelCatalog.selectable(in: root, environment: readyRuntime).isEmpty)

    let install = root.appending(path: model.id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    #expect(LocalModelCatalog.state(for: model, in: root) == .incomplete)

    for artifact in model.artifacts {
        let artifactURL = install.appending(path: artifact.relativePath)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model".utf8).write(to: artifactURL)
    }
    try Data(model.id.utf8).write(to: install.appending(path: ".sayso-install-complete"))
    #expect(LocalModelCatalog.state(for: model, in: root) == .installed)
    #expect(LocalModelCatalog.availability(for: model, in: root, environment: .init(hostArchitecture: .appleSilicon, availableEngines: [])) == .unavailable(reason: "Required local runtime is not installed"))
    #expect(LocalModelCatalog.selectable(in: root, environment: readyRuntime).map(\.id) == [model.id])
}

@Test func unapprovedCustomModelTermsBlockSelection() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let senseVoice = try #require(LocalModelCatalog.model(id: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"))
    let install = root.appending(path: senseVoice.id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try Data("model".utf8).write(to: install.appending(path: "model.int8.onnx"))

    #expect(!senseVoice.license.isApprovedForDistribution)
    #expect(LocalModelCatalog.availability(
        for: senseVoice,
        in: root,
        environment: .init(hostArchitecture: .appleSilicon, availableEngines: [.sherpaONNX])
    ) == .unavailable(reason: "Model license requires distribution review"))
}
