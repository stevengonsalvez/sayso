import Foundation
import Testing
@testable import SaysoCore

private final class Sink: @unchecked Sendable { var retries: [ModelInstallRetryRequested] = [] }

private func setup() -> (SaysoModuleHost, SaysoEventBus, Sink) {
    let bus = SaysoEventBus(), sink = Sink()
    _ = bus.subscribe(ModelInstallRetryRequested.self) { sink.retries.append($0) }
    let host = SaysoModuleHost(modules: [ModelsModule()], events: bus)
    host.enable("models")
    return (host, bus, sink)
}

@Test func progressEventsShowOneUpdatingActivityPerModel() {
    let (host, bus, _) = setup()
    bus.publish(ModelInstallProgress(modelID: "parakeet", displayName: "English model", fraction: 0.25))
    bus.publish(ModelInstallProgress(modelID: "sherpa", displayName: "Punjabi model", fraction: 0.1))
    bus.publish(ModelInstallProgress(modelID: "parakeet", displayName: "English model", fraction: 0.5))

    let stack = host.engine.stack
    #expect(stack.count == 2)
    let english = stack.first { $0.stackID == "install-parakeet" }
    #expect(english?.title == "Downloading English model")
    #expect(english?.progress == 0.5)
    #expect(english?.kind == .activeTask)
}

@Test func successReplacesProgressWithAnExpiringCompletion() {
    let (host, bus, _) = setup()
    bus.publish(ModelInstallProgress(modelID: "parakeet", displayName: "English model", fraction: 0.9))
    bus.publish(ModelInstallFinished(modelID: "parakeet", displayName: "English model", succeeded: true))

    let done = host.engine.stack.first
    #expect(host.engine.stack.count == 1)
    #expect(done?.kind == .completion)
    #expect(done?.title == "English model ready")
    #expect(done?.expiresAfter != nil)
    #expect(done?.progress == nil)
}

@Test func failureOffersRetryWhichRequestsAnotherInstallWithoutTheModuleInstallingItself() {
    let (host, bus, sink) = setup()
    bus.publish(ModelInstallFinished(modelID: "parakeet", displayName: "English model", succeeded: false))

    let failure = host.engine.stack.first
    #expect(failure?.kind == .failure)
    #expect(failure?.title == "English model download failed")
    #expect(failure?.actions.map(\.id) == ["retry"])

    #expect(host.perform(actionID: "retry", stackID: "install-parakeet", moduleID: "models"))
    #expect(sink.retries == [ModelInstallRetryRequested(modelID: "parakeet")])
    #expect(host.engine.stack.isEmpty)
}

@Test func disabledModelsModuleIgnoresInstallEvents() {
    let (host, bus, _) = setup()
    host.disable("models")
    bus.publish(ModelInstallProgress(modelID: "parakeet", displayName: "English model", fraction: 0.5))
    #expect(host.engine.stack.isEmpty)
}

@Test func modelsModulePassesTheGenericAcceptanceHarness() {
    #expect(SaysoModuleAcceptance.violations(for: ModelsModule()) == [])
}
