@preconcurrency import AVFoundation
import Foundation

public enum FluidAudioBufferPumpEnqueueResult: Equatable, Sendable {
    case accepted
    case droppedAtCapacity
    case droppedCopyFailure
    case rejectedClosed
}

public enum FluidAudioBufferPumpTerminal: Equatable, Sendable {
    case drained(processed: Int, dropped: Int)
    case failed(processed: Int, dropped: Int, message: String)
}

public struct FluidAudioBufferPumpSnapshot: Equatable, Sendable {
    public let queued: Int
    public let isProcessing: Bool
    public let processed: Int
    public let dropped: Int
    public let terminal: FluidAudioBufferPumpTerminal?

    public init(
        queued: Int,
        isProcessing: Bool,
        processed: Int,
        dropped: Int,
        terminal: FluidAudioBufferPumpTerminal?
    ) {
        self.queued = queued
        self.isProcessing = isProcessing
        self.processed = processed
        self.dropped = dropped
        self.terminal = terminal
    }
}

/// Ordered, bounded bridge between an audio tap and FluidAudio inference.
/// Each source buffer is copied before it can enter the asynchronous queue.
public actor FluidAudioBufferPump {
    public static let capacity = 32
    public typealias Processor = @Sendable (AVAudioPCMBuffer) async throws -> Void

    private final class TapSubmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isSealed = false
        private var outstanding = 0

        func reserve() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isSealed else { return false }
            outstanding += 1
            return true
        }

        func seal() -> Int {
            lock.lock()
            defer { lock.unlock() }
            isSealed = true
            return outstanding
        }

        func complete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            outstanding -= 1
            return isSealed
        }
    }

    private final class BufferedPCM: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let process: Processor
    private let tapSubmissions = TapSubmissionGate()
    private var queue: [BufferedPCM] = []
    private var isProcessing = false
    private var isClosed = false
    private var pendingTapSubmissions = 0
    private var processed = 0
    private var dropped = 0
    private var terminal: FluidAudioBufferPumpTerminal?
    private var drainWaiters: [CheckedContinuation<FluidAudioBufferPumpTerminal, Never>] = []

    public init(process: @escaping Processor) {
        self.process = process
    }

    /// Audio-tap entry point. Copy happens synchronously before actor scheduling.
    public nonisolated func submit(_ source: AVAudioPCMBuffer) {
        guard tapSubmissions.reserve() else { return }
        guard let copy = Self.copy(source) else {
            Task {
                await self.recordCopyFailure()
                if self.tapSubmissions.complete() {
                    await self.completeTapSubmission()
                }
            }
            return
        }
        let buffered = BufferedPCM(copy)
        Task {
            await self.enqueueReserved(buffered)
            if self.tapSubmissions.complete() {
                await self.completeTapSubmission()
            }
        }
    }

    /// Awaitable entry point for non-realtime callers and deterministic tests.
    @discardableResult
    public func enqueue(_ source: AVAudioPCMBuffer) -> FluidAudioBufferPumpEnqueueResult {
        guard let copy = Self.copy(source) else {
            dropped += 1
            return .droppedCopyFailure
        }
        return enqueue(BufferedPCM(copy))
    }

    public func snapshot() -> FluidAudioBufferPumpSnapshot {
        FluidAudioBufferPumpSnapshot(
            queued: queue.count,
            isProcessing: isProcessing,
            processed: processed,
            dropped: dropped,
            terminal: terminal
        )
    }

    /// Rejects future audio, drains already accepted audio, then returns outcome.
    public func closeAndDrain() async -> FluidAudioBufferPumpTerminal {
        let outstanding = tapSubmissions.seal()
        if let terminal { return terminal }
        if isClosed {
            return await withCheckedContinuation { drainWaiters.append($0) }
        }
        isClosed = true
        pendingTapSubmissions = outstanding
        finishIfDrained()
        if let terminal { return terminal }
        return await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func enqueue(_ buffered: BufferedPCM) -> FluidAudioBufferPumpEnqueueResult {
        guard !isClosed, terminal == nil else { return .rejectedClosed }
        guard queue.count + (isProcessing ? 1 : 0) < Self.capacity else {
            dropped += 1
            return .droppedAtCapacity
        }
        queue.append(buffered)
        startProcessorIfNeeded()
        return .accepted
    }

    private func enqueueReserved(_ buffered: BufferedPCM) {
        guard terminal == nil else { return }
        guard queue.count + (isProcessing ? 1 : 0) < Self.capacity else {
            dropped += 1
            return
        }
        queue.append(buffered)
        startProcessorIfNeeded()
    }

    private func recordCopyFailure() {
        guard terminal == nil else { return }
        dropped += 1
    }

    private func completeTapSubmission() {
        guard pendingTapSubmissions > 0 else { return }
        pendingTapSubmissions -= 1
        finishIfDrained()
    }

    private func startProcessorIfNeeded() {
        guard !isProcessing, !queue.isEmpty, terminal == nil else { return }
        isProcessing = true
        Task { await processQueue() }
    }

    private func processQueue() async {
        while terminal == nil, !queue.isEmpty {
            let next = queue.removeFirst()
            do {
                try await process(next.buffer)
                processed += 1
            } catch {
                queue.removeAll(keepingCapacity: false)
                complete(.failed(processed: processed, dropped: dropped, message: error.localizedDescription))
            }
        }
        isProcessing = false
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard terminal == nil, isClosed, pendingTapSubmissions == 0, !isProcessing, queue.isEmpty else { return }
        complete(.drained(processed: processed, dropped: dropped))
    }

    private func complete(_ outcome: FluidAudioBufferPumpTerminal) {
        guard terminal == nil else { return }
        _ = tapSubmissions.seal()
        terminal = outcome
        isClosed = true
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private nonisolated static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }

        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceBuffer.mDataByteSize <= destinationBuffers[index].mDataByteSize else {
                return nil
            }
            destinationData.copyMemory(from: sourceData, byteCount: Int(sourceBuffer.mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return destination
    }
}
