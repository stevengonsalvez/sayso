import Foundation
import Testing
@testable import SaysoCore

@Test func PunjabiManifestPinsModelAndTokenizer() throws {
    let model = try #require(LocalModelCatalog.model(id: SherpaPunjabiModelManager.modelID))

    #expect(model.isRecommended)
    #expect(model.license == .apache20)
    #expect(model.supportedLanguages == [.punjabi])
    #expect(model.artifacts == [
        .init(
            url: URL(string: "https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx/resolve/9721eb71eea141fae0982cfcdb9dd2e3d4953c4a/pa/model.int8.onnx")!,
            relativePath: "model.int8.onnx",
            byteCount: 197_595_548,
            sha256: "ccd02e5ae7e71b6719de517c2819ce570247c1d9e79b3348e76cfd5eb3e5dbbc"
        ),
        .init(
            url: URL(string: "https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx/resolve/9721eb71eea141fae0982cfcdb9dd2e3d4953c4a/tokens.txt")!,
            relativePath: "tokens.txt",
            byteCount: 67_605,
            sha256: "ee60967630213f31951817ac8b402b92ec18cce80718a24a49b388e56672dfb2"
        ),
    ])
}

@Test @MainActor func installedPunjabiModelAvoidsSpeechRecognition() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SherpaPunjabiModelManager(modelsDirectory: root)
    let directory = root.appending(path: SherpaPunjabiModelManager.modelID, directoryHint: .isDirectory)
    for artifact in SherpaPunjabiModelManager.model.artifacts {
        let file = directory.appending(path: artifact.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
    }
    try Data(SherpaPunjabiModelManager.modelID.utf8).write(to: directory.appending(path: ".sayso-install-complete"))
    manager.refresh()

    let transcriber = LiveTranscriber(sherpaPunjabiModels: manager)
    #expect(manager.state.isInstalled)
    #expect(!transcriber.requiresSpeechRecognition(language: .punjabi, route: .local))
    #expect(FileTranscriber.prefersSherpaPunjabi(language: .punjabi, route: .local, localModelReady: true))
    #expect(!FileTranscriber.prefersSherpaPunjabi(language: .punjabi, route: .appleSpeech, localModelReady: true))
}
