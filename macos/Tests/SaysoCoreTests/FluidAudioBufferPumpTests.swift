@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SaysoCore

private actor FirstBufferGate {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var shouldHold = true

    func process(_: AVAudioPCMBuffer) async {
        if !hasStarted {
            hasStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard shouldHold else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
        shouldHold = false
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum PumpFailure: LocalizedError {
    case model

    var errorDescription: String? { "model failure" }
}

private func pcmBuffer(_ value: Float = 0.25) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
    buffer.frameLength = 16
    buffer.floatChannelData![0].initialize(repeating: value, count: 16)
    return buffer
}

@Test func fluidAudioPumpBoundsBufferedAudioAndDrainsInOrder() async {
    let gate = FirstBufferGate()
    let pump = FluidAudioBufferPump { buffer in await gate.process(buffer) }

    #expect(await pump.enqueue(pcmBuffer()) == .accepted)
    await gate.waitUntilStarted()
    for _ in 0..<31 {
        #expect(await pump.enqueue(pcmBuffer()) == .accepted)
    }
    #expect(await pump.enqueue(pcmBuffer()) == .droppedAtCapacity)

    let beforeDrain = await pump.snapshot()
    #expect(beforeDrain.queued == 31)
    #expect(beforeDrain.isProcessing)
    #expect(beforeDrain.dropped == 1)

    async let terminal = pump.closeAndDrain()
    await gate.release()
    #expect(await terminal == .drained(processed: 32, dropped: 1))
}

@Test func fluidAudioPumpCopiesTapBufferBeforeAsyncProcessing() async {
    actor Recorder {
        var samples: [Float] = []

        func append(_ buffer: AVAudioPCMBuffer) {
            samples.append(buffer.floatChannelData![0][0])
        }
    }

    let recorder = Recorder()
    let gate = FirstBufferGate()
    let pump = FluidAudioBufferPump { buffer in
        await gate.process(buffer)
        await recorder.append(buffer)
    }
    let source = pcmBuffer(0.25)

    pump.submit(source)
    await gate.waitUntilStarted()
    source.floatChannelData![0][0] = 0.75

    async let terminal = pump.closeAndDrain()
    await gate.release()
    #expect(await terminal == .drained(processed: 1, dropped: 0))
    #expect(await recorder.samples == [0.25])
}

@Test func fluidAudioPumpDrainsTapBuffersReservedBeforeStop() async {
    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    let counter = Counter()
    let pump = FluidAudioBufferPump { _ in await counter.increment() }
    for _ in 0..<FluidAudioBufferPump.capacity {
        pump.submit(pcmBuffer())
    }

    #expect(await pump.closeAndDrain() == .drained(processed: FluidAudioBufferPump.capacity, dropped: 0))
    #expect(await counter.value == FluidAudioBufferPump.capacity)
}

@Test func fluidAudioPumpReturnsProcessorFailureAfterDrain() async {
    let pump = FluidAudioBufferPump { _ in throw PumpFailure.model }

    #expect(await pump.enqueue(pcmBuffer()) == .accepted)
    #expect(await pump.closeAndDrain() == .failed(processed: 0, dropped: 0, message: "model failure"))
}
