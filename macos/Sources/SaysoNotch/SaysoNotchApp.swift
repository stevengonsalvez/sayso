import AppKit
import AVFoundation
import Combine
import Darwin
import SaysoCore
import SpeakUpstreamBridge
import SwiftUI
import UniformTypeIdentifiers

@main
struct SaysoNotchApp: App {
    private let instanceLock: SingleInstanceLock?
    @StateObject private var model: SaysoAppModel

    init() {
        switch SingleInstanceLock.acquire() {
        case let .acquired(instanceLock):
            self.instanceLock = instanceLock
        case .unavailable:
            self.instanceLock = nil
        case .held:
            Self.activateExistingInstance()
            DistributedNotificationCenter.default().post(name: saysoReopenNotification, object: nil)
            exit(0)
        }
        _model = StateObject(wrappedValue: SaysoAppModel())
    }

    var body: some Scene {
        MenuBarExtra("Sayso", systemImage: "waveform") {
            MenuContent(model: model)
        }
        WindowGroup("Sayso Notch") {
            SettingsHome(model: model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowResizability(.contentSize)
    }

    private static func activateExistingInstance() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "ai.sayso.notch"
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
            .activate(options: [.activateAllWindows])
    }
}

private final class SingleInstanceLock {
    enum Acquisition {
        case acquired(SingleInstanceLock)
        case held
        case unavailable
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() -> Acquisition {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .unavailable
        }
        let directory = applicationSupport.appendingPathComponent("Sayso Notch", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return .unavailable
        }
        let descriptor = open(
            directory.appendingPathComponent("instance.lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return .unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .held
        }
        return .acquired(Self(descriptor: descriptor))
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private let saysoReopenNotification = Notification.Name("ai.sayso.notch.reopen")

@MainActor
final class SaysoAppModel: ObservableObject {
    private enum DictationStartReservation {
        case reserved
        case rejected(AutomationErrorCode, String)
    }

    private struct PendingDictationDelivery {
        let session: RecordingSession
        let destination: TextOutput.Destination?
        let settings: SaysoSettings
    }

    private final class ControlCommandRun {
        let commands: [String]
        let target: NSRunningApplication
        let installedApplications: [InstalledDesktopApplication]
        var nextCommandIndex = 0
        var hasStarted = false

        init(
            commands: [String],
            target: NSRunningApplication,
            installedApplications: [InstalledDesktopApplication]
        ) {
            self.commands = commands
            self.target = target
            self.installedApplications = installedApplications
        }
    }

    @Published var settings: SaysoSettings
    @Published var lastTranscript: Transcript?
    @Published var controlStatus = "Ready"
    @Published var currentSnapshot: DesktopSnapshot?
    @Published var controlEntries: [ControlAuditEntry] = []
    @Published var pendingControlStep: ControlPlanStep?
    @Published var selectedTab = 0
    @Published var notice: String? {
        didSet {
            noticeDismissalTask?.cancel()
            guard notice != nil else { return }
            noticeDismissalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.notice = nil
            }
        }
    }
    @Published var dictationHotKey = HotKey.custom(keyCode: 49, modifiers: .option)
    @Published private(set) var lastVoiceEditRewrite: String?
    @Published private(set) var isStartingDictation = false
    @Published private(set) var reprocessingHistoryID: UUID?
    @Published private(set) var isImportingHistoryAudio = false
    @Published private(set) var isClearingHistory = false
    @Published private(set) var isHistoryAudioTaskRunning = false
    @Published var onboardingDeferredThisLaunch = false
    @Published private(set) var isOnboardingTestActive = false
    @Published private(set) var onboardingTestTranscriptID: UUID?

    let permissions = PermissionCenter()
    let transcriber: LiveTranscriber
    let localEnglishModel: FluidAudioLocalModelManager
    let localPunjabiModel: SherpaPunjabiModelManager
    let speech = SpeechOutput()
    let history = HistoryStore(maximumEntries: nil)
    let corrections: SaysoCorrectionLearning
    let sessions = RecordingSessionStore()
    let controller = AXDesktopController()
    let desktopControlSession = ControlSession()
    let controlAudit = ControlAuditStore()
    let secrets = KeychainSecretStore()
    private let automation = SaysoAutomationServer()
    private let settingsStore = UserDefaultsSettingsStore()
    private let hotKeyEngine = HotKeyEngine()
    private let notch: NotchPanelController
    private let launchDate = Date()
    private var mainWindow: NSWindow?
    private var lastExternalApplication: NSRunningApplication?
    private var dictationDestination: TextOutput.Destination?
    private var voiceEditCapture: SelectedTextEdit.Capture?
    private var activeRecordingSession: RecordingSession?
    private var pendingVoiceMode: SaysoMode?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionsChangeObserver: AnyCancellable?
    private var correctionChanges: AnyCancellable?
    private var controlRun: ControlCommandRun?
    private var controlExecutionTask: Task<Void, Never>?
    private var controlPreparationTask: Task<Void, Never>?
    private var controlPreparationID: UUID?
    private var historyAudioTask: Task<Void, Never>?
    private var noticeDismissalTask: Task<Void, Never>?
    private var reopenObserver: NSObjectProtocol?
    private var dictationStartCancellationRequested = false
    private var lastDictationStartError: String?
    private var onboardingTestSessionID: UUID?
    private var transcriptProcessingNotice: String?

    init() {
        let localEnglishModel = FluidAudioLocalModelManager()
        let localPunjabiModel = SherpaPunjabiModelManager()
        self.localEnglishModel = localEnglishModel
        self.localPunjabiModel = localPunjabiModel
        transcriber = LiveTranscriber(
            fluidAudioModels: localEnglishModel,
            sherpaPunjabiModels: localPunjabiModel
        )
        var saved = settingsStore.load()
        let persistedSettings = saved
        saved.applyFirstRunDefaults()
        if !saved.route.supportsDictation { saved.route = .local }
        if saved != persistedSettings { settingsStore.save(saved) }
        if CommandLine.arguments.contains("--automation-server") {
            saved.desktopControlEnabled = true
            saved.onboardingCompleted = true
        }
        settings = saved
        corrections = SaysoCorrectionLearning(promotionThreshold: saved.autoCorrectionsPromotionThreshold)
        dictationHotKey = Self.loadDictationHotKey()
        notch = NotchPanelController()
        permissionsChangeObserver = permissions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        correctionChanges = corrections.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        hotKeyEngine.register(gesture: .singleTap) { [weak self] in
            self?.startOrStopDictation()
        }
        hotKeyEngine.register(gesture: .doubleTap) { [weak self] in
            self?.startOrStopVoiceEdit()
        }
        hotKeyEngine.start(for: dictationHotKey)
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: saysoReopenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showMainWindow() }
        }
        observeExternalApplications()
        notch.install(model: self)
        if saved.desktopControlEnabled { startAutomation() }
        DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        Task {
            await history.reclaimUnreferencedAudio(olderThan: launchDate)
            controlEntries = await controlAudit.entries()
            await corrections.waitUntilLoaded()
            guard !settings.legacyLexiconMigrated else { return }
            do {
                try await corrections.importLegacy(settings.lexicon)
                settings.lexicon = [:]
                settings.legacyLexiconMigrated = true
                save()
            } catch {
                notice = "Could not migrate saved corrections."
            }
        }
    }

    func save() {
        if !settings.cloudConsentGranted { settings.cloudCleanupEnabled = false }
        corrections.setPromotionThreshold(settings.autoCorrectionsPromotionThreshold)
        if !settings.autoCorrectionsEnabled { corrections.stopMonitoring() }
        settingsStore.save(settings)
    }

    func setDictationHotKey(_ hotKey: HotKey) {
        dictationHotKey = hotKey
        if let data = try? JSONEncoder().encode(hotKey) {
            UserDefaults.standard.set(data, forKey: Self.dictationHotKeyDefaultsKey)
        }
        hotKeyEngine.start(for: hotKey)
    }

    private static let dictationHotKeyDefaultsKey = "sayso.dictation-hotkey"

    private static func loadDictationHotKey() -> HotKey {
        guard let data = UserDefaults.standard.data(forKey: dictationHotKeyDefaultsKey),
              let hotKey = try? JSONDecoder().decode(HotKey.self, from: data) else {
            return .custom(keyCode: 49, modifiers: .option)
        }
        return hotKey
    }

    private func permissionSummary(_ kind: PermissionKind) -> String {
        switch permissions.states[kind] ?? .unavailable {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        case .unavailable: "unavailable"
        }
    }

    private var microphoneSystemStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    private var localEnglishModelStatus: String {
        switch localEnglishModel.state {
        case .notInstalled: "not-installed"
        case .installing: "installing"
        case .installed: "installed"
        case .failed: "failed"
        }
    }

    private var localIndicModelStatus: String {
        switch localEnglishModel.multilingualState {
        case .notInstalled: "not-installed"
        case .installing: "installing"
        case .installed: "installed"
        case .failed: "failed"
        }
    }

    private var localPunjabiModelStatus: String {
        switch localPunjabiModel.state {
        case .notInstalled: "not-installed"
        case .installing: "installing"
        case .installed: "installed"
        case .failed: "failed"
        }
    }

    func nativeModelReady(for language: DictationLanguage) -> Bool {
        if language == .punjabi { return localPunjabiModel.state.isInstalled }
        guard FluidAudioLocalModelManager.supportsNativeModel(for: language) else { return false }
        return localEnglishModel.isInstalled(for: language)
    }

    func nativeModelDownloadAvailable(for language: DictationLanguage) -> Bool {
        language == .punjabi || FluidAudioLocalModelManager.supportsNativeModel(for: language)
    }

    func startOrStopDictation() {
        if transcriber.canStop {
            transcriber.stop()
            return
        }
        if isStartingDictation {
            dictationStartCancellationRequested = true
            notice = "Cancelling dictation start."
            return
        }
        requestDictationStart(onboardingTest: false)
    }

    func startOnboardingTest() {
        guard !isOnboardingTestActive, !transcriber.canStop else { return }
        requestDictationStart(onboardingTest: true)
    }

    func startOrStopVoiceEdit() {
        if voiceEditCapture != nil, transcriber.canStop {
            transcriber.stop()
            return
        }
        guard !isStartingDictation, transcriber.canStart else {
            notice = "Finish current dictation before voice edit."
            return
        }
        guard settings.voiceEditCloudConsent else {
            notice = "Confirm selected-text cloud consent in Settings before voice edit."
            return
        }
        guard secrets.secret(named: "byok-api-key") != nil,
              let baseURL = URL(string: settings.byokBaseURL),
              ProviderEndpointPolicy.allows(baseURL) else {
            notice = "Configure a compatible BYOK provider before voice edit."
            return
        }
        guard let capture = SelectedTextEdit.capture() else {
            notice = "Select editable text in another app before voice edit."
            return
        }
        lastVoiceEditRewrite = nil
        switch reserveDictationStart() {
        case .reserved:
            voiceEditCapture = capture
            Task { _ = await performDictationStart(voiceEditCapture: capture) }
        case let .rejected(_, message):
            notice = message
        }
    }

