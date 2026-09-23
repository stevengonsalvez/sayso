@preconcurrency import AVFoundation
import FluidAudio
import Speech

public enum TranscriptionTermination: Equatable, Sendable {
    case cancelled
    case failed(String)
}

/// Marks one asynchronous transcription run as current until it completes or is cancelled.
struct TranscriptionRunGate: Sendable {
    private var attempt: UUID?

    var isPending: Bool { attempt != nil }
    var current: UUID? { attempt }

    mutating func begin() -> UUID? {
        guard attempt == nil else { return nil }
        let next = UUID()
        attempt = next
        return next
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        attempt == candidate
    }

    mutating func finish(_ candidate: UUID) {
        guard attempt == candidate else { return }
        attempt = nil
    }

    mutating func cancel() {
        attempt = nil
    }
}

public enum SpeechCapabilities {
    public static func supports(_ language: DictationLanguage) -> Bool {
        guard let identifier = language.localeIdentifier else { return true }
        return SFSpeechRecognizer.supportedLocales().contains { $0.identifier == identifier }
    }
}

private final class AudioLevelReporter: Sendable {
    private let receive: @MainActor @Sendable (Float) -> Void

    init(receive: @escaping @MainActor @Sendable (Float) -> Void) {
        self.receive = receive
    }

    func report(_ level: Float) {
        Task { @MainActor [receive] in receive(level) }
    }
}

private func audioLevel(in buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0] else { return 0 }
    var level: Float = 0
    for index in 0..<Int(buffer.frameLength) {
        level = Swift.max(level, abs(samples[index]))
    }
    return level
}

private func makeSpeechTap(
    request: SFSpeechAudioBufferRecognitionRequest,
    levelReporter: AudioLevelReporter
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { [weak request, levelReporter] buffer, _ in
        request?.append(buffer)
        levelReporter.report(audioLevel(in: buffer))
    }
}

private func makePumpTap(
    pump: FluidAudioBufferPump,
    levelReporter: AudioLevelReporter
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { [pump, levelReporter] buffer, _ in
        pump.submit(buffer)
        levelReporter.report(audioLevel(in: buffer))
    }
}

@MainActor
public final class LiveTranscriber: NSObject, ObservableObject {
    @Published public private(set) var phase: SessionPhase = .idle
    @Published public private(set) var partialText = ""
    @Published public private(set) var error: SaysoError?

    private let audioEngine = AVAudioEngine()
    private let fluidAudioModels: FluidAudioLocalModelManager
    private let sherpaPunjabiModels: SherpaPunjabiModelManager
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var fluidAudioSession: FluidAudioLocalSession?
    private var fluidAudioPump: FluidAudioBufferPump?
    private var fluidAudioRunID: UUID?
    private var usesFluidAudio = false
    private var sherpaPunjabiSession: SherpaPunjabiLocalSession?
    private var sherpaPunjabiPump: FluidAudioBufferPump?
    private var sherpaPunjabiRunID: UUID?
    private var usesSherpaPunjabi = false
    private var onFinal: (@Sendable (Transcript) -> Void)?
    private var onPartial: (@Sendable (String) -> Void)?
    private var onTermination: (@Sendable (TranscriptionTermination) -> Void)?
    private var activeLanguage: DictationLanguage = .automatic
    private var activeRoute: ProviderRoute = .appleSpeech
    private var handsFree = false
    private var silenceTask: Task<Void, Never>?
    private var startGate = TranscriptionRunGate()
    private var appleRecognitionRun = TranscriptionRunGate()
    private var appleFinalizationTask: Task<Void, Never>?

    @Published public private(set) var isStarting = false
    public var canStop: Bool { isStarting || phase == .listening }
    public var canStart: Bool { !isStarting && phase != .requestingPermission && phase != .listening && phase != .processing }

    public init(
        fluidAudioModels: FluidAudioLocalModelManager = .init(),
        sherpaPunjabiModels: SherpaPunjabiModelManager = .init()
    ) {
        self.fluidAudioModels = fluidAudioModels
        self.sherpaPunjabiModels = sherpaPunjabiModels
        super.init()
    }

