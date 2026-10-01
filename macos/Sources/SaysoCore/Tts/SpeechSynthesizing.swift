import Foundation

/// Nondeterministic boundary: the real AVSpeechSynthesizer adapter lives behind this.
public protocol SpeechSynthesizing: AnyObject, Sendable {
    var isSpeaking: Bool { get }
    /// Called when an utterance finishes or is cancelled by the system.
    var onFinish: (@Sendable () -> Void)? { get set }
    func speak(_ plan: SpeechPlan)
    func stop()
}