    func clearOnboardingTestResult() {
        guard !isOnboardingTestActive else { return }
        onboardingTestTranscriptID = nil
    }

    private func requestDictationStart(onboardingTest: Bool) {
        switch reserveDictationStart() {
        case .reserved:
            Task {
                _ = await performDictationStart(onboardingTest: onboardingTest)
            }
        case let .rejected(_, message):
            notice = message
            return
        }
    }

    private func reserveDictationStart() -> DictationStartReservation {
        guard !isStartingDictation, transcriber.canStart else {
            let message = isStartingDictation || transcriber.isStarting ? "Dictation is already starting." : "Finishing current dictation."
            return .rejected(.alreadyRecording, message)
        }
        guard !isImportingHistoryAudio, reprocessingHistoryID == nil, !isHistoryAudioTaskRunning else {
            return .rejected(.alreadyRecording, "Finish the current history audio task before dictating.")
        }
        guard settings.route.supportsDictation else {
            return .rejected(.transcriptionFailed, "Your provider supports translation, not transcription.")
        }
        guard !settings.route.transmitsData || settings.cloudConsentGranted else {
            return .rejected(.transcriptionFailed, "Confirm the Apple Speech data path before recording.")
        }
        isStartingDictation = true
        dictationStartCancellationRequested = false
        lastDictationStartError = nil
        return .reserved
    }