    public func requiresSpeechRecognition(language: DictationLanguage, route: ProviderRoute) -> Bool {
        if FileTranscriber.prefersSherpaPunjabi(language: language, route: route, localModelReady: sherpaPunjabiModels.state.isInstalled) {
            return false
        }
        if route == .local, language == .punjabi {
            return false
        }
        return !FileTranscriber.prefersFluidAudio(
            language: language,
            route: route,
            localModelReady: fluidAudioModels.isInstalled(for: language)
        )
    }

    public func start(
        language: DictationLanguage,
        route: ProviderRoute,
        handsFree: Bool = false,
        onPartial: @escaping @Sendable (String) -> Void = { _ in },
        onTermination: @escaping @Sendable (TranscriptionTermination) -> Void = { _ in },
        onFinal: @escaping @Sendable (Transcript) -> Void
    ) async -> Bool {
        error = nil
        guard !startGate.isPending,
              phase != .requestingPermission, phase != .listening, phase != .processing else {
            return false
        }
        guard route.supportsDictation else {
            fail(.unavailable("Your provider is available for translation, not transcription"))
            return false
        }
        guard let attempt = startGate.begin() else {
            return false
        }
        isStarting = true
        defer { finishStartAttempt(attempt) }
        self.onFinal = onFinal
        self.onPartial = onPartial
        self.onTermination = onTermination
        activeLanguage = language
        activeRoute = route
        self.handsFree = handsFree
        error = nil
        partialText = ""
        phase = .requestingPermission

        if route == .local, language == .punjabi {
            guard sherpaPunjabiModels.state.isInstalled else {
                fail(.unavailable("Download the local Punjabi model before dictating."))
                return false
            }
            guard await microphoneAuthorized(attempt: attempt), isStartCurrent(attempt) else { return false }
            return await startSherpaPunjabi(language: language, route: route, attempt: attempt)
        }
        if route == .local, language != .automatic, !FluidAudioLocalModelManager.supportsNativeModel(for: language) {
            fail(.unavailable("On-device recognition is unavailable for \(language.displayName)"))
            return false
        }
        if shouldUseFluidAudio(language: language, route: route) {
            guard await microphoneAuthorized(attempt: attempt), isStartCurrent(attempt) else { return false }
            return await startFluidAudio(language: language, route: route, attempt: attempt)
        }
        guard SpeechCapabilities.supports(language) else {
            fail(.unavailable("Speech locale \(language.displayName)"))
            return false
        }
        guard await microphoneAuthorized(attempt: attempt), isStartCurrent(attempt),
              await speechAuthorized(attempt: attempt), isStartCurrent(attempt) else { return false }

        let locale = Locale(identifier: language.localeIdentifier ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail(.unavailable("Speech recognizer for \(language.displayName)"))
            return false
        }
        guard route != .local || recognizer.supportsOnDeviceRecognition else {
            fail(.unavailable("On-device recognition is unavailable for \(language.displayName)"))
            return false
        }
        guard let appleRunID = appleRecognitionRun.begin() else {
            fail(.unavailable("Speech recognition is already active"))
            return false
        }

        self.recognizer = recognizer
        phase = .listening

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = route == .local
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let levelReporter = AudioLevelReporter { [weak self] level in self?.observeAudio(level: level) }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: makeSpeechTap(request: request, levelReporter: levelReporter))

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            Task { @MainActor [weak self] in
                self?.receiveAppleRecognition(
                    result: result,
                    error: recognitionError,
                    language: language,
                    route: route,
                    runID: appleRunID
                )
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            return true
        } catch {
            fail(.unavailable("Microphone capture"))
            return false
        }
    }

    public func stop() {
        if startGate.isPending {
            cancelStartAttempt()
            silenceTask?.cancel()
            silenceTask = nil
            phase = .idle
            partialText = ""
            terminate(.cancelled)
            return
        }
        if usesFluidAudio {
            stopFluidAudio()
            return
        }
        if usesSherpaPunjabi {
            stopSherpaPunjabi()
            return
        }
        guard phase == .listening || audioEngine.isRunning else { return }
        phase = .processing
        finishAppleAudioCapture()
    }

    private func observeAudio(level: Float) {
        guard handsFree, phase == .listening else { return }
        if level > 0.015 { silenceTask?.cancel(); silenceTask = nil; return }
        guard silenceTask == nil else { return }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func receiveAppleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        language: DictationLanguage,
        route: ProviderRoute,
        runID: UUID
    ) {
        guard appleRecognitionRun.isCurrent(runID) else { return }
        if let result {
            partialText = result.bestTranscription.formattedString
            onPartial?(result.bestTranscription.formattedString)
            if result.isFinal {
                finish(text: result.bestTranscription.formattedString, language: language, route: route)
            }
        }
        if error != nil {
            if phase == .listening {
                fail(.unavailable("Speech recognition ended"))
            } else if phase == .processing {
                completeAppleFinalization(runID: runID)
            }
        }
    }

    static func prefersNativeFluidAudio(
        language: DictationLanguage,
        route: ProviderRoute,
        models: FluidAudioLocalModelManager
    ) -> Bool {
        FileTranscriber.prefersFluidAudio(
            language: language,
            route: route,
            localModelReady: models.isInstalled(for: language)
        )
    }

    private func shouldUseFluidAudio(language: DictationLanguage, route: ProviderRoute) -> Bool {
        Self.prefersNativeFluidAudio(language: language, route: route, models: fluidAudioModels)
    }

    private func startFluidAudio(language: DictationLanguage, route: ProviderRoute, attempt: UUID) async -> Bool {
        do {
            let session = try await fluidAudioModels.makeReadySession(for: language)
            guard isStartCurrent(attempt) else {
                await session.reset()
                return false
            }
            await session.reset()
            guard isStartCurrent(attempt) else { return false }
            let runID = UUID()
            fluidAudioSession = session
            fluidAudioRunID = runID
            usesFluidAudio = true
            await session.setPartialCallback { [weak self] text in
                Task { @MainActor [weak self] in self?.receiveFluidAudioPartial(text, runID: runID) }
            }
            guard isStartCurrent(attempt) else {
                clearFluidAudioRun(runID: runID)
                await session.reset()
                return false
            }
            let pump = FluidAudioBufferPump { [weak self, session] buffer in
                do {
                    _ = try await session.process(audioBuffer: buffer)
                } catch {
                    Task { @MainActor [weak self] in self?.stopFluidAudio() }
                    throw error
                }
            }
            fluidAudioPump = pump

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let levelReporter = AudioLevelReporter { [weak self] level in self?.observeAudio(level: level) }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: makePumpTap(pump: pump, levelReporter: levelReporter))
            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
            return true
        } catch {
            guard isStartCurrent(attempt) else { return false }
            stopAudioEngine()
            if let session = fluidAudioSession { await session.reset() }
            clearFluidAudioRun()
            fail(.unavailable("Local \(language.displayName) model could not start: \(error.localizedDescription)"))
            return false
        }
    }

    private func receiveFluidAudioPartial(_ text: String, runID: UUID) {
        guard fluidAudioRunID == runID, phase == .listening else { return }
        partialText = text
        onPartial?(text)
    }

    private func startSherpaPunjabi(language: DictationLanguage, route: ProviderRoute, attempt: UUID) async -> Bool {
        do {
            let session = try sherpaPunjabiModels.makeReadySession(for: language)
            guard isStartCurrent(attempt) else {
                await session.reset()
                return false
            }
            await session.reset()
            guard isStartCurrent(attempt) else { return false }
            let runID = UUID()
            sherpaPunjabiSession = session
            sherpaPunjabiRunID = runID
            usesSherpaPunjabi = true
            let pump = FluidAudioBufferPump { [weak self, session] buffer in
                do {
                    try await session.append(audioBuffer: buffer)
                } catch {
                    Task { @MainActor [weak self] in self?.stopSherpaPunjabi() }
                    throw error
                }
            }
            sherpaPunjabiPump = pump

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let levelReporter = AudioLevelReporter { [weak self] level in self?.observeAudio(level: level) }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: makePumpTap(pump: pump, levelReporter: levelReporter))
            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
            return true
        } catch {
            guard isStartCurrent(attempt) else { return false }
            stopAudioEngine()
            if let session = sherpaPunjabiSession { await session.reset() }
            clearSherpaPunjabiRun()
            fail(.unavailable("Local Punjabi model could not start: \(error.localizedDescription)"))
            return false
        }
    }

    private func stopFluidAudio() {
        guard usesFluidAudio, (phase == .listening || audioEngine.isRunning) else { return }
        guard let runID = fluidAudioRunID, let session = fluidAudioSession else { return }
        phase = .processing
        stopAudioEngine()
        silenceTask?.cancel()
        silenceTask = nil
        let pump = fluidAudioPump
        Task { [weak self] in
            let terminal = await pump?.closeAndDrain()
            guard let self else { return }
            switch terminal {
            case let .failed(_, _, message):
                await session.reset()
                self.finishFluidAudioRun(runID: runID, result: .failure(SaysoError.unavailable(message)))
            case let .drained(_, dropped) where dropped > 0:
                await session.reset()
                self.finishFluidAudioRun(
                    runID: runID,
                    result: .failure(SaysoError.unavailable("Local audio processing dropped \(dropped) buffers"))
                )
            case .drained, .none:
                do {
                    let text = try await session.finish()
                    await session.reset()
                    self.finishFluidAudioRun(runID: runID, result: .success(text))
                } catch {
                    await session.reset()
                    self.finishFluidAudioRun(runID: runID, result: .failure(error))
                }
            }
        }
    }

    private func stopSherpaPunjabi() {
        guard usesSherpaPunjabi, (phase == .listening || audioEngine.isRunning) else { return }
        guard let runID = sherpaPunjabiRunID, let session = sherpaPunjabiSession else { return }
        phase = .processing
        stopAudioEngine()
        silenceTask?.cancel()
        silenceTask = nil
        let pump = sherpaPunjabiPump
        Task { [weak self] in
            let terminal = await pump?.closeAndDrain()
            guard let self else { return }
            switch terminal {
            case let .failed(_, _, message):
                await session.reset()
                self.finishSherpaPunjabiRun(runID: runID, result: .failure(SaysoError.unavailable(message)))
            case let .drained(_, dropped) where dropped > 0:
                await session.reset()
                self.finishSherpaPunjabiRun(
                    runID: runID,
                    result: .failure(SaysoError.unavailable("Local audio processing dropped \(dropped) buffers"))
                )
            case .drained, .none:
                do {
                    let text = try await session.finish()
                    await session.reset()
                    self.finishSherpaPunjabiRun(runID: runID, result: .success(text))
                } catch {
                    await session.reset()
                    self.finishSherpaPunjabiRun(runID: runID, result: .failure(error))
                }
            }
        }
    }

    private func finishFluidAudioRun(runID: UUID, result: Result<String, any Error>) {
        guard fluidAudioRunID == runID else { return }
        clearFluidAudioRun(runID: runID)
        switch result {
        case let .success(text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phase = .idle
                terminate(.cancelled)
            } else {
                finish(text: text, language: activeLanguage, route: activeRoute)
            }
        case let .failure(error):
            fail(.unavailable("Local English transcription ended: \(error.localizedDescription)"))
        }
    }

    private func clearFluidAudioRun(runID: UUID? = nil) {
        guard runID == nil || fluidAudioRunID == runID else { return }
        fluidAudioPump = nil
        fluidAudioSession = nil
        fluidAudioRunID = nil
        usesFluidAudio = false
    }

    private func finishSherpaPunjabiRun(runID: UUID, result: Result<String, any Error>) {
        guard sherpaPunjabiRunID == runID else { return }
        clearSherpaPunjabiRun()
        switch result {
        case let .success(text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phase = .idle
                terminate(.cancelled)
            } else {
                finish(text: text, language: activeLanguage, route: activeRoute)
            }
        case let .failure(error):
            fail(.unavailable("Local Punjabi transcription ended: \(error.localizedDescription)"))
        }
    }

    private func clearSherpaPunjabiRun() {
        sherpaPunjabiPump = nil
        sherpaPunjabiSession = nil
        sherpaPunjabiRunID = nil
        usesSherpaPunjabi = false
    }

    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func finishAppleAudioCapture() {
        guard let runID = appleRecognitionRun.current else {
            stopAppleAudioCapture()
            phase = .idle
            terminate(.cancelled)
            return
        }
        stopAudioEngine()
        recognitionRequest?.endAudio()
        silenceTask?.cancel()
        silenceTask = nil
        appleFinalizationTask?.cancel()
        appleFinalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.completeAppleFinalization(runID: runID)
        }
    }

    private func completeAppleFinalization(runID: UUID) {
        guard appleRecognitionRun.isCurrent(runID), phase == .processing else { return }
        if partialText.isEmpty {
            stopAppleAudioCapture()
            phase = .idle
            terminate(.cancelled)
        } else {
            finish(text: partialText, language: activeLanguage, route: activeRoute)
        }
    }

    private func stopAppleAudioCapture() {
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        silenceTask?.cancel()
        silenceTask = nil
        appleFinalizationTask?.cancel()
        appleFinalizationTask = nil
        appleRecognitionRun.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func finish(text: String, language: DictationLanguage, route: ProviderRoute) {
        guard phase != .idle else { return }
        if !usesFluidAudio { stopAppleAudioCapture() }
        let transcript = Transcript(text: text, language: language, route: route, isFinal: true)
        phase = .idle
        onFinal?(transcript)
        onFinal = nil
        onPartial = nil
        onTermination = nil
    }

    private func fail(_ error: SaysoError) {
        cancelStartAttempt()
        stopAppleAudioCapture()
        self.error = error
        phase = .failed
        terminate(.failed(error.localizedDescription))
    }

    private func terminate(_ termination: TranscriptionTermination) {
        onTermination?(termination)
        onFinal = nil
        onPartial = nil
        onTermination = nil
    }

    private func isStartCurrent(_ attempt: UUID) -> Bool {
        startGate.isCurrent(attempt)
    }

    private func finishStartAttempt(_ attempt: UUID) {
        startGate.finish(attempt)
        isStarting = startGate.isPending
    }

    private func cancelStartAttempt() {
        startGate.cancel()
        isStarting = false
    }

    private func microphoneAuthorized(attempt: UUID) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard isStartCurrent(attempt) else { return false }
            guard granted else {
                fail(.permissionDenied("Microphone"))
                return false
            }
            return true
        default:
            guard isStartCurrent(attempt) else { return false }
            fail(.permissionDenied("Microphone"))
            return false
        }
    }

    private func speechAuthorized(attempt: UUID) async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .notDetermined {
            let requested = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if isStartCurrent(attempt), requested == .authorized { return true }
        }
        guard isStartCurrent(attempt) else { return false }
        fail(.permissionDenied("Speech Recognition"))
        return false
    }
}

