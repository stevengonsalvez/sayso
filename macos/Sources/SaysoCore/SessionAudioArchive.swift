@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

/// Owns one captured dictation file. Failed or cancelled captures never become history audio.
public final class SessionAudioArchive: @unchecked Sendable {
    public let recordingURL: URL

    private let fileManager: FileManager
    private let inputFormat: AVAudioFormat
    private let archiveFormat: AVAudioFormat
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var failed = false
    private var finished = false

    public init(
        directory: URL = SessionAudioArchive.defaultDirectory(),
        inputFormat: AVAudioFormat,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.inputFormat = inputFormat
        guard let archiveFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw ArchiveError.unsupportedArchiveFormat
        }
        self.archiveFormat = archiveFormat
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        recordingURL = directory.appendingPathComponent("Recording-\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(
                forWriting: recordingURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: archiveFormat.sampleRate,
                    AVNumberOfChannelsKey: Int(archiveFormat.channelCount),
                    AVEncoderBitRateKey: 32_000
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat) else {
                throw ArchiveError.cannotCreateConverter
            }
            self.file = file
            self.converter = converter
        } catch {
            try? fileManager.removeItem(at: recordingURL)
            throw error
        }
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaysoNotch", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func isManagedRecording(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let directory = defaultDirectory(fileManager: fileManager).standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return url.isFileURL
            && candidate.hasPrefix(directory + "/")
            && managedExtensions.contains(url.pathExtension.lowercased())
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

    public static func sweepUnreferencedRecordings(
        retaining retainedURLs: Set<URL>,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let recordingDirectory = (directory ?? defaultDirectory(fileManager: fileManager)).standardizedFileURL
        let retained = Set(retainedURLs.map(\.standardizedFileURL))
        let urls = (try? fileManager.contentsOfDirectory(at: recordingDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where managedExtensions.contains(url.pathExtension.lowercased()) {
            let standardizedURL = url.standardizedFileURL
            if !retained.contains(standardizedURL) {
                try? fileManager.removeItem(at: standardizedURL)
            }
        }
    }

    /// Called directly from the audio tap. A write failure invalidates the archive.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !failed, let file else { return }
        do {
            try writeConverted(buffer, to: file)
        } catch {
            fail()
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
        if !failed, let file {
            do {
                try flushConverter(to: file)
            } catch {
                fail()
            }
        }
        let shouldKeep = !failed && framesWritten > 0
        file = nil
        converter = nil
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
        converter = nil
        lock.unlock()
        try? fileManager.removeItem(at: recordingURL)
    }

    private static let managedExtensions: Set<String> = ["m4a", "caf"]

    private enum ArchiveError: Error {
        case unsupportedArchiveFormat
        case cannotCreateConverter
        case changedInputFormat
        case conversionFailed
    }

    private func writeConverted(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        guard buffer.frameLength > 0 else { return }
        guard matchesInputFormat(buffer.format) else { throw ArchiveError.changedInputFormat }
        guard let converter else { throw ArchiveError.conversionFailed }

        let capacity = AVAudioFrameCount(max(
            1,
            Int((Double(buffer.frameLength) * archiveFormat.sampleRate / inputFormat.sampleRate).rounded(.up)) + 32
        ))
        guard let output = AVAudioPCMBuffer(pcmFormat: archiveFormat, frameCapacity: capacity) else {
            throw ArchiveError.conversionFailed
        }
        let input = PendingInput(buffer)
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let buffer = input.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if conversionError != nil || status == .error { throw ArchiveError.conversionFailed }
            if output.frameLength > 0 {
                try file.write(from: output)
                framesWritten += AVAudioFramePosition(output.frameLength)
            }
            guard status == .haveData else { return }
        }
    }

    private func flushConverter(to file: AVAudioFile) throws {
        guard let converter else { return }
        guard let output = AVAudioPCMBuffer(pcmFormat: archiveFormat, frameCapacity: 2_048) else {
            throw ArchiveError.conversionFailed
        }
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if conversionError != nil || status == .error { throw ArchiveError.conversionFailed }
            if output.frameLength > 0 {
                try file.write(from: output)
                framesWritten += AVAudioFramePosition(output.frameLength)
            }
            guard status == .haveData else { return }
        }
    }

    private func matchesInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == inputFormat.sampleRate
            && format.channelCount == inputFormat.channelCount
            && format.commonFormat == inputFormat.commonFormat
            && format.isInterleaved == inputFormat.isInterleaved
    }

    private func fail() {
        failed = true
        file = nil
        converter = nil
        try? fileManager.removeItem(at: recordingURL)
    }

    private final class PendingInput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            lock.lock()
            defer { lock.unlock() }
            defer { buffer = nil }
            return buffer
        }
    }
}