    private func performDictationStart(
        onboardingTest: Bool = false,
        voiceEditCapture capture: SelectedTextEdit.Capture? = nil
    ) async -> Bool {
        defer {
            isStartingDictation = false
            dictationStartCancellationRequested = false
        }
        notch.show()
        voiceEditCapture = capture
        dictationDestination = !onboardingTest && capture == nil && settings.autoInsert
            ? TextOutput.captureDestination(targetProcessIdentifier: lastExternalApplication?.processIdentifier)
            : nil
        let session = RecordingSession(
            language: settings.language,
            route: settings.route,
            destination: dictationDestination?.recordingDestination
        )
        activeRecordingSession = session
        if onboardingTest {
            onboardingTestSessionID = session.id
            onboardingTestTranscriptID = nil
            isOnboardingTestActive = true
        }
        await sessions.upsert(session)
        guard !dictationStartCancellationRequested else {
            lastDictationStartError = nil
            handleTranscriptionTermination(.cancelled)
            return false
        }
        guard await permissions.authorize(.microphone) == .granted else {
            notice = "Microphone access is required before Sayso can listen. Grant it in Settings."
            failActiveSession(notice ?? "Microphone access denied")
            return false
        }
        guard !dictationStartCancellationRequested else {
            lastDictationStartError = nil
            handleTranscriptionTermination(.cancelled)
            return false
        }
        if transcriber.requiresSpeechRecognition(language: settings.language, route: settings.route) {
            guard await permissions.authorize(.speechRecognition) == .granted else {
                notice = "Speech Recognition access is required before Sayso can transcribe. Grant it in Settings."
                failActiveSession(notice ?? "Speech Recognition access denied")
                return false
            }
        }
        guard !dictationStartCancellationRequested else {
            lastDictationStartError = nil
            handleTranscriptionTermination(.cancelled)
            return false
        }
        restoreDictationTargetFocus()
        let started = await transcriber.start(
                language: settings.language,
                route: settings.route,
                handsFree: settings.handsFree,
                saveAudio: settings.saveSessionAudio && !onboardingTest && capture == nil && settings.mode == .dictation,
                onPartial: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard self?.voiceEditCapture == nil else { return }
                        self?.handleVoiceModeSwitch(text)
                    }
                },
                onTermination: { [weak self] termination in
                    Task { @MainActor [weak self] in self?.handleTranscriptionTermination(termination) }
                }
        ) { [weak self] transcript in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.accept(transcript)
                }
        }
        guard started else {
            guard transcriber.error != nil else {
                lastDictationStartError = nil
                handleTranscriptionTermination(.cancelled)
                return false
            }
            let error = transcriber.error?.localizedDescription ?? "Could not start dictation"
            failActiveSession(error)
            return false
        }
        lastDictationStartError = nil
        updateActiveSession { $0.transition(to: .listening) }
        try? await Task.sleep(for: .milliseconds(250))
        return transcriber.phase == .listening
    }

    /// A first-run permission sheet activates Sayso. Hand focus back to the
    /// captured app so auto-insert still passes its frontmost-target check.
    private func restoreDictationTargetFocus() {
        guard let target = dictationDestination?.recordingDestination.processIdentifier
                ?? voiceEditCapture?.targetProcessIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        NSRunningApplication(processIdentifier: target)?.activate()
    }

    private var automationDictationState: String {
        if transcriber.phase == .listening { return "listening" }
        if isStartingDictation { return "preparing" }
        if let lastDictationStartError { return "failed: \(lastDictationStartError)" }
        return "idle"
    }

    func accept(_ transcript: Transcript) {
        if applyPendingVoiceMode() {
            discardTranscriptAudio(transcript)
            return
        }
        if let capture = voiceEditCapture {
            voiceEditCapture = nil
            guard let delivery = takeActiveDictationDelivery() else {
                discardTranscriptAudio(transcript)
                notice = "Voice edit session was no longer active."
                return
            }
            discardTranscriptAudio(transcript)
            Task { await finishVoiceEdit(transcript, session: delivery.session, capture: capture) }
            return
        }
        if let testID = onboardingTestSessionID, activeRecordingSession?.id == testID {
            guard let delivery = takeActiveDictationDelivery() else {
                discardTranscriptAudio(transcript)
                return
            }
            discardTranscriptAudio(transcript)
            Task { await finishOnboardingTest(transcript, session: delivery.session) }
            return
        }
        guard settings.mode == .dictation else {
            discardTranscriptAudio(transcript)
            updateActiveSession { $0.completeControlCommand(transcript.text) }
            activeRecordingSession = nil
            dictationDestination = nil
            runControl(transcript.text)
            return
        }
        if let current = lastTranscript {
            switch VoiceEdits.outcome(transcript.text, to: current.displayText) {
            case let .applied(edited):
                var updated = current
                updated.text = edited
                updated.translatedText = nil
                lastTranscript = updated
                Task {
                    let historyResult = await history.appendResult(updated)
                    guard lastTranscript?.id == updated.id else { return }
                    if historyResult == .recovered {
                        notice = "Voice edit applied. Recovered unreadable history to a local backup."
                    } else if historyResult == .failed {
                        notice = "Voice edit applied, but history could not save."
                    }
                }
                updateActiveSession { $0.completeVoiceEdit(edited) }
                activeRecordingSession = nil
                dictationDestination = nil
                discardTranscriptAudio(transcript)
                notice = "Voice edit applied."
                return
            case .targetNotFound:
                discardTranscriptAudio(transcript)
                cancelActiveRecordingSession()
                notice = "Voice edit target was not found."
                return
            case .notCommand:
                break
            }
        }
        guard let delivery = takeActiveDictationDelivery() else {
            Task { await deliverUnboundTranscript(transcript) }
            return
        }
        Task {
            await sessions.upsert(delivery.session)
            await finish(await translated(transcript, settings: delivery.settings), delivery: delivery)
        }
    }

    private func discardTranscriptAudio(_ transcript: Transcript) {
        guard let audioFileURL = transcript.audioFileURL else { return }
        SessionAudioArchive.deleteManagedRecording(audioFileURL)
    }

    /// Preserve a final transcript even if an already-terminated recording lost its session record.
    private func deliverUnboundTranscript(_ transcript: Transcript) async {
        let settingsSnapshot = settings
        let completed = await translated(transcript, settings: settingsSnapshot)
        lastTranscript = completed
        let historyResult = await history.appendResult(completed)
        let finalText = completed.displayText
        let copied = TextOutput.copy(finalText)
        if historyResult == .recovered {
            setTranscriptCompletionNotice(copied
                ? "Final text copied. Recovered unreadable history to a local backup."
                : "Dictation finished. Recovered unreadable history to a local backup.")
        } else if historyResult == .failed {
            setTranscriptCompletionNotice(copied ? "Final text copied, but history could not save." : "Dictation finished, but text could not be copied and history could not be saved.")
        } else {
            setTranscriptCompletionNotice(copied ? "Final text copied to clipboard." : "Dictation finished, but final text could not be copied.")
        }
        transcriptProcessingNotice = nil
    }

    private func translated(_ transcript: Transcript, settings currentSettings: SaysoSettings) async -> Transcript {
        transcriptProcessingNotice = nil
        var corrected = transcript
        corrected.text = currentSettings.dictationProfile.postProcess(transcript.text)
        corrected.text = LexiconCorrections.apply(corrected.text, replacements: currentSettings.lexicon)
        corrected.text = corrections.apply(to: corrected.text).transformedText
        corrected.text = await cleaned(corrected.text, language: corrected.language, settings: currentSettings)
        guard currentSettings.translationEnabled else { return corrected }
        guard currentSettings.cloudConsentGranted else {
            transcriptProcessingNotice = "Translation needs cloud consent and a selected provider."
            return corrected
        }
        guard let key = secrets.secret(named: "byok-api-key"),
              let baseURL = URL(string: currentSettings.byokBaseURL) else {
            transcriptProcessingNotice = "Configure BYOK translation in Settings."
            return corrected
        }
        var translated = corrected
        do {
            let translator = OpenAICompatibleTranslator(
                baseURL: baseURL, apiKey: key, model: currentSettings.byokTranslationModel
            )
            translated.translatedText = try await translator.translate(
                corrected.text, from: corrected.language, to: currentSettings.outputLanguage
            )
        } catch {
            transcriptProcessingNotice = "Translation unavailable. Inserted original transcript."
        }
        return translated
    }

    private func cleaned(
        _ text: String,
        language: DictationLanguage,
        settings currentSettings: SaysoSettings
    ) async -> String {
        guard currentSettings.cleanupEnabled else { return text }
        let local = TranscriptCleanup.processLocally(
            text,
            capitalizesFirstLetter: currentSettings.dictationProfile.capitalizesSentences
        )
        guard currentSettings.cloudCleanupEnabled,
              currentSettings.cloudConsentGranted,
              let key = secrets.secret(named: "byok-api-key"),
              let baseURL = URL(string: currentSettings.byokBaseURL),
              ProviderEndpointPolicy.allows(baseURL),
              !currentSettings.byokCleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return local
        }
        do {
            let cloud = try await OpenAICompatibleTranscriptCleaner(
                baseURL: baseURL, apiKey: key, model: currentSettings.byokCleanupModel
            ).clean(text, language: language)
            var cleaned = TranscriptCleanup.processLocally(
                cloud,
                capitalizesFirstLetter: currentSettings.dictationProfile.capitalizesSentences
            )
            cleaned = currentSettings.dictationProfile.postProcess(cleaned)
            cleaned = LexiconCorrections.apply(cleaned, replacements: currentSettings.lexicon)
            return corrections.apply(to: cleaned).transformedText
        } catch {
            transcriptProcessingNotice = "Cloud cleanup unavailable. Applied local cleanup."
            return local
        }
    }

    private func setTranscriptCompletionNotice(_ completion: String) {
        if let transcriptProcessingNotice {
            notice = "\(completion) \(transcriptProcessingNotice)"
        } else {
            notice = completion
        }
    }

    private func finish(_ transcript: Transcript, delivery pendingDelivery: PendingDictationDelivery) async {
        lastTranscript = transcript
        let historyResult = await history.appendResult(transcript)
        let finalText = transcript.displayText
        let output: TextOutput.DeliveryResult
        if pendingDelivery.settings.autoInsert {
            output = TextOutput.insertOrCopy(
                finalText,
                destination: pendingDelivery.destination,
                restoreClipboardAfterPaste: pendingDelivery.settings.restoreClipboardAfterPaste
            )
        } else {
            output = TextOutput.copy(finalText)
                ? .delivered(.clipboard)
                : .pasteFailed(.clipboardUnavailable)
        }
        var session = pendingDelivery.session
        switch output {
        case let .delivered(method):
            if method == .clipboard, activeRecordingSession == nil {
                setTranscriptCompletionNotice("Final text copied to clipboard.")
            }
            session.complete(text: finalText, delivery: method)
        case let .pasteFailed(failure):
            if let fallbackDelivery = failure.fallbackDelivery {
                session.complete(text: finalText, delivery: fallbackDelivery)
            } else {
                session.fail(failure.userMessage)
            }
            if activeRecordingSession == nil {
                setTranscriptCompletionNotice(failure.userMessage)
            }
        }
        if pendingDelivery.settings.autoCorrectionsEnabled,
           case .delivered(.directInsertion) = output {
            corrections.startMonitoring(insertedText: finalText, destination: pendingDelivery.destination)
        }
        if activeRecordingSession == nil {
            if historyResult == .recovered {
                switch output {
                case .delivered:
                    setTranscriptCompletionNotice("Final text delivered. Recovered unreadable history to a local backup.")
                case let .pasteFailed(failure):
                    setTranscriptCompletionNotice("\(failure.userMessage) Recovered unreadable history to a local backup.")
                }
            } else if historyResult == .failed {
                switch output {
                case .delivered:
                    setTranscriptCompletionNotice("Final text delivered, but history could not save.")
                case let .pasteFailed(failure):
                    setTranscriptCompletionNotice("\(failure.userMessage) History could not save.")
                }
            } else if transcriptProcessingNotice != nil {
                setTranscriptCompletionNotice("Final text delivered.")
            }
        }
        await sessions.upsert(session)
        transcriptProcessingNotice = nil
        if activeRecordingSession == nil { notch.hideAfterDelay() }
    }

    private func finishVoiceEdit(
        _ transcript: Transcript,
        session: RecordingSession,
        capture: SelectedTextEdit.Capture
    ) async {
        let instruction = VoiceEditPolicy.normalizedInstruction(transcript.text)
        guard !instruction.isEmpty else {
            await failVoiceEdit(session, message: "Voice edit needs an instruction.")
            return
        }
        guard settings.voiceEditCloudConsent,
              let key = secrets.secret(named: "byok-api-key"),
              let baseURL = URL(string: settings.byokBaseURL),
              ProviderEndpointPolicy.allows(baseURL) else {
            await failVoiceEdit(session, message: "Voice edit provider or consent changed before rewrite.")
            return
        }
        notice = "Rewriting selected text."
        do {
            let rewrite = try await OpenAICompatibleRewriter(
                baseURL: baseURL, apiKey: key, model: settings.byokRewriteModel
            ).rewrite(selection: capture.selectedText, instruction: instruction)
            let result = SelectedTextEdit.replace(rewrite, in: capture)
            var completed = session
            switch result {
            case .replaced:
                lastVoiceEditRewrite = nil
                completed.completeVoiceEdit(rewrite)
            case .replacementUnverified:
                lastVoiceEditRewrite = rewrite
                completed.completeVoiceEdit(rewrite)
            case .noRewrite, .copiedToClipboard:
                lastVoiceEditRewrite = nil
                completed.fail(result.userMessage)
            }
            await sessions.upsert(completed)
            notice = result.userMessage
        } catch {
            await failVoiceEdit(session, message: "Voice edit failed: \(error.localizedDescription)")
            return
        }
        notch.hideAfterDelay()
    }

    private func failVoiceEdit(_ session: RecordingSession, message: String) async {
        var failed = session
        failed.fail(message)
        await sessions.upsert(failed)
        notice = message
        notch.hideAfterDelay()
    }

    private func finishOnboardingTest(_ transcript: Transcript, session: RecordingSession) async {
        onboardingTestTranscriptID = transcript.id
        onboardingTestSessionID = nil
        isOnboardingTestActive = false
        var completed = session
        completed.completeTest(transcript.text)
        await sessions.upsert(completed)
        notice = "Test transcript received."
        notch.hideAfterDelay()
    }

    private func takeActiveDictationDelivery() -> PendingDictationDelivery? {
        guard var session = activeRecordingSession else { return nil }
        session.transition(to: .processing)
        let delivery = PendingDictationDelivery(
            session: session,
            destination: dictationDestination,
            settings: settings
        )
        activeRecordingSession = nil
        dictationDestination = nil
        return delivery
    }

    private func updateActiveSession(_ update: (inout RecordingSession) -> Void) {
        guard var session = activeRecordingSession else { return }
        update(&session)
        activeRecordingSession = session
        Task { await sessions.upsert(session) }
    }

    private func failActiveSession(_ message: String) {
        lastDictationStartError = message
        clearOnboardingTest(for: activeRecordingSession)
        updateActiveSession { $0.fail(message) }
        activeRecordingSession = nil
        dictationDestination = nil
        voiceEditCapture = nil
    }

    private func cancelActiveRecordingSession() {
        clearOnboardingTest(for: activeRecordingSession)
        updateActiveSession { $0.transition(to: .cancelled) }
        activeRecordingSession = nil
        dictationDestination = nil
        voiceEditCapture = nil
    }

    private func handleTranscriptionTermination(_ termination: TranscriptionTermination) {
        guard activeRecordingSession != nil else { return }
        pendingVoiceMode = nil
        switch termination {
        case .cancelled:
            clearOnboardingTest(for: activeRecordingSession)
            updateActiveSession { $0.transition(to: .cancelled) }
            activeRecordingSession = nil
            dictationDestination = nil
            voiceEditCapture = nil
        case let .failed(message):
            failActiveSession(message)
        }
    }

    private func clearOnboardingTest(for session: RecordingSession?) {
        guard let testID = onboardingTestSessionID, session?.id == testID else { return }
        onboardingTestSessionID = nil
        isOnboardingTestActive = false
    }

    func switchMode(_ mode: SaysoMode) {
        guard mode == settings.mode || (!isStartingDictation && transcriber.phase != .requestingPermission && transcriber.phase != .listening && transcriber.phase != .processing) else {
            notice = "Stop dictation before changing modes."
            return
        }
        applyMode(mode)
    }

    private func applyMode(_ mode: SaysoMode) {
        settings.mode = mode
        save()
        notch.show()
    }

    func setOverlayPresentation(_ presentation: OverlayPresentation) {
        settings.overlayPresentation = presentation
        save()
        notch.show()
    }

    func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sayso Notch"
        window.contentView = NSHostingView(rootView: SettingsHome(model: self).frame(minWidth: 1000, minHeight: 680))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    func openSettings() {
        selectedTab = 6
        showMainWindow()
    }

    func quit() {
        save()
        automation.stop()
        NSApplication.shared.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exit(0)
        }
    }

    func saveBYOKKey(_ key: String) {
        guard !key.isEmpty else { return }
        guard let baseURL = URL(string: settings.byokBaseURL), ProviderEndpointPolicy.allows(baseURL) else {
            notice = "BYOK provider must use HTTPS, except localhost HTTP."
            return
        }
        do {
            try secrets.store(key, named: "byok-api-key")
            notice = "BYOK key stored in Keychain."
        } catch {
            notice = "Could not store BYOK key."
        }
    }

    func addLexiconCorrection(_ spoken: String, replacement: String) {
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                try await corrections.addRule(source: spoken, replacement: replacement)
            } catch {
                notice = "Could not save correction."
            }
        }
    }

    func removeLexiconCorrection(_ rule: PersonalLexiconRule) {
        Task {
            do {
                try await corrections.removeRule(id: rule.id)
            } catch {
                notice = "Could not remove correction."
            }
        }
    }

    func promoteCorrection(_ candidate: AutoCorrectionCandidate) {
        Task {
            do {
                try await corrections.promote(candidate)
            } catch {
                notice = "Could not promote correction."
            }
        }
    }

    func dismissCorrection(_ candidate: AutoCorrectionCandidate) {
        Task {
            do {
                try await corrections.dismiss(id: candidate.id)
            } catch {
                notice = "Could not dismiss correction."
            }
        }
    }

    func setAutomation(_ enabled: Bool) {
        settings.desktopControlEnabled = enabled
        if enabled {
            startAutomation()
        } else {
            automation.stop()
            pendingControlStep = nil
            controlPreparationTask?.cancel()
            controlPreparationTask = nil
            controlPreparationID = nil
            if let run = controlRun { requestControlCancellation(run, status: "Desktop control disabled.") }
        }
        save()
    }

    private func startAutomation() {
        do {
            try automation.start { [weak self] request in
                guard let self else {
                    return .failure(
                        id: request.id, command: request.command,
                        error: .init(code: .appUnavailable, message: "Sayso is shutting down.")
                    )
                }
                return await self.handle(request)
            }
            notice = "Local automation enabled."
        } catch {
            settings.desktopControlEnabled = false
            notice = "Could not start local automation."
        }
    }

    private func handleVoiceModeSwitch(_ text: String) {
        let command = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let target: SaysoMode?
        if command.contains("sayso switch to control") {
            target = .control
        } else if command.contains("sayso switch to dictation") {
            target = .dictation
        } else {
            target = nil
        }
        guard let target, target != settings.mode, pendingVoiceMode == nil else { return }
        pendingVoiceMode = target
        notice = "Switching to \(target == .control ? "Control" : "Dictation")…"
        if transcriber.phase == .listening { transcriber.stop() }
    }

    private func applyPendingVoiceMode() -> Bool {
        guard let target = pendingVoiceMode else { return false }
        pendingVoiceMode = nil
        clearOnboardingTest(for: activeRecordingSession)
        updateActiveSession { $0.transition(to: .cancelled) }
        activeRecordingSession = nil
        dictationDestination = nil
        voiceEditCapture = nil
        applyMode(target)
        notice = target == .control ? "Control ready." : "Dictation ready."
        return true
    }

    func speak(_ text: String) {
        speech.speak(
            text,
            language: settings.speechLanguage,
            voiceIdentifier: settings.speechVoiceIdentifier,
            rate: settings.speechRate
        )
    }

    func speakLatest() {
        guard let transcript = lastTranscript else { return }
        let language = transcript.spokenLanguage(outputLanguage: settings.outputLanguage)
        let voiceIdentifier = settings.speechVoiceIdentifier.flatMap { selected in
            SpeechOutput.availableVoices(for: language).contains(where: { $0.id == selected }) ? selected : nil
        }
        speech.speak(transcript.displayText, language: language, voiceIdentifier: voiceIdentifier, rate: settings.speechRate)
    }

    func reprocessHistory(_ entry: Transcript) async {
        guard reprocessingHistoryID == nil, !isImportingHistoryAudio, !isClearingHistory else {
            notice = "Finish the current history audio task before reprocessing."
            return
        }
        guard !isStartingDictation, transcriber.phase == .idle else {
            notice = "Stop dictation before reprocessing saved audio."
            return
        }
        guard let audioFileURL = entry.audioFileURL,
              FileManager.default.fileExists(atPath: audioFileURL.path) else {
            notice = "This history item has no saved audio to reprocess."
            return
        }
        reprocessingHistoryID = entry.id
        defer { reprocessingHistoryID = nil }
        let settingsSnapshot = settings
        notice = "Reprocessing saved audio."
        do {
            var reprocessed = try await FileTranscriber.transcribe(
                fileURL: audioFileURL,
                language: settingsSnapshot.language,
                route: settingsSnapshot.route
            )
            reprocessed.audioFileURL = audioFileURL
            let completed = await translated(reprocessed, settings: settingsSnapshot)
            try Task.checkCancellation()
            guard !completed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SaysoError.invalidAction("No speech detected.")
            }
            guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
                throw SaysoError.unavailable("Saved audio was removed during reprocessing")
            }
            guard await history.append(completed) else {
                notice = "Reprocessed transcript could not save to history."
                transcriptProcessingNotice = nil
                return
            }
            lastTranscript = completed
            setTranscriptCompletionNotice("Reprocessed transcript saved as a new history item.")
            transcriptProcessingNotice = nil
        } catch is CancellationError {
            transcriptProcessingNotice = nil
            notice = "History audio reprocess cancelled."
        } catch {
            transcriptProcessingNotice = nil
            notice = "Could not reprocess saved audio: \(error.localizedDescription)"
        }
    }

    func startReprocessingHistory(_ entry: Transcript) {
        guard !isHistoryAudioTaskRunning else {
            notice = "Finish the current history audio task before reprocessing."
            return
        }
        isHistoryAudioTaskRunning = true
        historyAudioTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isHistoryAudioTaskRunning = false }
            await self.reprocessHistory(entry)
            self.historyAudioTask = nil
        }
    }

    func importHistoryAudio(_ sourceURLs: [URL]) async {
        guard !isImportingHistoryAudio, reprocessingHistoryID == nil, !isClearingHistory else {
            notice = "Finish the current history audio task before importing."
            return
        }
        guard !isStartingDictation, transcriber.phase == .idle else {
            notice = "Stop dictation before importing audio."
            return
        }
        let settingsSnapshot = settings
        isImportingHistoryAudio = true
        defer { isImportingHistoryAudio = false }
        var importedCount = 0
        var failedCount = 0
        var lastFailure: String?
        var processingWarnings = Set<String>()

        for sourceURL in sourceURLs {
            guard !Task.isCancelled else {
                notice = "History audio import cancelled."
                return
            }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }
            var copiedURL: URL?
            do {
                let importedURL = try await Task.detached(priority: .userInitiated) {
                    try SessionAudioArchive.importRecording(from: sourceURL)
                }.value
                copiedURL = importedURL
                try Task.checkCancellation()
                var transcript = try await FileTranscriber.transcribe(
                    fileURL: importedURL,
                    language: settingsSnapshot.language,
                    route: settingsSnapshot.route
                )
                transcript.audioFileURL = importedURL
                let completed = await translated(transcript, settings: settingsSnapshot)
                try Task.checkCancellation()
                guard !completed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SaysoError.invalidAction("No speech detected.")
                }
                guard FileManager.default.fileExists(atPath: importedURL.path) else {
                    throw SaysoError.unavailable("Imported audio was removed before it could be saved")
                }
                guard await history.append(completed) else {
                    throw SaysoError.unavailable("History storage")
                }
                lastTranscript = completed
                if let transcriptProcessingNotice {
                    processingWarnings.insert(transcriptProcessingNotice)
                }
                transcriptProcessingNotice = nil
                importedCount += 1
            } catch is CancellationError {
                if let copiedURL {
                    SessionAudioArchive.deleteManagedRecording(copiedURL)
                }
                transcriptProcessingNotice = nil
                notice = "History audio import cancelled."
                return
            } catch {
                if let copiedURL {
                    SessionAudioArchive.deleteManagedRecording(copiedURL)
                }
                transcriptProcessingNotice = nil
                failedCount += 1
                lastFailure = error.localizedDescription
            }
        }

        let processingWarningSuffix = processingWarnings.isEmpty
            ? ""
            : " \(processingWarnings.sorted().joined(separator: " "))"
        switch (importedCount, failedCount) {
        case (0, _):
            notice = "Could not import the selected audio: \(lastFailure ?? "Unknown error")."
        case (_, 0):
            notice = "Imported \(importedCount) audio \(importedCount == 1 ? "file" : "files") into history.\(processingWarningSuffix)"
        default:
            notice = "Imported \(importedCount) audio \(importedCount == 1 ? "file" : "files"); \(failedCount) could not be imported: \(lastFailure ?? "Unknown error").\(processingWarningSuffix)"
        }
    }

    func startImportHistoryAudio(_ sourceURLs: [URL]) {
        guard !isHistoryAudioTaskRunning else {
            notice = "Finish the current history audio task before importing."
            return
        }
        isHistoryAudioTaskRunning = true
        historyAudioTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isHistoryAudioTaskRunning = false }
            await self.importHistoryAudio(sourceURLs)
            self.historyAudioTask = nil
        }
    }

    func cancelHistoryAudioTask() {
        guard isHistoryAudioTaskRunning, let historyAudioTask else { return }
        historyAudioTask.cancel()
        notice = "Cancelling history audio task."
    }

    func clearHistory() async -> Bool {
        guard !isImportingHistoryAudio, reprocessingHistoryID == nil, !isHistoryAudioTaskRunning, !isClearingHistory else {
            notice = "Finish the current history audio task before clearing history."
            return false
        }
        isClearingHistory = true
        defer { isClearingHistory = false }
        return await history.clear()
    }

    func copyLastVoiceEditRewrite() {
        guard let rewrite = lastVoiceEditRewrite else { return }
        notice = TextOutput.copy(rewrite)
            ? "Voice edit rewrite copied to clipboard."
            : "Could not copy voice edit rewrite."
    }

    private func desktopControlEnabled() -> Bool {
        guard settings.desktopControlEnabled else {
            controlStatus = "Enable desktop control in Settings before acting."
            return false
        }
        return true
    }

    func captureDesktop() {
        guard desktopControlEnabled() else { return }
        do {
            currentSnapshot = try controller.capture(application: controlTarget())
            controlStatus = "Grounded \(currentSnapshot?.applicationName ?? "desktop")"
        } catch {
            controlStatus = error.localizedDescription
        }
    }

    func runSafeDemoControl() {
        guard desktopControlEnabled() else { return }
        captureDesktop()
        guard let snapshot = currentSnapshot else { return }
        Task {
            do {
                _ = try controller.verify(snapshot, targetApplication: controlTarget())
                controlStatus = "Verified focused target"
            } catch {
                controlStatus = error.localizedDescription
            }
        }
    }

    func runControl(_ command: String) {
        guard desktopControlEnabled() else { return }
        guard controlRun == nil, controlPreparationTask == nil else {
            controlStatus = "Control command already active."
            return
        }
        do {
            let target = try controlTarget()
            let commands = try ControlPlanner.commands(from: command)
            let preparationID = UUID()
            controlPreparationID = preparationID
            controlStatus = "Preparing control command"
            controlPreparationTask = Task { [weak self] in
                let applications: [InstalledDesktopApplication]
                if commands.contains(where: { ControlPlanner.requiresInstalledApplicationCatalog(for: $0) }) {
                    applications = await Task.detached(priority: .utility) {
                        InstalledDesktopApplication.available()
                    }.value
                } else {
                    applications = []
                }
                guard !Task.isCancelled,
                      let self,
                      self.controlPreparationID == preparationID else { return }
                self.controlPreparationTask = nil
                self.controlPreparationID = nil
                guard self.controlRun == nil else { return }
                let run = ControlCommandRun(
                    commands: commands,
                    target: target,
                    installedApplications: applications
                )
                self.controlRun = run
                self.executeControlRun(run)
            }
        } catch {
            controlStatus = error.localizedDescription
        }
    }

    func approvePendingControl() {
        guard desktopControlEnabled() else {
            pendingControlStep = nil
            if let run = controlRun { requestControlCancellation(run, status: "Desktop control disabled.") }
            return
        }
        guard let step = pendingControlStep, let run = controlRun else { return }
        pendingControlStep = nil
        executeControlRun(run, approvedStep: step)
    }

    func discardPendingControl() {
        pendingControlStep = nil
        guard let run = controlRun else {
            controlStatus = "Action discarded"
            return
        }
        requestControlCancellation(run, status: "Action discarded")
    }

    func cancelControl() {
        pendingControlStep = nil
        if controlPreparationTask != nil {
            controlPreparationTask?.cancel()
            controlPreparationTask = nil
            controlPreparationID = nil
            controlStatus = "Control command cancelled."
            return
        }
        guard let run = controlRun else {
            controlStatus = "No active control task"
            return
        }
        requestControlCancellation(run, status: "Cancellation requested. Current macOS action may still finish.")
    }

    private func executeControlRun(_ run: ControlCommandRun, approvedStep: ControlPlanStep? = nil) {
        guard controlRun === run, controlExecutionTask == nil else { return }
        guard desktopControlEnabled() else {
            requestControlCancellation(run, status: "Desktop control disabled.")
            return
        }
        controlExecutionTask = Task { [weak self] in
            guard let self else { return }
            var actionWasDispatched = false
            do {
                if !run.hasStarted {
                    _ = await desktopControlSession.beginCommand()
                    run.hasStarted = true
                }
                var carriedStep = approvedStep
                while run.nextCommandIndex < run.commands.count {
                    try Task.checkCancellation()
                    let step: ControlPlanStep
                    let isApprovedStep: Bool
                    if let approvedStep = carriedStep {
                        step = approvedStep
                        carriedStep = nil
                        isApprovedStep = true
                    } else {
                        let snapshot = try controller.capture(application: run.target)
                        currentSnapshot = snapshot
                        step = try ControlPlanner.plan(
                            command: run.commands[run.nextCommandIndex],
                            snapshot: snapshot,
                            installedApplications: run.installedApplications
                        )
                        isApprovedStep = false
                        controlStatus = "Planned: \(step.reason)"
                        if ControlPolicy.requiresConfirmation(step) {
                            pendingControlStep = step
                            controlStatus = "Review required: \(step.reason)"
                            controlExecutionTask = nil
                            return
                        }
                    }
                    try Task.checkCancellation()
                    actionWasDispatched = true
                    let entry = try await controller.execute(step, approved: isApprovedStep, targetApplication: run.target)
                    await controlAudit.append(entry)
                    controlEntries = await controlAudit.entries()
                    guard !Task.isCancelled, controlRun === run else { return }
                    let updated = await desktopControlSession.record(.init(entry.effect))
                    actionWasDispatched = false
                    run.nextCommandIndex += 1
                    guard updated.canRunAction else {
                        controlStatus = "\(entry.result), \(updated.result?.rawValue ?? "stopped")"
                        finishControlRun()
                        return
                    }
                    controlStatus = entry.result
                }
                let completed = await desktopControlSession.complete()
                guard !Task.isCancelled, controlRun === run else { return }
                controlStatus = completed.result == .completed ? "Control completed" : "Control stopped"
                finishControlRun()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, controlRun === run else { return }
                if actionWasDispatched {
                    _ = await desktopControlSession.record(.actionFailed)
                }
                _ = await desktopControlSession.fail()
                controlStatus = error.localizedDescription
                finishControlRun()
            }
        }
    }

    private func finishControlRun() {
        controlRun = nil
        controlExecutionTask = nil
    }

    private func requestControlCancellation(_ run: ControlCommandRun, status: String) {
        controlExecutionTask?.cancel()
        controlStatus = status
        Task { [weak self] in
            guard let self else { return }
            _ = await desktopControlSession.cancel()
            guard controlRun === run else { return }
            controlRun = nil
            controlExecutionTask = nil
        }
    }

    private func controlTarget() throws -> NSRunningApplication {
        guard let app = lastExternalApplication else {
            throw SaysoError.unavailable("Choose another app, then return to Sayso Control")
        }
        return app
    }

    private func observeExternalApplications() {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != ownBundleIdentifier {
            lastExternalApplication = app
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != ownBundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.lastExternalApplication = app
            }
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sayso Notch", systemImage: "waveform.circle.fill")
                .font(.headline)
            Text(model.transcriber.partialText.isEmpty ? "Ready" : model.transcriber.partialText)
                .lineLimit(2)
            Button(model.transcriber.canStop ? "Stop dictation" : model.transcriber.canStart ? "Start dictation" : "Finishing dictation") {
                model.startOrStopDictation()
            }
            .disabled(!model.transcriber.canStop && !model.transcriber.canStart)
            if model.lastVoiceEditRewrite != nil {
                Button("Copy pending voice edit rewrite") { model.copyLastVoiceEditRewrite() }
            }
            Button("Show Sayso Notch") { model.switchMode(model.settings.mode) }
            Button("Open Sayso") { model.showMainWindow() }
            Button("Open Settings") { model.openSettings() }
            Divider()
            Button("Quit Sayso", role: .destructive) { model.quit() }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct SettingsHome: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(SaysoPalette.cobalt, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sayso").font(.headline.weight(.bold))
                        Text("Voice workspace").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)

                List(selection: $model.selectedTab) {
                    Label("Speak", systemImage: "waveform").tag(0)
                    Label("Control", systemImage: "cursorarrow.click").tag(1)
                    Label("History", systemImage: "clock.arrow.circlepath").tag(2)
                    Section("Voice") {
                        Label("Languages", systemImage: "character.bubble").tag(3)
                        Label("Models", systemImage: "cpu").tag(4)
                        Label("Voice output", systemImage: "speaker.wave.2").tag(5)
                    }
                    Label("Settings", systemImage: "gearshape").tag(6)
                }
                .listStyle(.sidebar)

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.transcriber.phase == .listening ? SaysoPalette.crimson : SaysoPalette.cobalt)
                        .frame(width: 8, height: 8)
                    Text(model.transcriber.phase == .listening ? "Listening" : "Ready")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .padding(16)
            }
            .frame(minWidth: 218)
        } detail: {
            switch model.selectedTab {
            case 0: DictationWorkspace(model: model)
            case 1: ControlWorkspace(model: model)
            case 2: HistoryWorkspace(model: model)
            case 3: LanguageWorkspace(model: model)
            case 4: ModelsWorkspace(model: model)
            case 5: VoiceOutputWorkspace(model: model, speech: model.speech)
            default: SaysoSettingsView(model: model)
            }
        }
        .tint(SaysoPalette.cobalt)
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeBanner(text: notice) { model.notice = nil }
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
        .sheet(isPresented: Binding(
            get: { !model.settings.onboardingCompleted && !model.onboardingDeferredThisLaunch },
            set: { _ in }
        )) {
            OnboardingWizard(model: model)
        }
    }
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(SaysoPalette.amber)
            Text(text)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 620)
        .background(SaysoPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(SaysoPalette.amber.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sayso message: \(text)")
    }
}

