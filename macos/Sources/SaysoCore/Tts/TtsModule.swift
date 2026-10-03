import Foundation

public final class TtsModule: SaysoModule, @unchecked Sendable {
    public let descriptor = SaysoModuleDescriptor(
        id: "tts", title: "Voice output", surfaces: [.compact, .expanded, .settings]
    )
    private let synthesizer: SpeechSynthesizing
    private var runtime: Runtime?

    public init(synthesizer: SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    public func makeRuntime(context: SaysoModuleContext) -> SaysoModuleRuntime {
        let runtime = Runtime(synthesizer: synthesizer, context: context)
        self.runtime = runtime
        return runtime
    }

    /// No-op while the module is disabled, quarantined or permission-blocked.
    public func speak(_ plan: SpeechPlan) {
        runtime?.speak(plan)
    }

    private final class Runtime: SaysoModuleRuntime, SaysoResourceAccounting, @unchecked Sendable {
        let synthesizer: SpeechSynthesizing
        let context: SaysoModuleContext
        private var currentID: Int?
        private var stopped = false

        init(synthesizer: SpeechSynthesizing, context: SaysoModuleContext) {
            self.synthesizer = synthesizer
            self.context = context
        }

        var retainedResources: Int { (synthesizer.onFinish == nil ? 0 : 1) + (synthesizer.isSpeaking ? 1 : 0) }

        func start() {
            synthesizer.onFinish = { [weak self] id in
                guard let self, self.currentID == id else { return }
                self.currentID = nil
                self.context.dismiss(stackID: "speaking")
            }
        }

        func stop() {
            stopped = true
            currentID = nil
            synthesizer.stop()
            synthesizer.onFinish = nil
        }

        func speak(_ plan: SpeechPlan) {
            guard !stopped else { return }
            currentID = synthesizer.speak(plan)
            context.publish(
                stackID: "speaking", kind: .activeTask, title: "Speaking",
                actions: [SaysoAction(id: "stop", title: "Stop")]
            )
        }

        func handle(stackID: String, actionID: String) {
            guard actionID == "stop" else { return }
            currentID = nil
            synthesizer.stop()
            context.dismiss(stackID: "speaking")
        }
    }
}