@MainActor
public enum FileTranscriber {
    private static let maximumAudioFileBytes = 512 * 1024 * 1024

    static func prefersFluidAudio(
        language: DictationLanguage,
        route: ProviderRoute,
        localModelReady: Bool
    ) -> Bool {
        route == .local && FluidAudioLocalModelManager.supportsCurrentHardware
            && FluidAudioLocalModelManager.supportsNativeModel(for: language) && localModelReady
    }

    static func prefersSherpaPunjabi(
        language: DictationLanguage,
        route: ProviderRoute,
        localModelReady: Bool
    ) -> Bool {
        route == .local && language == .punjabi && localModelReady
    }

    public static func transcribe(
        fileURL: URL,
        language: DictationLanguage,
        route: ProviderRoute
    ) async throws -> Transcript {
        guard route.supportsDictation else { throw SaysoError.unavailable("Your provider is available for translation, not transcription") }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SaysoError.invalidAction("Audio file was not found")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumAudioFileBytes {
            throw SaysoError.invalidAction("Audio file exceeds \(maximumAudioFileBytes) bytes")
        }
        let sherpaPunjabiModel = SherpaPunjabiModelManager()
        if route == .local, language == .punjabi {
            guard sherpaPunjabiModel.state.isInstalled else {
                throw SaysoError.unavailable("Download the local Punjabi model before dictating.")
            }
            return try await transcribeWithSherpaPunjabi(
                fileURL: fileURL,
                language: language,
                route: route,
                model: sherpaPunjabiModel
            )
        }
        if route == .local, language != .automatic, !FluidAudioLocalModelManager.supportsNativeModel(for: language) {
            throw SaysoError.unavailable("On-device recognition is unavailable for \(language.displayName)")
        }
        let localModel = FluidAudioLocalModelManager()
        if prefersFluidAudio(language: language, route: route, localModelReady: localModel.isInstalled(for: language)) {
            return try await transcribeWithFluidAudio(fileURL: fileURL, language: language, route: route, model: localModel)
        }
        let authorization = SFSpeechRecognizer.authorizationStatus()
        guard authorization == .authorized else { throw SaysoError.permissionDenied("Speech Recognition") }
        let locale = Locale(identifier: language.localeIdentifier ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SaysoError.unavailable("Speech recognizer for \(language.displayName)")
        }
        guard route != .local || recognizer.supportsOnDeviceRecognition else {
            throw SaysoError.unavailable("On-device recognition is unavailable for \(language.displayName)")
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = route == .local
        let taskBox = FileRecognitionTaskBox()
        let text = try await withCheckedThrowingContinuation { continuation in
            var completed = false
            taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                guard !completed else { return }
                if let result, result.isFinal {
                    completed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    completed = true
                    continuation.resume(throwing: error)
                }
            }
        }
        withExtendedLifetime(taskBox) {}
        return Transcript(text: text, language: language, route: route, isFinal: true)
    }