private struct DictationWorkspace: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Say it. Ship it.").font(.system(size: 32, weight: .bold))
                    Text("Private voice, instant words.").foregroundStyle(.secondary)
                }
                Spacer()
                ModePicker(model: model)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.transcriber.canStop ? "LISTENING" : model.transcriber.canStart ? "DICTATION" : "FINISHING")
                    .font(.caption.weight(.black)).foregroundStyle(SaysoPalette.amber)
                Text(model.transcriber.partialText.isEmpty ? "Tap to start talking" : model.transcriber.partialText)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                Button {
                    model.startOrStopDictation()
                } label: {
                    Label(
                        model.transcriber.canStop ? "Stop" : model.transcriber.canStart ? "Start dictation" : "Finishing dictation",
                        systemImage: model.transcriber.canStop ? "stop.fill" : model.transcriber.canStart ? "mic.fill" : "ellipsis"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.transcriber.canStop ? SaysoPalette.crimson : SaysoPalette.cobalt)
                .disabled(!model.transcriber.canStop && !model.transcriber.canStart)
            }
            .padding(28)
            .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            if let transcript = model.lastTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LAST RESULT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(transcript.displayText).font(.title3)
                    HStack {
                        Button("Speak") { model.speakLatest() }
                        Text(transcript.route.displayName).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(32)
    }
}

