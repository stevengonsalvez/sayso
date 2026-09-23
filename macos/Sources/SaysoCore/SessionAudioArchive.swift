@preconcurrency import AVFoundation
import Foundation

/// Owns one captured dictation file. Failed or cancelled captures never become history audio.
public final class SessionAudioArchive: @unchecked Sendable {
    public let recordingURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var failed = false
    private var finished = false

    public init(
        directory: URL = SessionAudioArchive.defaultDirectory(),
        inputFormat: AVAudioFormat,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        recordingURL = directory.appendingPathComponent("Recording-\(UUID().uuidString).caf")
        file = try AVAudioFile(
            forWriting: recordingURL,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func isManagedRecording(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let directory = defaultDirectory(fileManager: fileManager).standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(directory + "/") && url.pathExtension.lowercased() == "caf"
    }

    public static func deleteManagedRecording(_ url: URL, fileManager: FileManager = .default) {
        guard isManagedRecording(url, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }

    public static func deleteAllManagedRecordings(fileManager: FileManager = .default) {
        let directory = defaultDirectory(fileManager: fileManager)
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        urls.forEach { deleteManagedRecording($0, fileManager: fileManager) }
    }

    /// Called directly from the audio tap. A write failure invalidates the archive.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !failed, let file else { return }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            failed = true
            self.file = nil
            try? fileManager.removeItem(at: recordingURL)
        }
    }

    /// Returns a valid persisted file only after audio frames have been written.
    public func finish() -> URL? {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return nil
        }
        finished = true
        let shouldKeep = !failed && framesWritten > 0
        file = nil
        lock.unlock()

        guard shouldKeep else {
            try? fileManager.removeItem(at: recordingURL)
            return nil
        }
        return recordingURL
    }

    public func discard() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        file = nil
        lock.unlock()
        try? fileManager.removeItem(at: recordingURL)
    }
}
