import Foundation
import Testing
@testable import SaysoCore

@MainActor
private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func slmProgressAndCompletionReachModelsModule() async throws {
    let bus = SaysoEventBus()
    let host = SaysoModuleHost(modules: [ModelsModule()], events: bus)
    host.enable("models")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloaded = root.appendingPathComponent("download")
    try Data("model".utf8).write(to: downloaded)
    let model = LocalSlmCatalog.qwen15b
    let installer = LocalSlmInstaller(bus: bus, directory: root) { _, progress in
        progress(0.42)
        return downloaded
    }

    installer.start(model)
    await waitFor { installer.state(for: model) == .installed }

    #expect(installer.state(for: model) == .installed)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(model.fileName).path))
    #expect(host.engine.stack.map(\.title) == ["\(model.displayName) ready"])
    #expect(host.engine.stack.first?.kind == .completion)
    #expect(host.engine.stack.first?.expiresAfter == 5)
}

@Test @MainActor func cancellingSlmClearsActivityWithoutInstalling() async throws {
    let bus = SaysoEventBus()
    let host = SaysoModuleHost(modules: [ModelsModule()], events: bus)
    host.enable("models")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = LocalSlmCatalog.qwen15b
    let partial = root.appendingPathComponent("partial")
    let installer = LocalSlmInstaller(bus: bus, directory: root) { _, progress in
        try Data("partial".utf8).write(to: partial)
        progress(0.42)
        try? await Task.sleep(for: .seconds(60))
        return partial
    }

    installer.start(model)
    await waitFor { host.engine.stack.first?.progress == 0.42 }
    #expect(host.engine.stack.first?.title == "Downloading \(model.displayName)")
    #expect(host.engine.stack.first?.progress == 0.42)
    installer.cancel(model)
    #expect(installer.state(for: model) == .notInstalled)
    #expect(host.engine.stack.isEmpty)
    await waitFor { !FileManager.default.fileExists(atPath: partial.path) }
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(model.fileName).path))
}

@Test @MainActor func failedSlmOffersRetry() async throws {
    let bus = SaysoEventBus()
    final class RetrySink: @unchecked Sendable { var modelIDs: [String] = [] }
    let retries = RetrySink()
    _ = bus.subscribe(ModelInstallRetryRequested.self) { retries.modelIDs.append($0.modelID) }
    let host = SaysoModuleHost(modules: [ModelsModule()], events: bus)
    host.enable("models")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = LocalSlmCatalog.qwen15b
    let installer = LocalSlmInstaller(bus: bus, directory: root) { _, _ in
        throw CocoaError(.fileNoSuchFile)
    }

    installer.start(model)
    await waitFor { if case .failed = installer.state(for: model) { return true }; return false }
    #expect(host.engine.stack.first?.title == "\(model.displayName) download failed")
    #expect(host.engine.stack.first?.actions.map(\.id) == ["retry"])
    #expect(host.perform(actionID: "retry", stackID: "install-\(model.id)", moduleID: "models"))
    #expect(retries.modelIDs == [model.id])
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(model.fileName).path))
}
