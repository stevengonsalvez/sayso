import Foundation

/// Nondeterministic boundary: the real AVSpeechSynthesizer adapter lives behind this.
public protocol SpeechSynthesizing: AnyObject, Sendable {
    var isSpeaking: Bool { get }
    /// Called with the utterance id when that utterance finishes or is cancelled, possibly after a newer one started.
    var onFinish: (@Sendable (Int) -> Void)? { get set }
    /// Returns the id of the new utterance; speaking replaces any current one.
    func speak(_ plan: SpeechPlan) -> Int
    func stop()
}