    private static func transcribeWithFluidAudio(
        fileURL: URL,
        language: DictationLanguage,
        route: ProviderRoute,
        model: FluidAudioLocalModelManager
    ) async throws -> Transcript {
        let session = try await model.makeReadySession(for: language)
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let chunkFrames = AVAudioFrameCount(max(1_024, Int(file.processingFormat.sampleRate / 5)))
            while file.framePosition < file.length {
                let remaining = file.length - file.framePosition
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: min(chunkFrames, AVAudioFrameCount(remaining))
                ) else {
                    throw SaysoError.unavailable("Audio buffer")
                }
                try file.read(into: buffer)
                if buffer.frameLength > 0 {
                    _ = try await session.process(audioBuffer: buffer)
                }
            }
            let text = try await session.finish()
            await session.cleanup()
            return Transcript(text: text, language: language, route: route, isFinal: true)
        } catch {
            await session.cleanup()
            throw error
        }
    }

    private static func transcribeWithSherpaPunjabi(
        fileURL: URL,
        language: DictationLanguage,
        route: ProviderRoute,
        model: SherpaPunjabiModelManager
    ) async throws -> Transcript {
        let session = try model.makeReadySession(for: language)
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let chunkFrames = AVAudioFrameCount(max(1_024, Int(file.processingFormat.sampleRate / 5)))
            while file.framePosition < file.length {
                let remaining = file.length - file.framePosition
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: min(chunkFrames, AVAudioFrameCount(remaining))
                ) else {
                    throw SaysoError.unavailable("Audio buffer")
                }
                try file.read(into: buffer)
                try await session.append(audioBuffer: buffer)
            }
            let text = try await session.finish()
            await session.reset()
            return Transcript(text: text, language: language, route: route, isFinal: true)
        } catch {
            await session.reset()
            throw error
        }
    }
}

@MainActor
private final class FileRecognitionTaskBox {
    var task: SFSpeechRecognitionTask?
}