private struct VoiceOutputWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var speech: SpeechOutput
    @State private var text = ""
    @State private var historyEntries: [Transcript] = []
    @State private var historyID: Transcript.ID?
    @State private var voices: [SpeechOutput.Voice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(SaysoPalette.amber, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Voice output").font(.largeTitle.bold())
                        Text("Speak any saved or pasted text.").foregroundStyle(SaysoPalette.muted)
                    }
                }
                Spacer()
                if speech.isSpeaking {
                    Label("Speaking", systemImage: "waveform")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SaysoPalette.amber)
                }
            }
            HStack(spacing: 10) {
                Button("Use latest") {
                    guard let transcript = model.lastTranscript else {
                        model.notice = "Dictate or select saved text first."
                        return
                    }
                    text = transcript.displayText
                }
                .disabled(model.lastTranscript == nil)
                Button("Use clipboard") {
                    guard let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty else {
                        model.notice = "Clipboard has no text to speak."
                        return
                    }
                    text = clipboard
                }
                Button {
                    Task { await refreshHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh saved transcripts")
                Picker("Saved transcript", selection: $historyID) {
                    Text("Choose saved text").tag(nil as Transcript.ID?)
                    ForEach(historyEntries) { entry in
                        Text(entry.displayText).lineLimit(1).tag(entry.id as Transcript.ID?)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: historyID) { _, id in
                    if let entry = historyEntries.first(where: { $0.id == id }) { text = entry.displayText }
                }
            }
            .buttonStyle(.bordered)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 180)
                .padding(10)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(SaysoPalette.cobalt.opacity(0.35), lineWidth: 1)
                }
            VStack(spacing: 14) {
                HStack {
                    Picker("Spoken language", selection: $model.settings.speechLanguage) {
                        ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Voice", selection: $model.settings.speechVoiceIdentifier) {
                        Text("System default").tag(nil as String?)
                        ForEach(voices) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack(spacing: 12) {
                    Text("Rate \(model.settings.speechRate, format: .number.precision(.fractionLength(2)))")
                        .font(.caption.weight(.semibold))
                    Text("Slower")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.settings.speechRate, in: 0.2 ... 0.6, step: 0.05)
                    Text("Faster")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button {
                    model.speak(text)
                } label: {
                    Label("Speak", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(SaysoPalette.amber)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isSpeaking)
                Button("Stop", role: .cancel) { speech.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!speech.isSpeaking)
            }
            Spacer()
        }
        .padding(32)
        .task {
            await refreshHistory()
            refreshVoices()
        }
        .onChange(of: model.settings.speechLanguage) { _, _ in
            refreshVoices()
            model.save()
        }
        .onChange(of: model.settings.speechVoiceIdentifier) { _, _ in model.save() }
        .onChange(of: model.settings.speechRate) { _, _ in model.save() }
    }

    private func refreshVoices() {
        voices = SpeechOutput.availableVoices(for: model.settings.speechLanguage)
        if let selected = model.settings.speechVoiceIdentifier,
           !voices.contains(where: { $0.id == selected }) {
            model.settings.speechVoiceIdentifier = nil
        }
    }

    private func refreshHistory() async {
        historyEntries = Array((await model.history.all()).prefix(20))
    }
}

private struct ControlWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(SaysoPalette.cobalt, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Desktop control").font(.largeTitle.bold())
                        Text("Ground. Act. Verify.").foregroundStyle(SaysoPalette.muted)
                    }
                }
                Spacer()
                ModePicker(model: model)
            }
            HStack(spacing: 12) {
                Button {
                    model.captureDesktop()
                } label: {
                    Label("Capture desktop", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(SaysoPalette.cobalt)
                Button {
                    model.runSafeDemoControl()
                } label: {
                    Label("Verify target", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .tint(SaysoPalette.amber)
            }
            .disabled(!model.settings.desktopControlEnabled)
            HStack(spacing: 12) {
                TextField("Type, scroll down, or open https://…", text: $command)
                    .onSubmit { model.runControl(command) }
                    .textFieldStyle(.roundedBorder)
                Button {
                    model.runControl(command)
                } label: {
                    Label("Run", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(SaysoPalette.cobalt)
                Button("Cancel", role: .cancel) { model.cancelControl() }
                    .buttonStyle(.bordered)
            }
            .disabled(!model.settings.desktopControlEnabled)
            if !model.settings.desktopControlEnabled {
                Label("Enable desktop control in Settings before acting.", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SaysoPalette.muted)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Control status", systemImage: "scope")
                        .font(.headline)
                        .foregroundStyle(statusTint)
                    Spacer()
                    Text(model.currentSnapshot == nil ? "Awaiting capture" : "Grounded")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(statusTint, in: Capsule())
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.controlStatus)
                        .font(.body.weight(.medium))
                    if let snapshot = model.currentSnapshot {
                        Label("\(snapshot.applicationName)  •  \(snapshot.windowTitle)", systemImage: "macwindow")
                            .foregroundStyle(SaysoPalette.muted)
                        Label(
                            snapshot.isProtected ? "Protected target, blocked" : "Target eligible for action",
                            systemImage: snapshot.isProtected ? "xmark.shield" : "checkmark.shield"
                        )
                        .foregroundStyle(snapshot.isProtected ? SaysoPalette.crimson : SaysoPalette.amber)
                        if !snapshot.elements.isEmpty {
                            Text("Visible controls: \(snapshot.elements.prefix(4).map(\.title).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(SaysoPalette.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(statusTint, lineWidth: 1)
            }
            if let pending = model.pendingControlStep {
                HStack(spacing: 12) {
                    Label("Review required: \(pending.reason)", systemImage: "exclamationmark.shield")
                        .foregroundStyle(SaysoPalette.amber)
                    Spacer()
                    Button("Discard") { model.discardPendingControl() }
                    Button("Approve") { model.approvePendingControl() }
                        .buttonStyle(.borderedProminent)
                        .tint(SaysoPalette.crimson)
                }
                .padding(14)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(SaysoPalette.amber, lineWidth: 1)
                }
            }
            if !model.controlEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recent control actions", systemImage: "checkmark.seal")
                        .font(.headline)
                        .foregroundStyle(SaysoPalette.amber)
                    ForEach(model.controlEntries.prefix(3)) { entry in
                        Text("\(entry.timestamp.formatted(date: .omitted, time: .shortened))  \(entry.result)")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            Label("Say “type hello”, “click Send”, “scroll down”, or “open https://…”. Secure fields, stale targets, and low-confidence plans are rejected.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(SaysoPalette.muted)
            Spacer()
        }
        .padding(32)
    }

    private var statusTint: Color {
        if model.currentSnapshot?.isProtected == true { return SaysoPalette.crimson }
        return model.currentSnapshot == nil ? SaysoPalette.amber : SaysoPalette.cobalt
    }
}

private struct HistoryWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @State private var entries: [Transcript] = []
    @State private var availableRecordingIDs: Set<Transcript.ID> = []
    @State private var query = ""
    @State private var scope: HistoryScope = .all
    @State private var confirmClear = false
    @State private var deletionCandidate: Transcript?
    @State private var isImportingAudio = false
    @StateObject private var playback = HistoryAudioPlayback()

    private func refreshEntries() async {
        let loaded = await model.history.all()
        entries = loaded
        availableRecordingIDs = Set(loaded.compactMap { transcript in
            guard let audioFileURL = transcript.audioFileURL,
                  FileManager.default.fileExists(atPath: audioFileURL.path) else { return nil }
            return transcript.id
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let displayedEntries = HistoryFilter.matching(
                entries,
                query: query,
                scope: scope,
                availableRecordingIDs: availableRecordingIDs
            )
            let insights = HistoryInsights.make(from: displayedEntries)
            let isFiltered = scope != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            HStack(spacing: 24) {
                Label("\(insights.entries) \(isFiltered ? "matching" : "entries")", systemImage: "text.quote")
                Label("\(insights.words) words", systemImage: "textformat")
                Label("\(insights.activeDays) days", systemImage: "calendar")
                Spacer()
                Button("Import audio") { isImportingAudio = true }
                    .disabled(model.isHistoryAudioTaskRunning || model.isClearingHistory)
                if model.isHistoryAudioTaskRunning {
                    Button("Cancel audio task", role: .cancel) { model.cancelHistoryAudioTask() }
                }
                Button("Copy all history") { Task { TextOutput.copy(await model.history.plainTextExport()) } }
                Button("Clear all history", role: .destructive) { confirmClear = true }
                    .disabled(model.isHistoryAudioTaskRunning || model.isClearingHistory)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal)
            TextField("Search words, translations, language, or route", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            Picker("History filter", selection: $scope) {
                ForEach(HistoryScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            List(displayedEntries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.displayText)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(entry.language.displayName)
                            Text(entry.route.displayName)
                            if entry.hasTranslation { Text("Translated") }
                            if availableRecordingIDs.contains(entry.id) { Text("Recording") }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let audioFileURL = entry.audioFileURL, availableRecordingIDs.contains(entry.id) {
                        Button {
                            Task {
                                guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
                                    availableRecordingIDs.remove(entry.id)
                                    model.notice = "Recording is no longer available."
                                    return
                                }
                                model.startReprocessingHistory(entry)
                                while model.isHistoryAudioTaskRunning {
                                    try? await Task.sleep(for: .milliseconds(100))
                                }
                                await refreshEntries()
                            }
                        } label: {
                            Image(systemName: model.reprocessingHistoryID == entry.id ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isHistoryAudioTaskRunning || model.isClearingHistory)
                        .accessibilityLabel("Reprocess recording")
                        Button {
                            guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
                                availableRecordingIDs.remove(entry.id)
                                model.notice = "Recording is no longer available."
                                return
                            }
                            playback.toggle(entryID: entry.id, url: audioFileURL)
                        } label: {
                            Image(systemName: playback.activeID == entry.id ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(playback.activeID == entry.id ? "Stop recording" : "Play recording")
                    }
                    Menu {
                        Button("Copy transcript") { _ = TextOutput.copy(entry.text) }
                        if entry.hasTranslation, let translatedText = entry.translatedText {
                            Button("Copy translation") { _ = TextOutput.copy(translatedText) }
                        }
                        if let audioFileURL = entry.audioFileURL, availableRecordingIDs.contains(entry.id) {
                            Button("Reveal recording in Finder") {
                                guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
                                    availableRecordingIDs.remove(entry.id)
                                    model.notice = "Recording is no longer available."
                                    return
                                }
                                NSWorkspace.shared.activateFileViewerSelecting([audioFileURL])
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("History actions")
                    Button {
                        deletionCandidate = entry
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.reprocessingHistoryID == entry.id || model.isClearingHistory)
                    .accessibilityLabel("Delete transcript")
                }
            }
        }
        .navigationTitle("History")
        .task { await refreshEntries() }
        .onDisappear { playback.stop() }
        .fileImporter(
            isPresented: $isImportingAudio,
            allowedContentTypes: [.mpeg4Audio, .wav, .mp3, .aiff, UTType(filenameExtension: "caf")!],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task {
                    model.startImportHistoryAudio(urls)
                    while model.isHistoryAudioTaskRunning {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    await refreshEntries()
                }
            case .failure:
                model.notice = "Could not access the selected audio."
            }
        }
        .alert("Clear Sayso history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                playback.stop()
                Task {
                    if await model.clearHistory() {
                        entries = []
                        availableRecordingIDs = []
                        model.lastTranscript = nil
                    } else if !model.isHistoryAudioTaskRunning, !model.isClearingHistory {
                        model.notice = "Could not clear saved history."
                    }
                }
            }
            .disabled(model.isHistoryAudioTaskRunning || model.isClearingHistory)
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes saved transcripts and retained audio from this Mac.") }
        .alert("Delete transcript?", isPresented: Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        ), presenting: deletionCandidate) { candidate in
            Button("Delete", role: .destructive) {
                Task {
                    if playback.activeID == candidate.id { playback.stop() }
                    if await model.history.remove(id: candidate.id) {
                        entries.removeAll { $0.id == candidate.id }
                        availableRecordingIDs.remove(candidate.id)
                        if model.lastTranscript?.id == candidate.id { model.lastTranscript = nil }
                    } else {
                        model.notice = "Could not delete saved transcript."
                    }
                    deletionCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { _ in
            Text("This removes this saved transcript and its retained audio from this Mac.")
        }
    }
}

@MainActor
private final class HistoryAudioPlayback: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var activeID: UUID?
    private var player: AVAudioPlayer?

    func toggle(entryID: UUID, url: URL) {
        if activeID == entryID, player?.isPlaying == true {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        guard player.play() else { return }
        self.player = player
        activeID = entryID
    }

    func stop() {
        player?.stop()
        player = nil
        activeID = nil
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        stop()
    }
}

private struct LanguageWorkspace: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        List {
            Section("Dictation language") {
                Picker("Speak", selection: $model.settings.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Choose Automatic for macOS detection, or lock Sayso to one language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Translation") {
                Toggle("Translate final text", isOn: $model.settings.translationEnabled)
                Picker("Output language", selection: $model.settings.outputLanguage) {
                    ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) { Text($0.displayName).tag($0) }
                }
                if model.settings.translationEnabled && !model.settings.cloudConsentGranted {
                    Label("Translation stays off until cloud consent and provider setup.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.amber)
                }
            }
            Section("Language coverage") {
                ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) { language in
                    HStack {
                        Text(language.displayName)
                        Spacer()
                        let nativeReady = model.nativeModelReady(for: language)
                        let downloadAvailable = model.nativeModelDownloadAvailable(for: language)
                        let appleAvailable = SpeechCapabilities.supports(language)
                        Label(
                            nativeReady ? "On-device ready" : downloadAvailable ? "Download local model" : appleAvailable ? "Apple Speech available" : "Unavailable",
                            systemImage: nativeReady || appleAvailable ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(nativeReady || appleAvailable ? SaysoPalette.cobalt : SaysoPalette.muted)
                    }
                }
            }
        }
        .navigationTitle("Languages")
        .onChange(of: model.settings) { _, _ in model.save() }
    }
}

private struct ModelsWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject private var localEnglishModel: FluidAudioLocalModelManager
    @ObservedObject private var localPunjabiModel: SherpaPunjabiModelManager
    @State private var apiKey = ""

    init(model: SaysoAppModel) {
        self.model = model
        _localEnglishModel = ObservedObject(wrappedValue: model.localEnglishModel)
        _localPunjabiModel = ObservedObject(wrappedValue: model.localPunjabiModel)
    }

    var body: some View {
        Form {
            Section("Speech route") {
                Picker("Active route", selection: $model.settings.route) {
                    ForEach(ProviderRoute.dictationRoutes) { route in
                        Text(route.displayName).tag(route)
                    }
                }
                ForEach(ProviderRoute.dictationRoutes) { route in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.displayName).fontWeight(.semibold)
                            Text(route == .local ? "Private, runs on this Mac." : "Uses Apple or your selected provider.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if route == model.settings.route {
                            Text("Active")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.cobalt)
                        }
                    }
                }
            }
            Section("Native English model") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(FluidAudioLocalModelManager.displayName).fontWeight(.semibold)
                        Text("On-device English streaming. Apple silicon only. About 430 MB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(localModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localEnglishModel.state.isInstalled ? SaysoPalette.cobalt : SaysoPalette.muted)
                }
                if case .installing = localEnglishModel.state {
                    ProgressView(value: localEnglishModel.downloadProgress)
                }
                if localEnglishModel.state.isInstalled {
                    Button("Delete local model", role: .destructive) { localEnglishModel.delete() }
                } else {
                    Button("Download local English model") { Task { await localEnglishModel.install() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SaysoPalette.cobalt)
                        .disabled(localEnglishModel.state == .installing)
                }
                if case let .failed(message) = localEnglishModel.state {
                    Text(message).font(.caption).foregroundStyle(SaysoPalette.crimson)
                }
            }
            Section("Native Indian language model") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(FluidAudioLocalModelManager.multilingualDisplayName).fontWeight(.semibold)
                        Text("Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Telugu and Urdu. Apple silicon only. About 1.5 GB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(multilingualModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localEnglishModel.multilingualState.isInstalled ? SaysoPalette.cobalt : SaysoPalette.muted)
                }
                Text("Runs entirely on this Mac. Model terms: NVIDIA Open Model Development License 1.1.")
                    .font(.caption).foregroundStyle(.secondary)
                if case .installing = localEnglishModel.multilingualState {
                    ProgressView(value: localEnglishModel.multilingualDownloadProgress)
                }
                if localEnglishModel.multilingualState.isInstalled {
                    Button("Delete Indian language model", role: .destructive) { localEnglishModel.deleteMultilingual() }
                } else {
                    Button("Download Indian language model") { Task { await localEnglishModel.install(language: .hindi) } }
                        .buttonStyle(.borderedProminent)
                        .tint(SaysoPalette.cobalt)
                        .disabled(localEnglishModel.multilingualState == .installing)
                }
                if case let .failed(message) = localEnglishModel.multilingualState {
                    Text(message).font(.caption).foregroundStyle(SaysoPalette.crimson)
                }
            }
            Section("Native Punjabi model") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SherpaPunjabiModelManager.displayName).fontWeight(.semibold)
                        Text("Offline Punjabi final transcription. Any Mac. About 198 MB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(punjabiModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localPunjabiModel.state.isInstalled ? SaysoPalette.cobalt : SaysoPalette.muted)
                }
                Text("Runs entirely on this Mac. Model and runtime: Apache-2.0.")
                    .font(.caption).foregroundStyle(.secondary)
                if case .installing = localPunjabiModel.state {
                    ProgressView()
                }
                if localPunjabiModel.state.isInstalled {
                    Button("Delete Punjabi model", role: .destructive) { localPunjabiModel.delete() }
                } else {
                    Button("Download Punjabi model") { Task { await localPunjabiModel.install() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SaysoPalette.cobalt)
                        .disabled(localPunjabiModel.state == .installing)
                }
                if case let .failed(message) = localPunjabiModel.state {
                    Text(message).font(.caption).foregroundStyle(SaysoPalette.crimson)
                }
            }
            Section("Your provider") {
                Text("Optional. Used only after explicit cloud consent. API key stays in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Base URL", text: $model.settings.byokBaseURL)
                TextField("Translation model", text: $model.settings.byokTranslationModel)
                TextField("Voice edit model", text: $model.settings.byokRewriteModel)
                SecureField("API key", text: $apiKey)
                Button("Store key") { model.saveBYOKKey(apiKey); apiKey = "" }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        .onChange(of: model.settings) { _, _ in model.save() }
    }

    private var localModelStatus: String {
        switch localEnglishModel.state {
        case .notInstalled: "Download required"
        case .installing: "Downloading"
        case .installed: "Ready"
        case .failed: "Unavailable"
        }
    }

    private var multilingualModelStatus: String {
        switch localEnglishModel.multilingualState {
        case .notInstalled: "Download required"
        case .installing: "Downloading"
        case .installed: "Ready"
        case .failed: "Unavailable"
        }
    }

    private var punjabiModelStatus: String {
        switch localPunjabiModel.state {
        case .notInstalled: "Download required"
        case .installing: "Downloading"
        case .installed: "Ready"
        case .failed: "Unavailable"
        }
    }
}

private struct SaysoSettingsView: View {
    @ObservedObject var model: SaysoAppModel
    @State private var spoken = ""
    @State private var replacement = ""

    var body: some View {
        Form {
            Section("Language") {
                Picker("Spoken language", selection: $model.settings.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                if model.settings.route == .local, model.nativeModelDownloadAvailable(for: model.settings.language) {
                    Text(model.nativeModelReady(for: model.settings.language)
                        ? "Selected language runs locally on this Mac."
                        : "Download the selected local model in Models before dictating.")
                        .font(.caption)
                        .foregroundStyle(model.nativeModelReady(for: model.settings.language) ? .secondary : SaysoPalette.crimson)
                } else {
                    Text(SpeechCapabilities.supports(model.settings.language) ? "Available on this Mac" : "Unavailable on this Mac, choose another language or cloud route")
                        .font(.caption).foregroundStyle(SpeechCapabilities.supports(model.settings.language) ? .secondary : SaysoPalette.crimson)
                }
                Picker("Speech route", selection: $model.settings.route) {
                    ForEach(ProviderRoute.dictationRoutes) { Text($0.displayName).tag($0) }
                }
                Toggle("Translate final text", isOn: $model.settings.translationEnabled)
                Toggle("Insert final text", isOn: $model.settings.autoInsert)
                Toggle("Restore clipboard after paste fallback", isOn: $model.settings.restoreClipboardAfterPaste)
                    .disabled(!model.settings.autoInsert)
                Toggle("Hands-free, stop after 1.2 seconds of silence", isOn: $model.settings.handsFree)
                Toggle("Save dictation audio in History", isOn: $model.settings.saveSessionAudio)
                Text("New audio stays on this Mac. Existing History audio remains until deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Overlay") {
                Picker("Presentation", selection: Binding(
                    get: { model.settings.overlayPresentation },
                    set: { model.setOverlayPresentation($0) }
                )) {
                    ForEach(OverlayPresentation.allCases) { presentation in
                        Text(presentation.displayName).tag(presentation)
                    }
                }
                Text("Notch sits beside the camera cutout. Floating places a movable Sayso panel on your desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dictation shortcut") {
                HotKeyRecorder("Start or stop dictation", hotKey: Binding(
                    get: { model.dictationHotKey },
                    set: { model.setDictationHotKey($0) }
                ))
                Text("Default: ⌥ Space. Double-tap it with selected text to voice edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                ForEach(PermissionKind.allCases) { permission in
                    HStack {
                        Text(permission.displayName)
                        Spacer()
                        Text(label(for: model.permissions.states[permission] ?? .undetermined))
                        Button("Request") { Task { await model.permissions.request(permission) } }
                    }
                }
            }
            Section("Privacy") {
                Toggle("I understand selected cloud routes transmit data", isOn: $model.settings.cloudConsentGranted)
                Toggle("Allow selected text to go to voice-edit provider", isOn: $model.settings.voiceEditCloudConsent)
                Toggle("Enable desktop control and local automation", isOn: Binding(
                    get: { model.settings.desktopControlEnabled },
                    set: { model.setAutomation($0) }
                ))
            }
            Section("Dictation profile") {
                TextField("Profile name", text: $model.settings.dictationProfile.name)
                Toggle("Normalize whitespace", isOn: $model.settings.dictationProfile.normalizesWhitespace)
                Toggle("Capitalize sentences", isOn: $model.settings.dictationProfile.capitalizesSentences)
            }
            Section("Transcript cleanup") {
                Toggle("Clean final transcripts", isOn: $model.settings.cleanupEnabled)
                Text("Local cleanup removes blank-audio markers and fixes safe spacing and punctuation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.settings.cleanupEnabled {
                    Toggle("Use your cloud model for cleanup", isOn: $model.settings.cloudCleanupEnabled)
                        .disabled(!model.settings.cloudConsentGranted)
                    if model.settings.cloudCleanupEnabled {
                        TextField("Cleanup model", text: $model.settings.byokCleanupModel)
                        Text("Transcript text leaves this Mac only with cloud consent and your stored BYOK key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Smart corrections") {
                Toggle("Learn from edits after dictation", isOn: $model.settings.autoCorrectionsEnabled)
                if model.settings.autoCorrectionsEnabled {
                    Stepper(
                        "Promote after \(model.settings.autoCorrectionsPromotionThreshold) edits",
                        value: $model.settings.autoCorrectionsPromotionThreshold,
                        in: 2 ... 10
                    )
                    if model.corrections.isMonitoring {
                        Label("Watching the last inserted text for an edit", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Heard", text: $spoken)
                    TextField("Write", text: $replacement)
                    Button("Add") {
                        model.addLexiconCorrection(spoken, replacement: replacement)
                        spoken = ""; replacement = ""
                    }
                }
                ForEach(model.corrections.rules) { rule in
                    HStack {
                        Text(rule.aliases.joined(separator: ", ")).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text(rule.canonical)
                        Spacer()
                        Button("Remove") { model.removeLexiconCorrection(rule) }
                    }
                }
                if !model.corrections.candidates.isEmpty {
                    ForEach(model.corrections.candidates) { candidate in
                        HStack {
                            Label("\(candidate.original) → \(candidate.corrected) · \(candidate.seenCount)x", systemImage: "wand.and.stars")
                            Spacer()
                            Button("Dismiss") { model.dismissCorrection(candidate) }
                            Button("Promote") { model.promoteCorrection(candidate) }
                        }
                    }
                }
            }
            CloudProviderSettings(model: model)
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: model.settings) { _, _ in model.save() }
    }

    private func label(for state: PermissionState) -> String {
        switch state {
        case .granted: "Granted"
        case .denied: "Denied"
        case .undetermined: "Needs setup"
        case .unavailable: "Unavailable"
        }
    }
}

extension SaysoAppModel {
    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        switch request.command {
        case .status:
            permissions.refresh()
            return .success(
                id: request.id, command: request.command,
                result: .init(
                    text: "dictation=\(automationDictationState)",
                    model: "\(settings.route.displayName); local-English=\(localEnglishModelStatus); local-Indic=\(localIndicModelStatus); local-Punjabi=\(localPunjabiModelStatus); microphone=\(permissionSummary(.microphone)); raw=\(microphoneSystemStatus); speech=\(permissionSummary(.speechRecognition))",
                    sessionActive: transcriber.phase == .listening,
                    appVersion: "1.0.0"
                )
            )
        case .startDictation:
            switch reserveDictationStart() {
            case let .rejected(code, message):
                return .failure(id: request.id, command: request.command, error: .init(code: code, message: message))
            case .reserved:
                break
            }
            Task { [weak self] in
                guard let self else { return }
                _ = await self.performDictationStart()
            }
            return .success(
                id: request.id,
                command: request.command,
                result: .init(model: settings.route.displayName, sessionActive: false)
            )
        case .stopDictation:
            guard transcriber.canStop || isStartingDictation else {
                return .failure(id: request.id, command: request.command, error: .init(code: .notRecording, message: "Sayso is not listening."))
            }
            startOrStopDictation()
            return .success(id: request.id, command: request.command, result: .init(sessionActive: false))
        case .history:
            let entries = await history.all().prefix(request.resolvedLimit).map {
                AutomationHistoryEntry(
                    id: $0.id.uuidString,
                    text: $0.displayText,
                    createdAt: $0.createdAt,
                    model: $0.route.displayName,
                    durationSeconds: nil,
                    wordCount: $0.text.split(whereSeparator: \.isWhitespace).count
                )
            }
            return .success(id: request.id, command: request.command, result: .init(entries: Array(entries)))
        case .transcribeFile:
            guard let path = request.path else {
                return .failure(id: request.id, command: request.command, error: .init(code: .invalidArgument, message: "transcribe_file requires an audio path."))
            }
            guard !settings.route.transmitsData || settings.cloudConsentGranted else {
                return .failure(
                    id: request.id,
                    command: request.command,
                    error: .init(code: .transcriptionFailed, message: "Confirm the Apple Speech data path before transcribing audio.")
                )
            }
            do {
                let transcript = try await FileTranscriber.transcribe(
                    fileURL: URL(fileURLWithPath: path), language: settings.language, route: settings.route
                )
                let final = await translated(transcript, settings: settings)
                lastTranscript = final
                await history.append(final)
                return .success(
                    id: request.id, command: request.command,
                    result: .init(text: final.displayText, model: final.route.displayName)
                )
            } catch let error as SaysoError {
                return .failure(id: request.id, command: request.command, error: .init(code: .transcriptionFailed, message: error.localizedDescription))
            } catch {
                return .failure(id: request.id, command: request.command, error: .init(code: .transcriptionFailed, message: "File transcription failed."))
            }
        }
    }
}

private struct CloudProviderSettings: View {
    @ObservedObject var model: SaysoAppModel
    @State private var apiKey = ""

    var body: some View {
        Section("BYOK cloud provider") {
            Text("Required only for selected cloud translation and compatible providers. Stored in Keychain, never UserDefaults.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Base URL", text: $model.settings.byokBaseURL)
            TextField("Translation model", text: $model.settings.byokTranslationModel)
            TextField("Voice edit model", text: $model.settings.byokRewriteModel)
            SecureField("API key", text: $apiKey)
            Button("Store key") { model.saveBYOKKey(apiKey); apiKey = "" }
        }
    }
}

private struct OnboardingWizard: View {
    @ObservedObject var model: SaysoAppModel
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    private let steps = ["Language", "Engine", "Delivery", "Permissions"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(SaysoPalette.cobalt)
                VStack(alignment: .leading) {
                    Text("Sayso").font(.title2.bold())
                    Text("Private voice, right where you look.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Step \(page + 1) of \(steps.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SaysoPalette.cobalt)
                    Button("Finish later") { deferSetup() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= page ? SaysoPalette.cobalt : SaysoPalette.outline)
                        .frame(height: 4)
                }
            }
            Group {
                switch page {
                case 0:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your words, your script.").font(.title2.bold())
                        Text("Choose the spoken language. An explicit language keeps recognition focused.")
                            .foregroundStyle(.secondary)
                        Picker("Spoken language", selection: $model.settings.language) {
                            ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Label("Indian languages included: Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Punjabi, Telugu, and Urdu.", systemImage: "character.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose your engine.").font(.title2.bold())
                        Text("On-device keeps recognition local. Download the selected Sayso model before starting, or choose Apple Speech to use Apple’s recognizer.")
                            .foregroundStyle(.secondary)
                        Picker("Speech route", selection: $model.settings.route) {
                            ForEach(ProviderRoute.dictationRoutes) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.settings.route) { _, route in
                            model.clearOnboardingTestResult()
                            guard route == .local, model.settings.language == .automatic else { return }
                            model.settings.language = .english
                        }
                        if model.settings.route.transmitsData {
                            Toggle("I understand Apple Speech may transmit voice data", isOn: $model.settings.cloudConsentGranted)
                        }
                        if model.settings.route == .local,
                           model.nativeModelDownloadAvailable(for: model.settings.language),
                           !model.nativeModelReady(for: model.settings.language) {
                            Button("Download selected local model") {
                                Task {
                                    if model.settings.language == .punjabi {
                                        await model.localPunjabiModel.install()
                                    } else {
                                        await model.localEnglishModel.install(language: model.settings.language)
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.cobalt)
                        }
                        if !engineReady {
                            Label(engineReadinessMessage, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.crimson)
                        }
                    }
                case 2:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose where words land.").font(.title2.bold())
                        Text("Sayso first tries to insert safely into your active app. If macOS blocks that, it can paste while preserving your clipboard.")
                            .foregroundStyle(.secondary)
                        Toggle("Insert final text into active app", isOn: $model.settings.autoInsert)
                        Toggle("Restore clipboard after a paste fallback", isOn: $model.settings.restoreClipboardAfterPaste)
                            .disabled(!model.settings.autoInsert)
                        Text(model.settings.autoInsert
                             ? "Turn restoration off only when you want the transcript left on your clipboard."
                             : "With insertion off, final transcripts copy to your clipboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                default:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Grant only what you use.").font(.title2.bold())
                        Text("Microphone powers dictation. Speech Recognition is only needed for Apple Speech. Accessibility enables safe text insertion. Input Monitoring is only for the global hotkey.")
                            .foregroundStyle(.secondary)
                        ForEach(PermissionKind.allCases) { permission in
                            HStack(spacing: 12) {
                                Image(systemName: model.permissions.states[permission] == .granted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.permissions.states[permission] == .granted ? SaysoPalette.cobalt : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(permission.displayName).fontWeight(.semibold)
                                    Text(permissionDetail(permission))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(permissionAction(permission)) {
                                    Task { await model.permissions.request(permission) }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        if !requiredPermissionsGranted {
                            Label("Grant the required permissions before testing dictation.", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.crimson)
                        } else if model.onboardingTestTranscriptID == nil {
                            Label(
                                model.isOnboardingTestActive
                                    ? "Say a short sentence, then stop the test to verify your first transcript."
                                    : "Start a short test dictation to verify your setup.",
                                systemImage: "checkmark.seal"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Label("First transcript received. Your setup is ready.", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.cobalt)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Back") { page = max(0, page - 1) }.disabled(page == 0)
                Spacer()
                Button(primaryActionTitle) {
                    if page == steps.count - 1 {
                        performFinalStep()
                    } else {
                        page += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
        .padding(32)
        .frame(width: 560, height: 500)
        .onChange(of: model.settings.language) { _, _ in model.clearOnboardingTestResult() }
    }

    private func complete() {
        model.settings.onboardingCompleted = true
        model.save()
        dismiss()
    }

    private func deferSetup() {
        model.onboardingDeferredThisLaunch = true
        dismiss()
    }

    private var engineReady: Bool {
        OnboardingReadiness.engineIsReady(
            route: model.settings.route,
            language: model.settings.language,
            hasLocalModel: model.nativeModelReady(for: model.settings.language),
            cloudConsentGranted: model.settings.cloudConsentGranted
        )
    }

    private var engineReadinessMessage: String {
        switch model.settings.route {
        case .local:
            if model.settings.language == .automatic {
                return "Choose a spoken language for On-device dictation."
            }
            return "Download the selected local model before continuing."
        case .appleSpeech:
            return "Confirm the Apple Speech data path before continuing."
        case .byok:
            return "Choose an available dictation engine."
        }
    }

    private var requiredPermissionsGranted: Bool {
        OnboardingReadiness.hasRequiredPermissions(
            route: model.settings.route,
            microphoneGranted: model.permissions.states[.microphone] == .granted,
            speechRecognitionGranted: model.permissions.states[.speechRecognition] == .granted
        )
    }

    private var primaryActionTitle: String {
        guard page == steps.count - 1 else { return "Continue" }
        if model.isOnboardingTestActive {
            if model.isStartingDictation { return "Cancel test start" }
            if model.transcriber.canStop { return "Stop test" }
            return "Verifying test"
        }
        if model.isStartingDictation { return "Dictation is starting" }
        if model.transcriber.canStop { return "Stop active dictation" }
        if model.onboardingTestTranscriptID != nil { return "Finish setup" }
        return "Start test dictation"
    }

    private var canAdvance: Bool {
        switch page {
        case 1:
            return engineReady
        case steps.count - 1:
            if model.isOnboardingTestActive {
                return model.isStartingDictation || model.transcriber.canStop
            }
            return requiredPermissionsGranted
        default:
            return true
        }
    }

    private func performFinalStep() {
        if model.isOnboardingTestActive {
            if model.isStartingDictation || model.transcriber.canStop {
                model.startOrStopDictation()
            }
        } else if model.isStartingDictation || model.transcriber.canStop {
            model.notice = "Stop active dictation before testing setup."
        } else if model.onboardingTestTranscriptID != nil {
            complete()
        } else {
            model.startOnboardingTest()
        }
    }

    private func permissionAction(_ permission: PermissionKind) -> String {
        model.permissions.states[permission] == .granted ? "Granted" : "Request"
    }

    private func permissionDetail(_ permission: PermissionKind) -> String {
        switch permission {
        case .microphone: "Required to hear dictation."
        case .speechRecognition: "Required to turn voice into text."
        case .accessibility: "Required to insert text into other apps."
        case .inputMonitoring: "Required only for the global hotkey."
        }
    }
}

struct ModePicker: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        HStack(spacing: 3) {
            modeButton(.dictation, title: "Dictation", icon: "waveform")
            modeButton(.control, title: "Control", icon: "cursorarrow.click")
        }
        .padding(3)
        .background(SaysoPalette.surfaceRaised, in: Capsule())
        .overlay {
            Capsule().stroke(SaysoPalette.outline, lineWidth: 1)
        }
        .accessibilityLabel("Mode")
    }

    private func modeButton(_ mode: SaysoMode, title: String, icon: String) -> some View {
        let isSelected = model.settings.mode == mode
        let selectedColor = mode == .dictation ? SaysoPalette.amber : SaysoPalette.cobalt
        return Button {
            model.switchMode(mode)
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? (mode == .dictation ? SaysoPalette.obsidian : .white) : SaysoPalette.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? selectedColor : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum SaysoPalette {
    static let cobalt = Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
    static let amber = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
    static let crimson = Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
    static let obsidian = Color(red: 11 / 255, green: 15 / 255, blue: 23 / 255)
    static let surface = Color(red: 19 / 255, green: 27 / 255, blue: 42 / 255)
    static let surfaceRaised = Color(red: 30 / 255, green: 41 / 255, blue: 59 / 255)
    static let outline = Color(red: 51 / 255, green: 65 / 255, blue: 85 / 255)
    static let muted = Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)
}
