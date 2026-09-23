import AVFoundation
import Speech

public enum TranscriptionTermination: Equatable, Sendable {
    case cancelled
    case failed(String)
}

public enum SpeechCapabilities {
    public static func supports(_ language: DictationLanguage) -> Bool {
        guard let identifier = language.localeIdentifier else { return true }
        return SFSpeechRecognizer.supportedLocales().contains { $0.identifier == identifier }
    }
}

@MainActor
public final class LiveTranscriber: NSObject, ObservableObject {
    @Published public private(set) var phase: SessionPhase = .idle
    @Published public private(set) var partialText = ""
    @Published public private(set) var error: SaysoError?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var onFinal: (@Sendable (Transcript) -> Void)?
    private var onPartial: (@Sendable (String) -> Void)?
    private var onTermination: (@Sendable (TranscriptionTermination) -> Void)?
    private var activeLanguage: DictationLanguage = .automatic
    private var activeRoute: ProviderRoute = .appleSpeech
    private var handsFree = false
    private var silenceTask: Task<Void, Never>?

    public override init() {
        super.init()
    }

    public func start(
        language: DictationLanguage,
        route: ProviderRoute,
        handsFree: Bool = false,
        onPartial: @escaping @Sendable (String) -> Void = { _ in },
        onTermination: @escaping @Sendable (TranscriptionTermination) -> Void = { _ in },
        onFinal: @escaping @Sendable (Transcript) -> Void
    ) async -> Bool {
        guard route.supportsDictation else {
            fail(.unavailable("Your provider is available for translation, not transcription"))
            return false
        }
        guard SpeechCapabilities.supports(language) else {
            fail(.unavailable("Speech locale \(language.displayName)"))
            return false
        }
        guard await microphoneAuthorized(), await speechAuthorized() else { return false }

        let locale = Locale(identifier: language.localeIdentifier ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail(.unavailable("Speech recognizer for \(language.displayName)"))
            return false
        }
        guard route != .local || recognizer.supportsOnDeviceRecognition else {
            fail(.unavailable("On-device recognition is unavailable for \(language.displayName)"))
            return false
        }

        stop()
        self.recognizer = recognizer
        self.onFinal = onFinal
        self.onPartial = onPartial
        self.onTermination = onTermination
        activeLanguage = language
        activeRoute = route
        self.handsFree = handsFree
        error = nil
        partialText = ""
        phase = .listening

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = route == .local
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            var level: Float = 0
            if let channels = buffer.floatChannelData {
                let samples = channels[0]
                for index in 0..<Int(buffer.frameLength) {
                    level = Swift.max(level, abs(samples[index]))
                }
            }
            Task { @MainActor [weak self] in self?.observeAudio(level: level) }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    self.onPartial?(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.finish(text: result.bestTranscription.formattedString, language: language, route: route)
                    }
                }
                if recognitionError != nil, self.phase == .listening {
                    self.fail(.unavailable("Speech recognition ended"))
                }
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
        guard phase == .listening || audioEngine.isRunning else { return }
        phase = .processing
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        silenceTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if !partialText.isEmpty {
            finish(text: partialText, language: activeLanguage, route: activeRoute)
        } else {
            phase = .idle
            terminate(.cancelled)
        }
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

    private func finish(text: String, language: DictationLanguage, route: ProviderRoute) {
        guard phase != .idle else { return }
        let transcript = Transcript(text: text, language: language, route: route, isFinal: true)
        phase = .idle
        onFinal?(transcript)
        onFinal = nil
        onPartial = nil
        onTermination = nil
    }

    private func fail(_ error: SaysoError) {
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

    private func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            fail(.permissionDenied("Microphone"))
            return false
        }
    }

    private func speechAuthorized() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .notDetermined {
            let requested = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if requested == .authorized { return true }
        }
        fail(.permissionDenied("Speech Recognition"))
        return false
    }
}

@MainActor
public enum FileTranscriber {
    private static let maximumAudioFileBytes = 512 * 1024 * 1024

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
}

@MainActor
private final class FileRecognitionTaskBox {
    var task: SFSpeechRecognitionTask?
}
