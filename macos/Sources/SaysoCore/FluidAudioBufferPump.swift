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

    private final class BufferedPCM: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let process: Processor
    private var queue: [BufferedPCM] = []
    private var isProcessing = false
    private var isClosed = false
    private var processed = 0
    private var dropped = 0
    private var terminal: FluidAudioBufferPumpTerminal?
    private var drainWaiters: [CheckedContinuation<FluidAudioBufferPumpTerminal, Never>] = []

    public init(process: @escaping Processor) {
        self.process = process
    }

    /// Audio-tap entry point. Copy happens synchronously before actor scheduling.
    public nonisolated func submit(_ source: AVAudioPCMBuffer) {
        guard let copy = Self.copy(source) else {
            Task { await self.recordCopyFailure() }
            return
        }
        let buffered = BufferedPCM(copy)
        Task { await self.enqueue(buffered) }
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
        if let terminal { return terminal }
        isClosed = true
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

    private func recordCopyFailure() {
        guard !isClosed, terminal == nil else { return }
        dropped += 1
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
        guard terminal == nil, isClosed, !isProcessing, queue.isEmpty else { return }
        complete(.drained(processed: processed, dropped: dropped))
    }

    private func complete(_ outcome: FluidAudioBufferPumpTerminal) {
        guard terminal == nil else { return }
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
