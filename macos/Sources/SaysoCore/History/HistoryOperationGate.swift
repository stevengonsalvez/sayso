import Foundation

/// The four busy flags that used to live loose in `SaysoAppModel`, with identical blocking rules.
public struct HistoryOperationGate: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case reprocess(UUID)
        case importAudio
        case clear
    }

    public private(set) var reprocessingID: UUID?
    public private(set) var isImporting = false
    public private(set) var isClearing = false
    public private(set) var isAudioTaskRunning = false

    public init() {}

    /// Dictation must not start while history audio is being reprocessed, imported or tasked.
    public var blocksDictation: Bool { isImporting || reprocessingID != nil || isAudioTaskRunning }

    public mutating func begin(_ operation: Operation) -> Bool {
        switch operation {
        case .reprocess(let id):
            guard reprocessingID == nil, !isImporting, !isClearing else { return false }
            reprocessingID = id
        case .importAudio:
            guard !isImporting, reprocessingID == nil, !isClearing else { return false }
            isImporting = true
        case .clear:
            guard !isImporting, reprocessingID == nil, !isAudioTaskRunning, !isClearing else { return false }
            isClearing = true
        }
        return true
    }

    public mutating func end(_ operation: Operation) {
        switch operation {
        case .reprocess: reprocessingID = nil
        case .importAudio: isImporting = false
        case .clear: isClearing = false
        }
    }

    public mutating func beginAudioTask() -> Bool {
        guard !isAudioTaskRunning else { return false }
        isAudioTaskRunning = true
        return true
    }

    public mutating func endAudioTask() { isAudioTaskRunning = false }
}
