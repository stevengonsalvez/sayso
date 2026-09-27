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
            DistributedNotificationCenter.default().postNotificationName(
                saysoReopenNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
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
        let liveInsertion: TextOutput.LiveInsertion?
        let settings: SaysoSettings
    }

    private final class ControlCommandRun {
        let commands: [String]
        var target: NSRunningApplication
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

    private final class SlmDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: (Double) -> Void

        init(onProgress: @escaping (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = min(0.99, max(0.05, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            onProgress(progress)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
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
            let isPersistent = nextNoticeIsPersistent
            nextNoticeIsPersistent = false
            noticeDismissalTask?.cancel()
            guard notice != nil, !isPersistent else { return }
            noticeDismissalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.notice = nil
            }
        }
    }
    @Published var dictationHotKey = HotKey.custom(keyCode: 49, modifiers: .option)
    @Published var controlHotKey = HotKey.custom(keyCode: 49, modifiers: [.control, .option])
    @Published var toggleNotchHotKey = HotKey.custom(keyCode: 45, modifiers: [.control, .option])
    @Published private(set) var isNotchOverlayVisible = true
    @Published private(set) var lastVoiceEditRewrite: String?
    @Published private(set) var isStartingDictation = false
    @Published private(set) var reprocessingHistoryID: UUID?
    @Published private(set) var isImportingHistoryAudio = false
    @Published private(set) var isClearingHistory = false
    @Published private(set) var isHistoryAudioTaskRunning = false
    @Published var onboardingDeferredThisLaunch = false
    @Published private(set) var isOnboardingTestActive = false
    @Published private(set) var onboardingTestTranscriptID: UUID?
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var hasBYOKKey = false
    @Published var slmStates: [String: LocalSlmState] = [:]
    @Published var slmDownloadProgress: [String: Double] = [:]

    let permissions = PermissionCenter()
    let transcriber: LiveTranscriber
    let localEnglishModel: FluidAudioLocalModelManager
    let localPunjabiModel: SherpaPunjabiModelManager
    let audioInputDeviceController = CoreAudioInputDeviceController()
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
    private let shortcutManager = SaysoShortcutManager()
    private let notch: NotchPanelController
    private var controlKeyDownTime: Date?
    private let launchDate = Date()
    private var mainWindow: NSWindow?
    private var lastExternalApplication: NSRunningApplication?
    private var dictationDestination: TextOutput.Destination?
    private var liveInsertion: TextOutput.LiveInsertion?
    private var voiceEditCapture: SelectedTextEdit.Capture?
    private var activeRecordingSession: RecordingSession?
    private var activeDictationSettings: SaysoSettings?
    private var pendingVoiceMode: SaysoMode?
    private var handsFreeCycle = HandsFreeCycle()
    private var handsFreeDestinationProcessIdentifier: pid_t?
    private var handsFreeDestinationBundleIdentifier: String?
    private var handsFreeDestinationLaunchDate: Date?
    private var handsFreeDestination: TextOutput.Destination?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionsChangeObserver: AnyCancellable?
    private var correctionChanges: AnyCancellable?
    private var controlRun: ControlCommandRun?
    private var controlExecutionTask: Task<Void, Never>?
    private var controlPreparationTask: Task<Void, Never>?
    private var controlPreparationID: UUID?
    private var historyAudioTask: Task<Void, Never>?
    private var noticeDismissalTask: Task<Void, Never>?
    private var nextNoticeIsPersistent = false
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
        audioInputDevices = audioInputDeviceController.inputDevices()
        hasBYOKKey = secrets.secret(named: "byok-api-key") != nil
        dictationHotKey = Self.loadHotKey(for: .dictation)
        controlHotKey = Self.loadHotKey(for: .control)
        toggleNotchHotKey = Self.loadHotKey(for: .toggleNotch)
        hotKeyEngine.updateConfiguration(.init(holdThreshold: saved.hotKeyHoldThresholdSeconds))
        notch = NotchPanelController()
        isNotchOverlayVisible = notch.isVisible
        permissionsChangeObserver = permissions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        correctionChanges = corrections.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        hotKeyEngine.register(gesture: .singleTap) { [weak self] in
            self?.handleTapDictationShortcut()
        }
        hotKeyEngine.register(gesture: .doubleTap) { [weak self] in
            self?.startOrStopVoiceEdit()
        }
        hotKeyEngine.register(gesture: .holdStart) { [weak self] in
            self?.startHoldDictation()
        }
        hotKeyEngine.register(gesture: .holdEnd) { [weak self] in
            self?.stopHoldDictation()
        }
        hotKeyEngine.start(for: dictationHotKey)
        shortcutManager.register(action: .control, hotKey: controlHotKey)
        shortcutManager.register(action: .toggleNotch, hotKey: toggleNotchHotKey)
        shortcutManager.onActionTriggered = { [weak self] action, isKeyDown in
            self?.handleShortcutAction(action, isKeyDown: isKeyDown)
        }
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

        for slm in LocalSlmCatalog.all {
            if LocalSlmCatalog.isInstalled(slm) {
                slmStates[slm.id] = .installed
            }
        }
    }

    func save() {
        if !settings.byokConsentGranted { settings.cloudCleanupEnabled = false }
        corrections.setPromotionThreshold(settings.autoCorrectionsPromotionThreshold)
        if !settings.autoCorrectionsEnabled { corrections.stopMonitoring() }
        hotKeyEngine.updateConfiguration(.init(holdThreshold: settings.hotKeyHoldThresholdSeconds))
        settingsStore.save(settings)
    }

    func refreshAudioInputDevices() {
        audioInputDevices = audioInputDeviceController.inputDevices()
    }

    func setDictationHotKey(_ hotKey: HotKey) {
        dictationHotKey = hotKey
        Self.saveHotKey(hotKey, for: .dictation)
        hotKeyEngine.start(for: hotKey)
    }

    func setControlHotKey(_ hotKey: HotKey) {
        controlHotKey = hotKey
        Self.saveHotKey(hotKey, for: .control)
        shortcutManager.register(action: .control, hotKey: hotKey)
    }

    func setToggleNotchHotKey(_ hotKey: HotKey) {
        toggleNotchHotKey = hotKey
        Self.saveHotKey(hotKey, for: .toggleNotch)
        shortcutManager.register(action: .toggleNotch, hotKey: hotKey)
    }

    func resetShortcutsToDefaults() {
        setDictationHotKey(SaysoShortcutAction.dictation.defaultHotKey)
        setControlHotKey(SaysoShortcutAction.control.defaultHotKey)
        setToggleNotchHotKey(SaysoShortcutAction.toggleNotch.defaultHotKey)
    }

    var shortcutConflicts: [ShortcutConflict] {
        SaysoShortcutManager.detectConflicts(
            dictation: dictationHotKey,
            control: controlHotKey,
            toggleNotch: toggleNotchHotKey
        )
    }

    private func handleShortcutAction(_ action: SaysoShortcutAction, isKeyDown: Bool) {
        switch action {
        case .dictation:
            if isKeyDown {
                handleTapDictationShortcut()
            }
        case .control:
            if isKeyDown {
                handleControlHotKeyDown()
            } else {
                handleControlHotKeyUp()
            }
        case .toggleNotch:
            if isKeyDown {
                toggleNotch()
            }
        }
    }

    private func handleControlHotKeyDown() {
        controlKeyDownTime = Date()
        if transcriber.canStop {
            if settings.mode == .control {
                if !settings.hotKeyActivation.usesPressAndHold {
                    transcriber.stop()
                }
            } else {
                transcriber.stop()
                switchMode(.control)
                requestDictationStart(onboardingTest: false)
            }
        } else if transcriber.canStart {
            switchMode(.control)
            requestDictationStart(onboardingTest: false)
        }
    }

    private func handleControlHotKeyUp() {
        guard let downTime = controlKeyDownTime else { return }
        controlKeyDownTime = nil
        let duration = Date().timeIntervalSince(downTime)
        if duration >= settings.hotKeyHoldThresholdSeconds {
            if transcriber.canStop, settings.mode == .control {
                transcriber.stop()
            }
        } else if settings.hotKeyActivation.usesPressAndHold {
            if transcriber.canStop, settings.mode == .control {
                transcriber.stop()
            }
        }
    }

    var isNotchVisible: Bool { notch.isVisible }
    var isNotchCollapsed: Bool { notch.isCollapsed }

    func toggleNotch() {
        notch.toggle()
        isNotchOverlayVisible = notch.isVisible
    }

    func showNotch() {
        notch.show()
        isNotchOverlayVisible = true
    }

    func hideNotch() {
        notch.hide()
        isNotchOverlayVisible = false
    }

    func setNotchOverlayVisible(_ visible: Bool) {
        if visible {
            showNotch()
        } else {
            hideNotch()
        }
    }

    private static func saveHotKey(_ hotKey: HotKey, for action: SaysoShortcutAction) {
        if let data = try? JSONEncoder().encode(hotKey) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }

    private static func loadHotKey(for action: SaysoShortcutAction) -> HotKey {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let hotKey = try? JSONDecoder().decode(HotKey.self, from: data) else {
            return action.defaultHotKey
        }
        return hotKey
    }

    private func showPersistentNotice(_ message: String) {
        nextNoticeIsPersistent = true
        notice = message
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
            handsFreeCycle.disarm()
            transcriber.stop()
            return
        }
        if isStartingDictation {
            handsFreeCycle.disarm()
            dictationStartCancellationRequested = true
            notice = "Cancelling dictation start."
            return
        }
        if handsFreeCycle.isArmed {
            handsFreeCycle.disarm()
            notice = "Continuous hands-free dictation stopped."
            notch.hideAfterDelay()
            return
        }
        requestDictationStart(onboardingTest: false, rearmHandsFree: settings.handsFreeContinuous)
    }

    var isContinuousDictationArmed: Bool { handsFreeCycle.isArmed }

    private func handleTapDictationShortcut() {
        guard settings.hotKeyActivation.usesTapToggle else { return }
        if settings.mode != .dictation {
            if transcriber.canStop {
                transcriber.stop()
            }
            switchMode(.dictation)
            requestDictationStart(onboardingTest: false, rearmHandsFree: settings.handsFreeContinuous)
            return
        }
        startOrStopDictation()
    }

    private func startHoldDictation() {
        guard settings.hotKeyActivation.usesPressAndHold,
              !transcriber.canStop,
              !isStartingDictation else { return }
        if settings.mode != .dictation {
            switchMode(.dictation)
        }
        requestDictationStart(onboardingTest: false)
    }

    private func stopHoldDictation() {
        guard settings.hotKeyActivation.usesPressAndHold,
              transcriber.canStop || isStartingDictation else { return }
        startOrStopDictation()
    }

    func startOnboardingTest() {
        guard !isOnboardingTestActive, !transcriber.canStop else { return }
        requestDictationStart(onboardingTest: true)
    }

    func startOrStopVoiceEdit() {
        if voiceEditCapture != nil, transcriber.canStop {
            handsFreeCycle.disarm()
            transcriber.stop()
            return
        }
        guard !isStartingDictation, transcriber.canStart else {
            notice = "Finish current dictation before voice edit."
            return
        }
        guard settings.voiceEditCloudConsent else {
            showPersistentNotice("Confirm selected-text cloud consent in Settings before voice edit.")
            return
        }
        guard secrets.secret(named: "byok-api-key") != nil,
              settings.normalizedBYOKBaseURL != nil else {
            showPersistentNotice("Configure a compatible BYOK provider before voice edit.")
            return
        }
        guard let capture = SelectedTextEdit.capture() else {
            showPersistentNotice("Select editable text in another app before voice edit.")
            return
        }
        lastVoiceEditRewrite = nil
        switch reserveDictationStart() {
        case .reserved:
            handsFreeCycle.disarm()
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

    @discardableResult
    private func requestDictationStart(onboardingTest: Bool, rearmHandsFree: Bool = false) -> Bool {
        let isContinuousRearm = rearmHandsFree && handsFreeCycle.isArmed
        if !isContinuousRearm {
            handsFreeCycle.disarm()
            handsFreeDestinationProcessIdentifier = nil
            handsFreeDestinationBundleIdentifier = nil
            handsFreeDestinationLaunchDate = nil
            handsFreeDestination = nil
        }
        switch reserveDictationStart(onboardingTest: onboardingTest) {
        case .reserved:
            let canPinContinuousTarget = isContinuousRearm
                ? handsFreeDestinationProcessIdentifier != nil
                    && handsFreeDestinationBundleIdentifier != nil
                    && handsFreeDestinationLaunchDate != nil
                : lastExternalApplication?.processIdentifier != nil
                    && lastExternalApplication?.bundleIdentifier != nil
                    && lastExternalApplication?.launchDate != nil
            let continuousRequested = rearmHandsFree
                && settings.handsFree
                && settings.handsFreeContinuous
                && settings.autoInsert
            if continuousRequested, !canPinContinuousTarget {
                showPersistentNotice("Continuous dictation could not pin the active app. Recording one phrase instead.")
            }
            handsFreeCycle.start(
                rearmRequested: continuousRequested
                    && canPinContinuousTarget,
                handsFreeEnabled: settings.handsFree,
                isDictationMode: settings.mode == .dictation
            )
            if handsFreeCycle.isArmed, !isContinuousRearm {
                handsFreeDestinationProcessIdentifier = lastExternalApplication?.processIdentifier
                handsFreeDestinationBundleIdentifier = lastExternalApplication?.bundleIdentifier
                handsFreeDestinationLaunchDate = lastExternalApplication?.launchDate
            }
            Task {
                _ = await performDictationStart(
                    onboardingTest: onboardingTest,
                    isContinuousRearm: isContinuousRearm
                )
            }
            return true
        case let .rejected(_, message):
            handsFreeCycle.disarm()
            notice = message
            return false
        }
    }

    private func reserveDictationStart(onboardingTest: Bool = false) -> DictationStartReservation {
        guard !isStartingDictation, transcriber.canStart else {
            let message = isStartingDictation || transcriber.isStarting ? "Dictation is already starting." : "Finishing current dictation."
            return .rejected(.alreadyRecording, message)
        }
        guard !isImportingHistoryAudio, reprocessingHistoryID == nil, !isHistoryAudioTaskRunning else {
            return .rejected(.alreadyRecording, "Finish the current history audio task before dictating.")
        }
        let pinnedApplication = handsFreeDestinationProcessIdentifier
            .flatMap(NSRunningApplication.init(processIdentifier:))
        let destinationApplication = handsFreeCycle.isArmed
            ? pinnedApplication ?? lastExternalApplication
            : lastExternalApplication
        let sessionSettings = settings.resolvedDictationSettings(
            forBundleIdentifier: onboardingTest ? nil : destinationApplication?.bundleIdentifier
        )
        guard sessionSettings.route.supportsDictation else {
            return .rejected(.transcriptionFailed, "Your provider supports translation, not transcription.")
        }
        guard !sessionSettings.route.transmitsData || sessionSettings.hasConsent(for: sessionSettings.route) else {
            return .rejected(.transcriptionFailed, "Confirm the selected cloud data path before recording.")
        }
        if sessionSettings.route == .byok, cloudTranscriptionConfiguration(for: sessionSettings) == nil {
            return .rejected(.transcriptionFailed, "Configure your cloud transcription model and API key before recording.")
        }
        isStartingDictation = true
        dictationStartCancellationRequested = false
        lastDictationStartError = nil
        return .reserved
    }

    private func performDictationStart(
        onboardingTest: Bool = false,
        voiceEditCapture capture: SelectedTextEdit.Capture? = nil,
        isContinuousRearm: Bool = false
    ) async -> Bool {
        defer {
            isStartingDictation = false
            dictationStartCancellationRequested = false
        }
        notch.show()
        voiceEditCapture = capture
        let pinnedApplication = handsFreeDestinationProcessIdentifier
            .flatMap(NSRunningApplication.init(processIdentifier:))
        let destinationApplication = handsFreeCycle.isArmed
            ? pinnedApplication ?? lastExternalApplication
            : lastExternalApplication
        let sessionSettings = settings.resolvedDictationSettings(
            forBundleIdentifier: onboardingTest ? nil : destinationApplication?.bundleIdentifier
        )
        activeDictationSettings = sessionSettings
        let targetProcessIdentifier = destinationApplication?.processIdentifier
        if isContinuousRearm {
            guard let targetProcessIdentifier,
                  let bundleIdentifier = handsFreeDestinationBundleIdentifier,
                  let launchDate = handsFreeDestinationLaunchDate,
                  let application = NSRunningApplication(processIdentifier: targetProcessIdentifier),
                  !application.isTerminated,
                  application.bundleIdentifier == bundleIdentifier,
                  application.launchDate == launchDate,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier else {
                handsFreeCycle.disarm()
                activeDictationSettings = nil
                showPersistentNotice("Continuous dictation stopped because the original app is no longer ready.")
                notch.hideAfterDelay()
                return false
            }
        }
        if isContinuousRearm {
            guard let destination = handsFreeDestination,
                  TextOutput.isFocused(destination) else {
                handsFreeCycle.disarm()
                activeDictationSettings = nil
                showPersistentNotice("Continuous dictation stopped because the original field is no longer ready.")
                notch.hideAfterDelay()
                return false
            }
            dictationDestination = destination
        } else {
            dictationDestination = !onboardingTest && capture == nil && settings.autoInsert
                ? TextOutput.captureDestination(targetProcessIdentifier: targetProcessIdentifier)
                : nil
            if handsFreeCycle.isArmed {
                if let destination = dictationDestination {
                    handsFreeDestination = destination
                } else {
                    handsFreeCycle.disarm()
                    showPersistentNotice("Continuous dictation could not pin this field. Recording one phrase instead.")
                }
            }
        }
        let session = RecordingSession(
            language: sessionSettings.language,
            route: sessionSettings.route,
            destination: dictationDestination?.recordingDestination
        )
        activeRecordingSession = session
        liveInsertion = !onboardingTest && capture == nil && sessionSettings.autoInsert && sessionSettings.livePartialInsertion
            ? dictationDestination.flatMap(TextOutput.LiveInsertion.init(destination:))
            : nil
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
            showPersistentNotice("Microphone access is required before Sayso can listen. Grant it in Settings.")
            failActiveSession(notice ?? "Microphone access denied")
            return false
        }
        guard !dictationStartCancellationRequested else {
            lastDictationStartError = nil
            handleTranscriptionTermination(.cancelled)
            return false
        }
        if transcriber.requiresSpeechRecognition(language: sessionSettings.language, route: sessionSettings.route) {
            guard await permissions.authorize(.speechRecognition) == .granted else {
                showPersistentNotice("Speech Recognition access is required before Sayso can transcribe. Grant it in Settings.")
                failActiveSession(notice ?? "Speech Recognition access denied")
                return false
            }
        }
        guard !dictationStartCancellationRequested else {
            lastDictationStartError = nil
            handleTranscriptionTermination(.cancelled)
            return false
        }
        if !isContinuousRearm { restoreDictationTargetFocus() }
        let maximumDuration: Duration
        if handsFreeCycle.isArmed {
            guard let remainingSessionDuration = handsFreeCycle.remainingSessionDuration(
                maximumSessionDuration: settings.handsFreeMaximumSessionDurationSeconds
            ), remainingSessionDuration >= 5 else {
                cancelActiveRecordingSession()
                showPersistentNotice("Continuous dictation reached its session limit.")
                notch.hideAfterDelay()
                return false
            }
            maximumDuration = .seconds(min(settings.handsFreeMaximumDurationSeconds, remainingSessionDuration))
        } else {
            maximumDuration = .seconds(settings.handsFreeMaximumDurationSeconds)
        }
        let started = await transcriber.start(
                language: sessionSettings.language,
                route: sessionSettings.route,
                handsFree: settings.handsFree,
                handsFreeSilenceDuration: .seconds(settings.handsFreeSilenceSeconds),
                handsFreeMaximumDuration: maximumDuration,
                preferredAudioInputUID: settings.preferredAudioInputUID,
                saveAudio: settings.saveSessionAudio && !onboardingTest && capture == nil && settings.mode == .dictation,
                cloudTranscription: cloudTranscriptionConfiguration(for: sessionSettings),
                onPartial: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard self?.voiceEditCapture == nil else { return }
                        self?.handleDictationPartial(text)
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
        if sessionSettings.soundCues, !isContinuousRearm { NSSound.beep() }
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

    private func handleDictationPartial(_ text: String) {
        handleVoiceModeSwitch(text)
        guard pendingVoiceMode == nil, settings.mode == .dictation else { return }
        _ = liveInsertion?.update(text)
    }

    private var automationDictationState: String {
        if transcriber.phase == .listening { return "listening" }
        if isStartingDictation { return "preparing" }
        if handsFreeCycle.isArmed { return "armed" }
        if let lastDictationStartError { return "failed: \(lastDictationStartError)" }
        return "idle"
    }

    func accept(_ transcript: Transcript) {
        if applyPendingVoiceMode() {
            discardTranscriptAudio(transcript)
            return
        }
        if let capture = voiceEditCapture {
            handsFreeCycle.disarm()
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
            handsFreeCycle.disarm()
            guard let delivery = takeActiveDictationDelivery() else {
                discardTranscriptAudio(transcript)
                return
            }
            discardTranscriptAudio(transcript)
            Task { await finishOnboardingTest(transcript, session: delivery.session) }
            return
        }
        guard settings.mode == .dictation else {
            handsFreeCycle.disarm()
            liveInsertion?.discard()
            liveInsertion = nil
            discardTranscriptAudio(transcript)
            updateActiveSession { $0.completeControlCommand(transcript.text) }
            activeRecordingSession = nil
            activeDictationSettings = nil
            dictationDestination = nil
            runControl(transcript.text)
            return
        }
        if let current = lastTranscript {
            switch VoiceEdits.outcome(transcript.text, to: current.displayText) {
            case let .applied(edited):
                let wasContinuous = handsFreeCycle.isArmed
                handsFreeCycle.disarm()
                liveInsertion?.discard()
                liveInsertion = nil
                var updated = current
                updated.text = edited
                updated.translatedText = nil
                updated.translatedLanguage = nil
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
                notice = wasContinuous ? "Voice edit applied. Continuous dictation stopped." : "Voice edit applied."
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
            handsFreeCycle.disarm()
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
        corrected.text = LexiconCorrections.apply(corrected.text, pronunciations: currentSettings.pronunciations)
        corrected.text = corrections.apply(to: corrected.text).transformedText
        corrected.text = await cleaned(corrected.text, language: corrected.language, settings: currentSettings)
        guard currentSettings.translationEnabled else { return corrected }
        guard currentSettings.byokConsentGranted else {
            transcriptProcessingNotice = "Translation needs cloud consent and a selected provider."
            return corrected
        }
        guard let key = secrets.secret(named: "byok-api-key"),
              let baseURL = currentSettings.normalizedBYOKBaseURL else {
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
            translated.translatedLanguage = currentSettings.outputLanguage
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
        let formatted = TranscriptCleanup.smartFormat(
            text,
            capitalizesFirstLetter: true,
            capitalizesSentences: currentSettings.cleanupPreset != .minimal,
            addsTerminalPunctuation: currentSettings.cleanupPreset != .developer
        )

        var base = formatted
        base = currentSettings.dictationProfile.postProcess(base)
        base = LexiconCorrections.apply(base, replacements: currentSettings.lexicon)
        base = LexiconCorrections.apply(base, pronunciations: currentSettings.pronunciations)
        let local = corrections.apply(to: base).transformedText

        if currentSettings.cleanupMode == .localSLM {
            if let localEndpoint = URL(string: "http://127.0.0.1:11434/v1") {
                let slmModelName = currentSettings.selectedLocalSlmModelId.contains("qwen") ? "qwen2.5:0.5b" : "smollm2:360m"
                do {
                    let localCleaner = OpenAICompatibleTranscriptCleaner(
                        baseURL: localEndpoint,
                        apiKey: "ollama",
                        model: slmModelName
                    )
                    let slmCleaned = try await localCleaner.clean(
                        text,
                        language: language,
                        lexiconDirectives: currentSettings.dictationProfile.cleanupDirectives
                    )
                    var cleaned = TranscriptCleanup.smartFormat(
                        slmCleaned,
                        capitalizesFirstLetter: true,
                        capitalizesSentences: currentSettings.cleanupPreset != .minimal,
                        addsTerminalPunctuation: currentSettings.cleanupPreset != .developer
                    )
                    cleaned = currentSettings.dictationProfile.postProcess(cleaned)
                    cleaned = LexiconCorrections.apply(cleaned, replacements: currentSettings.lexicon)
                    cleaned = LexiconCorrections.apply(cleaned, pronunciations: currentSettings.pronunciations)
                    return corrections.apply(to: cleaned).transformedText
                } catch {
                    // Local server offline, continue with smart rules
                }
            }
            return local
        }

        guard currentSettings.cleanupMode == .cloudLLM || currentSettings.cloudCleanupEnabled,
              currentSettings.byokConsentGranted,
              let key = secrets.secret(named: "byok-api-key"),
              let baseURL = currentSettings.normalizedBYOKBaseURL,
              !currentSettings.byokCleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return local
        }
        do {
            let directives = currentSettings.dictationProfile.cleanupDirectives
            let cloud = try await OpenAICompatibleTranscriptCleaner(
                baseURL: baseURL, apiKey: key, model: currentSettings.byokCleanupModel
            ).clean(text, language: language, lexiconDirectives: directives)
            var cleaned = TranscriptCleanup.smartFormat(
                cloud,
                capitalizesFirstLetter: true,
                capitalizesSentences: currentSettings.cleanupPreset != .minimal,
                addsTerminalPunctuation: currentSettings.cleanupPreset != .developer
            )
            cleaned = currentSettings.dictationProfile.postProcess(cleaned)
            cleaned = LexiconCorrections.apply(cleaned, replacements: currentSettings.lexicon)
            cleaned = LexiconCorrections.apply(cleaned, pronunciations: currentSettings.pronunciations)
            return corrections.apply(to: cleaned).transformedText
        } catch {
            transcriptProcessingNotice = "Cloud cleanup unavailable. Applied smart rules."
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
        if let liveInsertion = pendingDelivery.liveInsertion {
            switch liveInsertion.finalize(finalText) {
            case .applied:
                output = .delivered(.directInsertion)
            case .deferred:
                output = pendingDelivery.settings.autoInsert
                    ? TextOutput.insertOrCopy(
                        finalText,
                        destination: pendingDelivery.destination,
                        restoreClipboardAfterPaste: pendingDelivery.settings.restoreClipboardAfterPaste
                    )
                    : (TextOutput.copy(finalText) ? .delivered(.clipboard) : .pasteFailed(.clipboardUnavailable))
            case .failed:
                if TextOutput.copy(finalText) {
                    transcriptProcessingNotice = "Live text could not be finalized. Final text copied to clipboard."
                    output = .delivered(.clipboard)
                } else {
                    output = .pasteFailed(.clipboardUnavailable)
                }
            }
        } else if pendingDelivery.settings.autoInsert {
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
        if pendingDelivery.settings.soundCues { NSSound.beep() }
        guard activeRecordingSession == nil, !isStartingDictation else { return }
        let wasDelivered: Bool
        switch output {
        case let .delivered(method):
            wasDelivered = method != .clipboard
        case .pasteFailed:
            wasDelivered = false
        }
        if handsFreeCycle.consumeDelivery(
            wasDelivered: wasDelivered,
            handsFreeEnabled: settings.handsFree,
            isDictationMode: settings.mode == .dictation,
            continuousEnabled: settings.handsFreeContinuous,
            autoInsertEnabled: settings.autoInsert,
            maximumSessionDuration: settings.handsFreeMaximumSessionDurationSeconds
        ) {
            if !requestDictationStart(onboardingTest: false, rearmHandsFree: true) {
                notch.hideAfterDelay()
            }
        } else {
            notch.hideAfterDelay()
        }
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
              let baseURL = settings.normalizedBYOKBaseURL else {
            await failVoiceEdit(session, message: "Voice edit provider or consent changed before rewrite.")
            return
        }
        showPersistentNotice("Rewriting selected text.")
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
            liveInsertion: liveInsertion,
            settings: activeDictationSettings ?? settings
        )
        activeRecordingSession = nil
        activeDictationSettings = nil
        dictationDestination = nil
        liveInsertion = nil
        return delivery
    }

    private func updateActiveSession(_ update: (inout RecordingSession) -> Void) {
        guard var session = activeRecordingSession else { return }
        update(&session)
        activeRecordingSession = session
        Task { await sessions.upsert(session) }
    }

    private func failActiveSession(_ message: String) {
        handsFreeCycle.disarm()
        liveInsertion?.discard()
        liveInsertion = nil
        lastDictationStartError = message
        clearOnboardingTest(for: activeRecordingSession)
        updateActiveSession { $0.fail(message) }
        activeRecordingSession = nil
        activeDictationSettings = nil
        dictationDestination = nil
        voiceEditCapture = nil
    }

    private func cancelActiveRecordingSession() {
        handsFreeCycle.disarm()
        liveInsertion?.discard()
        liveInsertion = nil
        clearOnboardingTest(for: activeRecordingSession)
        updateActiveSession { $0.transition(to: .cancelled) }
        activeRecordingSession = nil
        activeDictationSettings = nil
        dictationDestination = nil
        voiceEditCapture = nil
    }

    private func handleTranscriptionTermination(_ termination: TranscriptionTermination) {
        guard activeRecordingSession != nil else { return }
        pendingVoiceMode = nil
        switch termination {
        case .cancelled:
            handsFreeCycle.disarm()
            liveInsertion?.discard()
            liveInsertion = nil
            clearOnboardingTest(for: activeRecordingSession)
            updateActiveSession { $0.transition(to: .cancelled) }
            activeRecordingSession = nil
            activeDictationSettings = nil
            dictationDestination = nil
            voiceEditCapture = nil
            notch.hideAfterDelay()
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
        selectedTab = 10
        showMainWindow()
    }

    func openNotchSettings() {
        selectedTab = 7
        showMainWindow()
    }

    func openShortcutsSettings() {
        selectedTab = 8
        showMainWindow()
    }

    func openTranscriptionSettings() {
        selectedTab = 3
        showMainWindow()
    }

    func openPreProcessingSettings() {
        openTranscriptionSettings()
    }

    func openModelsSettings() {
        selectedTab = 4
        showMainWindow()
    }

    func openAICleanupSettings() {
        selectedTab = 5
        showMainWindow()
    }

    func openPostProcessingSettings() {
        openAICleanupSettings()
    }

    func openVocabularySettings() {
        selectedTab = 6
        showMainWindow()
    }

    func checkSlmStatus(_ manifest: LocalSlmManifest) -> LocalSlmState {
        if let liveState = slmStates[manifest.id], liveState == .installing {
            return .installing
        }
        if LocalSlmCatalog.isInstalled(manifest) {
            return .installed
        }
        return slmStates[manifest.id] ?? .notInstalled
    }

    func installSlm(_ manifest: LocalSlmManifest) async {
        await MainActor.run {
            slmStates[manifest.id] = .installing
            slmDownloadProgress[manifest.id] = 0.05
            notice = "Downloading \(manifest.displayName)..."
        }
        let destDir = LocalSlmCatalog.modelsDirectory()
        let destFile = destDir.appendingPathComponent(manifest.fileName)
        let delegate = SlmDownloadDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.slmDownloadProgress[manifest.id] = progress
            }
        }
        do {
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let (tempURL, response) = try await session.download(from: manifest.downloadURL)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 500
                throw LocalModelInstallError.unexpectedHTTPStatus(manifest.downloadURL, code)
            }
            if FileManager.default.fileExists(atPath: destFile.path) {
                try? FileManager.default.removeItem(at: destFile)
            }
            try FileManager.default.moveItem(at: tempURL, to: destFile)
            await MainActor.run {
                slmStates[manifest.id] = .installed
                slmDownloadProgress[manifest.id] = 1.0
                notice = "\(manifest.displayName) ready on disk."
            }
        } catch {
            await MainActor.run {
                slmStates[manifest.id] = .failed(error.localizedDescription)
                slmDownloadProgress.removeValue(forKey: manifest.id)
                notice = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteSlm(_ manifest: LocalSlmManifest) {
        try? LocalSlmCatalog.delete(manifest)
        slmStates[manifest.id] = .notInstalled
        slmDownloadProgress.removeValue(forKey: manifest.id)
        notice = "\(manifest.displayName) deleted."
    }

    func hasKey(for provider: CloudProvider) -> Bool {
        if provider.id == "ollama" { return true }
        if let key = secrets.secret(named: provider.keychainServiceIdentifier), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if provider.id == "openai" || provider.id == "custom" {
            return hasBYOKKey
        }
        return false
    }

    @discardableResult
    func saveProviderKey(_ key: String, for provider: CloudProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try secrets.store(trimmed, named: provider.keychainServiceIdentifier)
            if provider.id == "openai" || provider.id == "custom" {
                try? secrets.store(trimmed, named: "byok-api-key")
                hasBYOKKey = true
            }
            notice = "\(provider.displayName) key saved in Keychain."
            return true
        } catch {
            notice = "Could not save \(provider.displayName) key."
            return false
        }
    }

    func removeProviderKey(for provider: CloudProvider) {
        secrets.remove(named: provider.keychainServiceIdentifier)
        if provider.id == "openai" || provider.id == "custom" {
            secrets.remove(named: "byok-api-key")
            hasBYOKKey = false
        }
        notice = "\(provider.displayName) key removed from Keychain."
    }

    var hasTypeSafeKey: Bool {
        if let key = secrets.secret(named: "typesafe-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let jevStore = KeychainSecretStore(service: "local.jev-use")
        if let key = jevStore.secret(named: "typesafe-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    func typeSafeKey() -> String? {
        if let key = secrets.secret(named: "typesafe-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let jevStore = KeychainSecretStore(service: "local.jev-use")
        if let key = jevStore.secret(named: "typesafe-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    @discardableResult
    func saveTypeSafeKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try secrets.store(trimmed, named: "typesafe-api-key")
            notice = "TypeSafe / Jev key saved in Keychain."
            objectWillChange.send()
            return true
        } catch {
            notice = "Could not save TypeSafe key."
            return false
        }
    }

    func removeTypeSafeKey() {
        secrets.remove(named: "typesafe-api-key")
        notice = "TypeSafe key removed."
        objectWillChange.send()
    }

    func addPronunciation(_ entry: SaysoPronunciationEntry) {
        settings.pronunciations.append(entry)
        save()
    }

    func updatePronunciation(_ entry: SaysoPronunciationEntry) {
        if let index = settings.pronunciations.firstIndex(where: { $0.id == entry.id }) {
            settings.pronunciations[index] = entry
            save()
        }
    }

    func removePronunciation(_ id: String) {
        settings.pronunciations.removeAll(where: { $0.id == id })
        save()
    }

    func resetPronunciationsToDefaults() {
        settings.pronunciations = PronunciationDefaults.standard
        save()
    }

    func importPronunciations(json: String) throws {
        let imported = try PronunciationJsonCodec.decode(json)
        guard !imported.isEmpty else { return }
        var current = settings.pronunciations
        for entry in imported {
            if let existingIndex = current.firstIndex(where: { $0.word.caseInsensitiveCompare(entry.word) == .orderedSame }) {
                current[existingIndex] = entry
            } else {
                current.append(entry)
            }
        }
        settings.pronunciations = current
        save()
    }

    func exportPronunciationsJson() -> String? {
        try? PronunciationJsonCodec.encode(settings.pronunciations)
    }

    func quit() {
        save()
        automation.stop()
        NSApplication.shared.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exit(0)
        }
    }

    @discardableResult
    func saveBYOKKey(_ key: String) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return false }
        guard settings.normalizedBYOKBaseURL != nil else {
            showPersistentNotice("BYOK provider must use HTTPS, except localhost HTTP.")
            return false
        }
        do {
            try secrets.store(trimmedKey, named: "byok-api-key")
            hasBYOKKey = true
            notice = "BYOK key stored in Keychain."
            return true
        } catch {
            notice = "Could not store BYOK key."
            return false
        }
    }

    func refreshBYOKKeyStatus() {
        hasBYOKKey = secrets.secret(named: "byok-api-key") != nil
    }

    var isBYOKBaseURLValid: Bool {
        settings.normalizedBYOKBaseURL != nil
    }

    var isBYOKConfigured: Bool {
        OnboardingReadiness.isBYOKConfigured(
            baseURLString: settings.byokBaseURL,
            transcriptionModel: settings.byokTranscriptionModel,
            hasAPIKey: hasBYOKKey
        )
    }

    private func cloudTranscriptionConfiguration(
        for currentSettings: SaysoSettings
    ) -> OpenAICompatibleAudioTranscriptionConfiguration? {
        guard currentSettings.route == .byok,
              currentSettings.byokConsentGranted,
              let apiKey = secrets.secret(named: "byok-api-key"),
              let baseURL = currentSettings.normalizedBYOKBaseURL else {
            return nil
        }
        let model = currentSettings.byokTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return .init(baseURL: baseURL, apiKey: apiKey, model: model)
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

    func addDictationProfileOverrideForLastExternalApp() {
        guard let application = lastExternalApplication,
              let bundleIdentifier = application.bundleIdentifier else {
            notice = "Choose the app to customize, then return to Sayso."
            return
        }
        guard !settings.dictationProfileOverrides.contains(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) else {
            notice = "An app profile already exists for \(application.localizedName ?? bundleIdentifier)."
            return
        }
        let defaultProfile = settings.dictationProfile
        let profile = DictationProfile(
            name: application.localizedName ?? bundleIdentifier,
            corrections: defaultProfile.corrections,
            normalizesWhitespace: defaultProfile.normalizesWhitespace,
            capitalizesSentences: defaultProfile.capitalizesSentences,
            cleanupDirectives: defaultProfile.cleanupDirectives
        )
        settings.dictationProfileOverrides.append(.init(bundleIdentifier: bundleIdentifier, profile: profile))
        save()
        notice = "Added app profile for \(application.localizedName ?? bundleIdentifier)."
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
        showPersistentNotice("Switching to \(target == .control ? "Control" : "Dictation")…")
        if transcriber.phase == .listening { transcriber.stop() }
    }

    private func applyPendingVoiceMode() -> Bool {
        guard let target = pendingVoiceMode else { return false }
        handsFreeCycle.disarm()
        liveInsertion?.discard()
        liveInsertion = nil
        pendingVoiceMode = nil
        clearOnboardingTest(for: activeRecordingSession)
        updateActiveSession { $0.transition(to: .cancelled) }
        activeRecordingSession = nil
        activeDictationSettings = nil
        dictationDestination = nil
        voiceEditCapture = nil
        applyMode(target)
        notice = target == .control ? "Control ready." : "Dictation ready."
        return true
    }

    func speak(_ text: String, language: DictationLanguage? = nil) {
        let resolvedLanguage = language ?? settings.speechLanguage
        speech.speak(
            text,
            language: resolvedLanguage,
            voiceIdentifier: selectedVoice(for: resolvedLanguage),
            rate: settings.speechRate
        )
    }

    func speakLatest() {
        guard let transcript = lastTranscript else { return }
        let transcriptLanguage = transcript.spokenLanguage(outputLanguage: settings.outputLanguage)
        let language = transcriptLanguage == .automatic ? settings.speechLanguage : transcriptLanguage
        speech.speak(transcript.displayText, language: language, voiceIdentifier: selectedVoice(for: language), rate: settings.speechRate)
    }

    private func selectedVoice(for language: DictationLanguage) -> String? {
        guard language != .automatic else { return nil }
        return settings.speechVoiceIdentifier.flatMap { selected in
            SpeechOutput.availableVoices(for: language).contains(where: { $0.id == selected }) ? selected : nil
        }
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
        showPersistentNotice("Reprocessing saved audio.")
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
        showPersistentNotice("Cancelling history audio task.")
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
                        let cmd = run.commands[run.nextCommandIndex]
                        var planned: ControlPlanStep? = nil
                        do {
                            planned = try ControlPlanner.plan(
                                command: cmd,
                                snapshot: snapshot,
                                installedApplications: run.installedApplications
                            )
                        } catch {
                            if let jevKey = typeSafeKey() {
                                controlStatus = "Consulting Jev model..."
                                let candidates = JevControlBridge.makeCandidates(
                                    from: snapshot,
                                    installedApplications: run.installedApplications
                                )
                                let context = JevCommandContext(
                                    command: cmd,
                                    application: run.target.localizedName ?? snapshot.applicationName,
                                    window: snapshot.windowTitle,
                                    completedSteps: run.commands.prefix(run.nextCommandIndex).map { String($0) }
                                )
                                let decision = try await JevClient.decide(context: context, candidates: candidates, apiKey: jevKey)
                                planned = try JevControlBridge.planStep(
                                    from: decision,
                                    candidates: candidates,
                                    snapshot: snapshot,
                                    installedApplications: run.installedApplications
                                )
                            } else {
                                throw error
                            }
                        }
                        guard let stepCandidate = planned else {
                            throw SaysoError.invalidAction("Could not plan action for command.")
                        }
                        step = stepCandidate
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
                    updateControlTarget(after: entry, step: step, run: run)
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

    private func updateControlTarget(
        after entry: ControlAuditEntry,
        step: ControlPlanStep,
        run: ControlCommandRun
    ) {
        guard entry.effect == .observed,
              let bundleIdentifier = step.action.validatedNextTargetBundleIdentifier,
              let target = NSWorkspace.shared.frontmostApplication,
              target.bundleIdentifier == bundleIdentifier,
              !target.isTerminated else { return }
        run.target = target
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
            Button(model.transcriber.canStop ? "Stop dictation" : model.isContinuousDictationArmed ? "Stop continuous dictation" : model.transcriber.canStart ? "Start dictation" : "Finishing dictation") {
                model.startOrStopDictation()
            }
            .disabled(!model.transcriber.canStop && !model.transcriber.canStart && !model.isContinuousDictationArmed)
            if model.lastVoiceEditRewrite != nil {
                Button("Copy pending voice edit rewrite") { model.copyLastVoiceEditRewrite() }
            }
            Button("Show Sayso Notch") { model.showNotch() }
            Button("Transcription") { model.openTranscriptionSettings() }
            Button("Models & Downloads") { model.openModelsSettings() }
            Button("AI Cleanup") { model.openAICleanupSettings() }
            Button("Vocabulary Dictionary") { model.openVocabularySettings() }
            Button("Notch & HUD Display") { model.openNotchSettings() }
            Button("Keyboard Shortcuts") { model.openShortcutsSettings() }
            Button("Open Sayso") { model.showMainWindow() }
            Button("Open Settings") { model.openSettings() }
            Divider()
            Button("Quit Sayso", role: .destructive) { model.quit() }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct NotchWorkspace: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notch & Desktop HUD").font(.system(size: 28, weight: .bold))
                    Text("Configure the Sayso dynamic notch and floating desktop overlay.").foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HUD Overlay Display").font(.headline)
                            Text("Show or hide the live voice and control overlay.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { model.isNotchOverlayVisible },
                            set: { model.setNotchOverlayVisible($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Presentation Style").font(.subheadline.weight(.semibold))
                        Picker("Presentation", selection: Binding(
                            get: { model.settings.overlayPresentation },
                            set: { model.setOverlayPresentation($0) }
                        )) {
                            ForEach(OverlayPresentation.allCases) { presentation in
                                Text(presentation.displayName).tag(presentation)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(model.settings.overlayPresentation == .notch
                            ? "Notch: Docks seamlessly beside your MacBook camera cutout or top menu bar."
                            : "Floating: Floats as a movable glass HUD widget on your desktop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HUD Controls").font(.subheadline.weight(.semibold))
                        HStack(spacing: 12) {
                            Button(model.isNotchCollapsed ? "Expand HUD" : "Collapse HUD") {
                                model.toggleNotch()
                            }
                            Button("Show HUD") {
                                model.showNotch()
                            }
                            Button("Hide HUD") {
                                model.hideNotch()
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Toggle Shortcut").font(.subheadline.weight(.semibold))
                        SaysoShortcutRecorderRow(
                            action: .toggleNotch,
                            hotKey: Binding(
                                get: { model.toggleNotchHotKey },
                                set: { model.setToggleNotchHotKey($0) }
                            )
                        )
                    }
                }
                .padding(20)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
    }
}

private struct ShortcutsWorkspace: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard Shortcuts").font(.system(size: 28, weight: .bold))
                    Text("Configure trigger hotkeys for dictation, desktop control, and the notch HUD.").foregroundStyle(.secondary)
                }

                if !model.shortcutConflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(SaysoPalette.crimson)
                            Text("Shortcut Conflicts Detected").font(.headline).foregroundStyle(SaysoPalette.crimson)
                        }
                        ForEach(model.shortcutConflicts) { conflict in
                            Text(conflict.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(SaysoPalette.crimson.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Global Shortcuts").font(.headline)
                    Text("These hotkeys work anywhere in macOS, even when Sayso is running in the background.").font(.caption).foregroundStyle(.secondary)

                    Divider()

                    SaysoShortcutRecorderRow(
                        action: .dictation,
                        hotKey: Binding(
                            get: { model.dictationHotKey },
                            set: { model.setDictationHotKey($0) }
                        )
                    )

                    Divider()

                    SaysoShortcutRecorderRow(
                        action: .control,
                        hotKey: Binding(
                            get: { model.controlHotKey },
                            set: { model.setControlHotKey($0) }
                        )
                    )

                    Divider()

                    SaysoShortcutRecorderRow(
                        action: .toggleNotch,
                        hotKey: Binding(
                            get: { model.toggleNotchHotKey },
                            set: { model.setToggleNotchHotKey($0) }
                        )
                    )
                }
                .padding(20)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Activation & Timing").font(.headline)

                    Picker("Dictation activation", selection: $model.settings.hotKeyActivation) {
                        ForEach(DictationHotKeyActivation.allCases) { activation in
                            Text(activation.displayName).tag(activation)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.settings.hotKeyActivation.usesPressAndHold {
                        HStack {
                            Text("Hold threshold: \(model.settings.hotKeyHoldThresholdSeconds, format: .number.precision(.fractionLength(2)))s")
                            Slider(value: $model.settings.hotKeyHoldThresholdSeconds, in: 0.2 ... 1, step: 0.05)
                        }
                    }

                    Text("Double-tap the Dictation shortcut with text selected in any app to rewrite it with voice edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Spacer()
                        Button("Reset Shortcuts to Defaults") {
                            model.resetShortcutsToDefaults()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
    }
}

private struct SettingsHome: View {
    @ObservedObject var model: SaysoAppModel

    private var selectedTabTitle: String {
        switch model.selectedTab {
        case 0: return "Speak"
        case 1: return "Control"
        case 2: return "History"
        case 3: return "Transcription"
        case 4: return "Models & Downloads"
        case 5: return "AI Cleanup"
        case 6: return "Vocabulary Dictionary"
        case 7: return "Notch & HUD"
        case 8: return "Shortcuts"
        case 9: return "Voice output"
        default: return "Settings"
        }
    }

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
                    Section("Activity") {
                        Label("Speak", systemImage: "waveform").tag(0)
                        Label("Control", systemImage: "cursorarrow.click").tag(1)
                        Label("History", systemImage: "clock.arrow.circlepath").tag(2)
                    }
                    Section("Pipeline") {
                        Label("Transcription", systemImage: "mic.badge.waveform").tag(3)
                        Label("Models & Downloads", systemImage: "square.stack.3d.up.fill").tag(4)
                        Label("AI Cleanup", systemImage: "sparkles").tag(5)
                        Label("Vocabulary Dictionary", systemImage: "character.book.closed").tag(6)
                    }
                    Section("Desktop & Triggers") {
                        Label("Notch & HUD", systemImage: "menubar.rectangle").tag(7)
                        Label("Shortcuts", systemImage: "keyboard").tag(8)
                    }
                    Section("System") {
                        Label("Voice output", systemImage: "speaker.wave.2").tag(9)
                        Label("Settings", systemImage: "gearshape").tag(10)
                    }
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
            Group {
                switch model.selectedTab {
                case 0: DictationWorkspace(model: model)
                case 1: ControlWorkspace(model: model)
                case 2: HistoryWorkspace(model: model)
                case 3: TranscriptionWorkspace(model: model)
                case 4: ModelsWorkspace(model: model)
                case 5: AICleanupWorkspace(model: model)
                case 6: VocabularyWorkspace(model: model)
                case 7: NotchWorkspace(model: model)
                case 8: ShortcutsWorkspace(model: model)
                case 9: VoiceOutputWorkspace(model: model, speech: model.speech)
                default: SaysoSettingsView(model: model)
                }
            }
            .navigationTitle(selectedTabTitle)
            .toolbarBackground(SaysoPalette.brandNavyDark, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .tint(SaysoPalette.cobalt)
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(SaysoPalette.brandNavyDark, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
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
    @State private var selectedLanguage: DictationLanguage
    @State private var historyEntries: [Transcript] = []
    @State private var historyID: Transcript.ID?
    @State private var voices: [SpeechOutput.Voice] = []

    init(model: SaysoAppModel, speech: SpeechOutput) {
        self.model = model
        self.speech = speech
        _selectedLanguage = State(initialValue: model.settings.speechLanguage)
    }

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
                    selectedLanguage = playbackLanguage(for: transcript)
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
                    if let entry = historyEntries.first(where: { $0.id == id }) {
                        text = entry.displayText
                        selectedLanguage = playbackLanguage(for: entry)
                    }
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
                    Picker("Spoken language", selection: Binding(
                        get: { selectedLanguage },
                        set: { language in
                            selectedLanguage = language
                            model.settings.speechLanguage = language
                            model.save()
                        }
                    )) {
                        ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Voice", selection: $model.settings.speechVoiceIdentifier) {
                        Text("System default").tag(nil as String?)
                        if let selected = model.settings.speechVoiceIdentifier,
                           !voices.contains(where: { $0.id == selected }) {
                            let label = SpeechOutput.availableVoices(for: .automatic).contains(where: { $0.id == selected })
                                ? "Voice set for another language"
                                : "Saved voice unavailable"
                            Text(label).tag(selected as String?)
                        }
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
                    model.speak(text, language: selectedLanguage)
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
        .onChange(of: selectedLanguage) { _, _ in
            refreshVoices()
        }
        .onChange(of: model.settings.speechVoiceIdentifier) { _, _ in model.save() }
        .onChange(of: model.settings.speechRate) { _, _ in model.save() }
    }

    private func refreshVoices() {
        voices = SpeechOutput.availableVoices(for: selectedLanguage)
    }

    private func playbackLanguage(for transcript: Transcript) -> DictationLanguage {
        let language = transcript.spokenLanguage(outputLanguage: model.settings.outputLanguage)
        return language == .automatic ? model.settings.speechLanguage : language
    }

    private func refreshHistory() async {
        historyEntries = Array((await model.history.all()).prefix(20))
    }
}

private struct ControlWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @State private var command = ""
    @State private var jevKeyInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

                // TypeSafe / Jev API Key Card
                SaysoSectionHeader(text: "AI Control Model (Jev-Use)")
                SaysoApiKeyCard(
                    providerName: "TypeSafe / Jev",
                    hasKey: model.hasTypeSafeKey,
                    apiKeyURL: URL(string: "https://typesafe.ai"),
                    apiKeyInput: $jevKeyInput,
                    onSave: {
                        model.saveTypeSafeKey(jevKeyInput)
                        jevKeyInput = ""
                    },
                    onClear: {
                        model.removeTypeSafeKey()
                    }
                )

                SaysoSectionHeader(text: "Command & Actions")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 14) {
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

                        HStack(spacing: 10) {
                            TextField("e.g. click Settings, scroll down, open Safari...", text: $command)
                                .onSubmit { model.runControl(command) }
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.8), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                                )

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
                    }
                }

                SaysoSectionHeader(text: "Control Status")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Status", systemImage: "scope")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(statusTint)
                            Spacer()
                            Text(model.currentSnapshot == nil ? "Awaiting capture" : "Grounded")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(statusTint, in: Capsule())
                        }

                        Text(model.controlStatus)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)

                        if let snapshot = model.currentSnapshot {
                            Divider().background(SaysoPalette.brandNavyContainer)
                            Label("\(snapshot.applicationName) : \(snapshot.windowTitle)", systemImage: "macwindow")
                                .font(.subheadline)
                                .foregroundStyle(SaysoPalette.muted)
                            Label(
                                snapshot.isProtected ? "Protected target, blocked" : "Target eligible for action",
                                systemImage: snapshot.isProtected ? "xmark.shield" : "checkmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(snapshot.isProtected ? SaysoPalette.crimson : SaysoPalette.amber)

                            if !snapshot.elements.isEmpty {
                                Text("Visible controls: \(snapshot.elements.prefix(5).map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(SaysoPalette.muted)
                            }
                        }
                    }
                }

                if let pending = model.pendingControlStep {
                    SaysoCard {
                        HStack(spacing: 12) {
                            Label("Review required: \(pending.reason)", systemImage: "exclamationmark.shield")
                                .foregroundStyle(SaysoPalette.amber)
                            Spacer()
                            Button("Discard") { model.discardPendingControl() }
                            Button("Approve") { model.approvePendingControl() }
                                .buttonStyle(.borderedProminent)
                                .tint(SaysoPalette.crimson)
                        }
                    }
                }

                if !model.controlEntries.isEmpty {
                    SaysoSectionHeader(text: "Recent Actions")
                    SaysoCard {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.controlEntries.prefix(4)) { entry in
                                HStack {
                                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(SaysoPalette.muted)
                                    Text(entry.result)
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                }
                                if entry != model.controlEntries.prefix(4).last {
                                    Divider().background(SaysoPalette.brandNavyContainer)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                    Text("Secure fields, stale targets, and low-confidence plans are rejected safely.")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                }
            }
            .padding(20)
        }
        .background(SaysoPalette.brandNavyDark)
        .navigationTitle("Desktop Control")
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
        TranscriptionWorkspace(model: model)
    }
}

// MARK: - Sayso Android Brand Card Components

private struct SaysoSectionHeader: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(SaysoPalette.brandAmber)
                .frame(width: 5, height: 5)
                .shadow(color: SaysoPalette.brandAmber.opacity(0.8), radius: 3, x: 0, y: 0)
            Text(text.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(SaysoPalette.brandAmber)
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
        .padding(.horizontal, 4)
    }
}

private struct SaysoCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            SaysoPalette.cardSurfaceGradient,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(SaysoPalette.cardBevelBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.55), radius: 7, x: 3, y: 5)
        .shadow(color: Color(red: 0x33 / 255.0, green: 0x46 / 255.0, blue: 0x68 / 255.0).opacity(0.12), radius: 4, x: -2, y: -2)
    }
}

private struct SaysoSwitchCard<DetailContent: View>: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    let detailContent: DetailContent?

    init(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        @ViewBuilder detailContent: () -> DetailContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.detailContent = detailContent()
    }

    var body: some View {
        SaysoCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if let detailContent, isOn {
                detailContent
                    .padding(.top, 4)
            }
        }
    }
}

private extension SaysoSwitchCard where DetailContent == EmptyView {
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, isOn: isOn, detailContent: { EmptyView() })
    }
}

private struct SaysoTransliterationCard: View {
    @Binding var transliterateToLatin: Bool
    var languageCode: String?
    var onToggle: ((Bool) -> Void)? = nil

    private var langTitle: String {
        switch languageCode {
        case "hi": "Hinglish"
        case "ml": "Manglish"
        case "ta": "Tanglish"
        case "bn": "Banglish"
        case "te": "Tenglish"
        case "kn": "Kanglish"
        case "mr": "Marathlish"
        case "pa": "Punglish"
        case "ur": "Roman Urdu"
        default: "Tanglish / Hinglish / Manglish"
        }
    }

    private var exampleLatin: String {
        switch languageCode {
        case "hi": "Namaste, aap kaise hain?"
        case "ml": "Namaskaram, sugam aano?"
        case "ta": "Vanakkam, eppadi irukkeenga?"
        case "bn": "Nomoshkar, kemon achhen?"
        case "te": "Namaskaram, ela unnaru?"
        case "kn": "Namaskara, hegiddira?"
        case "mr": "Namaskar, kase aahat?"
        case "pa": "Sat Sri Akal, ki haal hai?"
        case "ur": "Adaab, aap kaise hain?"
        default: "Vanakkam, eppadi irukkeenga?"
        }
    }

    private var exampleNative: String {
        switch languageCode {
        case "hi": "नमस्ते, आप कैसे हैं?"
        case "ml": "നമസ്കാരം, സുഖമാണോ?"
        case "ta": "வணக்கம், எப்படி இருக்கீங்க?"
        case "bn": "নমস্কার, কেমন আছেন?"
        case "te": "నమస్కారం, ఎలా ఉన్నారు?"
        case "kn": "ನಮಸ್ಕಾರ, ಹೇಗಿದ್ದೀರಾ?"
        case "mr": "नमस्कार, कसे आहात?"
        case "pa": "ਸਤਿ ਸ੍ਰੀ ਅਕਾਲ, ਕੀ ਹਾਲ ਹੈ?"
        case "ur": "آداب، آپ کیسے ہیں؟"
        default: "வணக்கம், எப்படி இருக்கீங்க?"
        }
    }

    var body: some View {
        SaysoCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Indic Transliteration (\(langTitle))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Choose how spoken words are formatted when you dictate in Indian languages")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { transliterateToLatin },
                    set: { newValue in
                        transliterateToLatin = newValue
                        onToggle?(newValue)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 10) {
                // Option 1: Tanglish / Hinglish / Manglish (English letters)
                Button {
                    transliterateToLatin = true
                    onToggle?(true)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: transliterateToLatin ? "largecircle.fill.circle" : "circle")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(transliterateToLatin ? SaysoPalette.brandAmber : SaysoPalette.muted)
                            Text(langTitle)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        Text("English letters")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Example:")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Text("\"\(exampleLatin)\"")
                                .font(.caption2.italic().weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    LinearGradient(colors: [Color.black.opacity(0.8), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                    lineWidth: 1
                                )
                        )
                    }
                    .padding(10)
                    .background(
                        transliterateToLatin
                            ? LinearGradient(colors: [Color(red: 0x22 / 255.0, green: 0x33 / 255.0, blue: 0x54 / 255.0), Color(red: 0x18 / 255.0, green: 0x25 / 255.0, blue: 0x3D / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color(red: 0x14 / 255.0, green: 0x1E / 255.0, blue: 0x32 / 255.0), Color(red: 0x0E / 255.0, green: 0x15 / 255.0, blue: 0x24 / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                transliterateToLatin ? SaysoPalette.activeGlowGradient : LinearGradient(colors: [SaysoPalette.brandNavyContainer, SaysoPalette.brandNavyDark], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: transliterateToLatin ? 1.5 : 1
                            )
                    )
                    .shadow(
                        color: transliterateToLatin ? SaysoPalette.brandAmber.opacity(0.3) : Color.black.opacity(0.4),
                        radius: transliterateToLatin ? 6 : 3,
                        x: 0,
                        y: 2
                    )
                }
                .buttonStyle(.plain)

                // Option 2: Native Script
                Button {
                    transliterateToLatin = false
                    onToggle?(false)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: !transliterateToLatin ? "largecircle.fill.circle" : "circle")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(!transliterateToLatin ? SaysoPalette.brandAmber : SaysoPalette.muted)
                            Text("Native Script")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        Text("Traditional script")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Example:")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Text("\"\(exampleNative)\"")
                                .font(.caption2.italic().weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    LinearGradient(colors: [Color.black.opacity(0.8), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                    lineWidth: 1
                                )
                        )
                    }
                    .padding(10)
                    .background(
                        !transliterateToLatin
                            ? LinearGradient(colors: [Color(red: 0x22 / 255.0, green: 0x33 / 255.0, blue: 0x54 / 255.0), Color(red: 0x18 / 255.0, green: 0x25 / 255.0, blue: 0x3D / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color(red: 0x14 / 255.0, green: 0x1E / 255.0, blue: 0x32 / 255.0), Color(red: 0x0E / 255.0, green: 0x15 / 255.0, blue: 0x24 / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                !transliterateToLatin ? SaysoPalette.activeGlowGradient : LinearGradient(colors: [SaysoPalette.brandNavyContainer, SaysoPalette.brandNavyDark], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: !transliterateToLatin ? 1.5 : 1
                            )
                    )
                    .shadow(
                        color: !transliterateToLatin ? SaysoPalette.brandAmber.opacity(0.3) : Color.black.opacity(0.4),
                        radius: !transliterateToLatin ? 6 : 3,
                        x: 0,
                        y: 2
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }
}

private struct SaysoModeOptionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? .white : SaysoPalette.muted)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(SaysoPalette.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .background(
                isSelected
                    ? LinearGradient(colors: [Color(red: 0x22 / 255.0, green: 0x33 / 255.0, blue: 0x54 / 255.0), Color(red: 0x18 / 255.0, green: 0x25 / 255.0, blue: 0x3D / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color(red: 0x14 / 255.0, green: 0x1E / 255.0, blue: 0x32 / 255.0), Color(red: 0x0E / 255.0, green: 0x15 / 255.0, blue: 0x24 / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? SaysoPalette.activeGlowGradient : LinearGradient(colors: [SaysoPalette.brandNavyContainer, SaysoPalette.brandNavyDark], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSelected ? SaysoPalette.brandAmber.opacity(0.3) : Color.black.opacity(0.4),
                radius: isSelected ? 8 : 4,
                x: 0,
                y: isSelected ? 2 : 3
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SaysoSliderCard: View {
    let title: String
    let subtitle: String?
    let valueDisplay: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        SaysoCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                    }
                }
                Spacer()
                Text(valueDisplay)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SaysoPalette.brandAmber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        SaysoPalette.brandNavyWell,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(colors: [SaysoPalette.brandAmber.opacity(0.5), Color.clear], startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: SaysoPalette.brandAmber.opacity(0.2), radius: 4, x: 0, y: 1)
            }
            Slider(value: $value, in: range, step: step)
                .tint(SaysoPalette.brandAmber)
        }
    }
}

private struct SaysoApiKeyCard: View {
    let providerName: String
    let hasKey: Bool
    let apiKeyURL: URL?
    @Binding var apiKeyInput: String
    let onSave: () -> Void
    let onClear: () -> Void

    @State private var isVisible = false

    var body: some View {
        SaysoCard {
            HStack {
                Text("API Key (\(providerName))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if hasKey {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.emerald)
                        Text("Key saved in Keychain")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.emerald)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.amber)
                        Text("No key stored")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.amber)
                    }
                }
            }

            HStack(spacing: 8) {
                Group {
                    if isVisible {
                        TextField("Enter API key...", text: $apiKeyInput)
                    } else {
                        SecureField("Enter API key...", text: $apiKeyInput)
                    }
                }
                .textFieldStyle(.plain)
                .padding(8)
                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.8), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )

                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.subheadline)
                        .foregroundStyle(SaysoPalette.muted)
                        .frame(width: 32, height: 32)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button("Save Key") {
                    onSave()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(SaysoPalette.amberButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: SaysoPalette.brandAmber.opacity(0.4), radius: 4, x: 0, y: 2)
                .foregroundStyle(SaysoPalette.brandNavyDark)
                .font(.caption.weight(.bold))
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasKey {
                    Button("Clear Key") {
                        onClear()
                    }
                    .buttonStyle(.bordered)
                    .tint(SaysoPalette.crimson)
                    .font(.caption)
                }

                Spacer()

                if let apiKeyURL {
                    Link("Get API Key ↗", destination: apiKeyURL)
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.brandAmber)
                }
            }
        }
    }
}

private struct TranscriptionWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @State private var hintsText = ""
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Section: Speech Recognition
                SaysoSectionHeader(text: "Speech Recognition")

                HStack(spacing: 10) {
                    SaysoModeOptionCard(
                        title: "On-Device",
                        subtitle: "Private & Local",
                        systemImage: "arrow.down.circle.fill",
                        isSelected: model.settings.route == .local
                    ) {
                        model.settings.route = .local
                        model.save()
                    }

                    SaysoModeOptionCard(
                        title: "Cloud LLM / ASR",
                        subtitle: "BYOK Providers",
                        systemImage: "cloud.fill",
                        isSelected: model.settings.route == .byok
                    ) {
                        model.settings.route = .byok
                        model.save()
                    }

                    SaysoModeOptionCard(
                        title: "Apple Speech",
                        subtitle: "macOS Built-in",
                        systemImage: "waveform",
                        isSelected: model.settings.route == .appleSpeech
                    ) {
                        model.settings.route = .appleSpeech
                        model.save()
                    }
                }

                if model.settings.route == .local {
                    SaysoCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Engine: Local On-Device Neural ASR")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                Text("Audio never leaves this Mac. Offline dictation with zero latency jitter.")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                            Spacer()
                            Button("Manage on-device models") {
                                model.openModelsSettings()
                            }
                            .buttonStyle(.bordered)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption.weight(.semibold))
                        }
                    }
                } else if model.settings.route == .byok {
                    let providers = CloudProviderCatalog.transcriptionProviders
                    let currentProvider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId) ?? CloudProviderCatalog.saysoCloud

                    SaysoCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Cloud Provider")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)

                            Picker("Provider", selection: Binding(
                                get: { model.settings.selectedCloudProviderId },
                                set: { newId in
                                    model.settings.selectedCloudProviderId = newId
                                    if let p = CloudProviderCatalog.provider(for: newId) {
                                        model.settings.byokBaseURL = p.defaultBaseURL
                                        if let firstModel = p.transcriptionModels.first {
                                            model.settings.selectedCloudModelId = firstModel.id
                                            model.settings.byokTranscriptionModel = firstModel.id
                                        }
                                    }
                                    model.save()
                                }
                            )) {
                                ForEach(providers) { p in
                                    Text(p.displayName).tag(p.id)
                                }
                            }
                            .labelsHidden()

                            if !currentProvider.transcriptionModels.isEmpty {
                                Text("Transcription Model")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)

                                Picker("Model", selection: Binding(
                                    get: { model.settings.selectedCloudModelId },
                                    set: {
                                        model.settings.selectedCloudModelId = $0
                                        model.settings.byokTranscriptionModel = $0
                                        model.save()
                                    }
                                )) {
                                    ForEach(currentProvider.transcriptionModels) { opt in
                                        HStack {
                                            Text(opt.displayName)
                                            Spacer()
                                            Text(opt.latencyTier.badgeText)
                                        }
                                        .tag(opt.id)
                                    }
                                }
                                .labelsHidden()
                            }

                            if currentProvider.id == "custom" {
                                TextField("Base URL", text: $model.settings.byokBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Model name", text: $model.settings.byokTranscriptionModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    SaysoApiKeyCard(
                        providerName: currentProvider.displayName,
                        hasKey: model.hasKey(for: currentProvider),
                        apiKeyURL: currentProvider.apiKeyURL,
                        apiKeyInput: $apiKey,
                        onSave: {
                            if model.saveProviderKey(apiKey, for: currentProvider) {
                                apiKey = ""
                            }
                        },
                        onClear: {
                            model.removeProviderKey(for: currentProvider)
                        }
                    )
                } else {
                    SaysoCard {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(SaysoPalette.cobalt)
                            Text("Uses Apple Speech recognition framework built into macOS.")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                        }
                    }
                }

                // Section: Spoken Language & Transliteration
                SaysoSectionHeader(text: model.settings.language.isIndic ? "Spoken Language & Transliteration" : "Spoken Language")

                SaysoCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Spoken Language")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Primary language for speech recognition and acoustic model routing")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                        }
                        Spacer()
                        Picker("Spoken language", selection: $model.settings.language) {
                            ForEach(DictationLanguage.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                SaysoSwitchCard(
                    title: "Automatic language routing (Early LID)",
                    subtitle: "Uses Whisper neural detector to route Tamil, Hindi, or Malayalam to AI4Bharat and English to Parakeet",
                    isOn: $model.settings.autoLanguageRouting
                )

                if model.settings.language.isIndic {
                    SaysoTransliterationCard(
                        transliterateToLatin: $model.settings.transliterateIndicToLatin,
                        languageCode: model.settings.language.languageCode,
                        onToggle: { _ in model.save() }
                    )
                }

                // Section: Acoustic Vocabulary Hints
                SaysoSectionHeader(text: "Acoustic Vocabulary Hints")

                SaysoCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Acoustic Hints")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Names, technical terms, and specialized jargon to bias recognition towards, separated by commas.")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)

                        TextField("Custom words / proper nouns (comma-separated)", text: $hintsText)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.8), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                            )
                            .onAppear {
                                hintsText = model.settings.hints.joined(separator: ", ")
                            }
                            .onChange(of: hintsText) { _, newText in
                                model.settings.hints = newText
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                                model.save()
                            }
                    }
                }

                // Section: Recording & Hardware
                SaysoSectionHeader(text: "Recording & Hardware")

                SaysoCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Microphone Input")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        HStack {
                            Picker("Microphone", selection: $model.settings.preferredAudioInputUID) {
                                Text("macOS default").tag(nil as AudioInputDeviceUID?)
                                ForEach(model.audioInputDevices) { device in
                                    Text(device.displayName).tag(Optional(device.uid))
                                }
                            }
                            .labelsHidden()

                            Spacer()

                            Button("Refresh") {
                                model.refreshAudioInputDevices()
                            }
                            .buttonStyle(.bordered)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                        }
                    }
                }

                SaysoSwitchCard(
                    title: "Audio ducking",
                    subtitle: "Lowers background music and media playback volume while dictation is recording",
                    isOn: $model.settings.audioDuckingEnabled
                )

                SaysoSwitchCard(
                    title: "Sound cues",
                    subtitle: "Play audio start and stop tones when dictation begins and completes",
                    isOn: $model.settings.soundCues
                )

                SaysoSwitchCard(
                    title: "Hands-free silence auto-stop",
                    subtitle: "Automatically end recording when you pause speaking",
                    isOn: Binding(
                        get: { model.settings.silenceTimeoutSeconds > 0 },
                        set: { if !$0 { model.settings.silenceTimeoutSeconds = 1.5 } }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Silence timeout")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                            Spacer()
                            Text("\(model.settings.silenceTimeoutSeconds, format: .number.precision(.fractionLength(1)))s")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                        }
                        Slider(value: $model.settings.silenceTimeoutSeconds, in: 0.5 ... 5.0, step: 0.1)
                            .tint(SaysoPalette.brandAmber)
                    }
                }

                SaysoSliderCard(
                    title: "Maximum recording duration",
                    subtitle: "Safety limit on continuous speech capture",
                    valueDisplay: "\(Int(model.settings.maxRecordingSeconds))s",
                    value: $model.settings.maxRecordingSeconds,
                    range: 15 ... 300,
                    step: 15
                )

                // Section: Language Coverage
                SaysoSectionHeader(text: "Language Coverage")

                SaysoCard {
                    VStack(spacing: 8) {
                        ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) { language in
                            HStack {
                                Text(language.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                Spacer()
                                let isInstalling = (language == .english && model.localEnglishModel.state == .installing) ||
                                    (language.isIndic && model.localEnglishModel.multilingualState == .installing) ||
                                    (language == .punjabi && model.localPunjabiModel.state == .installing)

                                if isInstalling {
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.small)
                                        Text("Downloading...")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(SaysoPalette.brandAmber)
                                    }
                                } else {
                                    let nativeReady = model.nativeModelReady(for: language)
                                    let downloadAvailable = model.nativeModelDownloadAvailable(for: language)
                                    let appleAvailable = SpeechCapabilities.supports(language)
                                    if downloadAvailable && !nativeReady {
                                        Button {
                                            if language == .punjabi {
                                                Task { await model.localPunjabiModel.install() }
                                            } else if language == .english {
                                                Task { await model.localEnglishModel.install() }
                                            } else {
                                                Task { await model.localEnglishModel.install(language: language) }
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.down.circle.fill")
                                                Text("Download model")
                                            }
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(SaysoPalette.brandCobalt)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Label(
                                            nativeReady ? "On-device ready" : appleAvailable ? "Apple Speech available" : "Cloud only",
                                            systemImage: nativeReady || appleAvailable ? "checkmark.circle.fill" : "circle"
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(nativeReady || appleAvailable ? SaysoPalette.emerald : SaysoPalette.muted)
                                    }
                                }
                            }
                            if language != DictationLanguage.allCases.filter({ $0 != .automatic }).last {
                                Divider().background(SaysoPalette.brandNavyContainer)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(SaysoPalette.brandNavyDark)
        .navigationTitle("Transcription")
        .onChange(of: model.settings) { _, _ in model.save() }
    }
}


private typealias PreProcessingWorkspace = TranscriptionWorkspace

private struct LocalSlmRowCard: View {
    let slm: LocalSlmManifest
    let isSelected: Bool
    let status: LocalSlmState
    let progress: Double?
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Button(action: onSelect) {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slm.displayName)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                Text("\(slm.parameterCount) params · \(slm.sizeDisplay) · GGUF")
                                    .font(.caption2)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if status.isInstalled {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.emerald)
                            Text("Ready")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.emerald)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SaysoPalette.emerald.opacity(0.15), in: Capsule())
                    } else if case .installing = status {
                        let pct = Int((progress ?? 0.05) * 100)
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading \(pct)%")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SaysoPalette.brandAmber.opacity(0.15), in: Capsule())
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.crimson)
                            Text("Not downloaded")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SaysoPalette.crimson)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SaysoPalette.crimson.opacity(0.12), in: Capsule())
                    }
                }

                Text(slm.summary)
                    .font(.caption)
                    .foregroundStyle(SaysoPalette.muted)

                if status.isInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(SaysoPalette.emerald)
                        Text("Model installed · Ready for offline rewrite")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.emerald)
                        Spacer()
                    }
                    .padding(10)
                    .background(SaysoPalette.emerald.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(SaysoPalette.emerald.opacity(0.3), lineWidth: 1)
                    )
                } else if case .installing = status {
                    let currentProgress = max(0.05, progress ?? 0.05)
                    let pct = Int(currentProgress * 100)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading \(slm.displayName)... \(pct)%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Spacer()
                            Text(slm.sizeDisplay)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(SaysoPalette.muted)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(SaysoPalette.brandNavyWell)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.7), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                                    )

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        LinearGradient(
                                            colors: [SaysoPalette.brandAmber, SaysoPalette.amberDark],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(12, geo.size.width * CGFloat(currentProgress)))
                                    .shadow(color: SaysoPalette.brandAmber.opacity(0.6), radius: 5, x: 0, y: 0)
                            }
                        }
                        .frame(height: 8)
                    }
                    .padding(12)
                    .background(SaysoPalette.brandNavyWell.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1)
                    )
                } else {
                    Button(action: onDownload) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption.weight(.bold))
                            Text("Download \(slm.displayName) (\(slm.sizeDisplay))")
                                .font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(SaysoPalette.blueButtonGradient, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .shadow(color: SaysoPalette.brandCobalt.opacity(0.4), radius: 6, x: 0, y: 3)
                        .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
        }
    }
}

private struct AICleanupWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SaysoSwitchCard(
                    title: "Enable text cleanup",
                    subtitle: "Polishes grammar, punctuation, and formatting using rules, local SLM, or cloud models",
                    isOn: $model.settings.cleanupEnabled
                )

                SaysoSectionHeader(text: "Cleanup Pipeline Mode")
                modePickerRow
                modeContentSection

                SaysoSectionHeader(text: "Smart Capabilities")
                smartCapabilitiesSection

                SaysoSectionHeader(text: "Prompt Presets")
                promptPresetsSection

                SaysoSectionHeader(text: "Output Language & Translation")
                outputLanguageSection
            }
            .padding(20)
        }
        .background(SaysoPalette.brandNavyDark)
        .navigationTitle("AI Cleanup")
        .onChange(of: model.settings) { _, _ in model.save() }
    }

    @ViewBuilder
    private var modePickerRow: some View {
        HStack(spacing: 10) {
            SaysoModeOptionCard(
                title: "No LLM",
                subtitle: "Fast rules",
                systemImage: "bolt.fill",
                isSelected: model.settings.cleanupMode == .rules
            ) {
                model.settings.cleanupMode = .rules
                model.save()
            }

            SaysoModeOptionCard(
                title: "Local LLM",
                subtitle: "Offline",
                systemImage: "cpu",
                isSelected: model.settings.cleanupMode == .localSLM
            ) {
                model.settings.cleanupMode = .localSLM
                model.save()
            }

            SaysoModeOptionCard(
                title: "Cloud LLM",
                subtitle: "BYOK",
                systemImage: "cloud.fill",
                isSelected: model.settings.cleanupMode == .cloudLLM
            ) {
                model.settings.cleanupMode = .cloudLLM
                model.save()
            }
        }
    }

    @ViewBuilder
    private var modeContentSection: some View {
        if model.settings.cleanupMode == .rules {
            SaysoCard {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SaysoPalette.brandAmber)
                    Text("Fast deterministic rules polish grammar, punctuation, and capitalization without calling an LLM.")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                }
            }
        } else if model.settings.cleanupMode == .localSLM {
            VStack(spacing: 10) {
                ForEach(LocalSlmCatalog.all) { slm in
                    LocalSlmRowCard(
                        slm: slm,
                        isSelected: model.settings.selectedLocalSlmModelId == slm.id,
                        status: model.checkSlmStatus(slm),
                        progress: model.slmDownloadProgress[slm.id],
                        onSelect: {
                            model.settings.selectedLocalSlmModelId = slm.id
                            model.save()
                        },
                        onDownload: {
                            Task { await model.installSlm(slm) }
                        }
                    )
                }
            }
        } else if model.settings.cleanupMode == .cloudLLM {
            cloudLlmContent
        }
    }

    @ViewBuilder
    private var cloudLlmContent: some View {
        let providers = CloudProviderCatalog.cleanupProviders
        let currentProvider = CloudProviderCatalog.provider(for: model.settings.selectedCloudCleanupProviderId) ?? CloudProviderCatalog.groq

        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cloud Provider")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Picker("Provider", selection: Binding(
                    get: { model.settings.selectedCloudCleanupProviderId },
                    set: { newId in
                        model.settings.selectedCloudCleanupProviderId = newId
                        if let p = CloudProviderCatalog.provider(for: newId) {
                            model.settings.byokBaseURL = p.defaultBaseURL
                            if let firstModel = p.cleanupModels.first {
                                model.settings.selectedCloudCleanupModelId = firstModel.id
                                model.settings.byokCleanupModel = firstModel.id
                            }
                        }
                        model.save()
                    }
                )) {
                    ForEach(providers) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }
                .labelsHidden()

                if !currentProvider.cleanupModels.isEmpty {
                    Text("Cleanup Model")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Picker("Model", selection: Binding(
                        get: { model.settings.selectedCloudCleanupModelId },
                        set: {
                            model.settings.selectedCloudCleanupModelId = $0
                            model.settings.byokCleanupModel = $0
                            model.save()
                        }
                    )) {
                        ForEach(currentProvider.cleanupModels) { opt in
                            HStack {
                                Text(opt.displayName)
                                Spacer()
                                Text(opt.latencyTier.badgeText)
                            }
                            .tag(opt.id)
                        }
                    }
                    .labelsHidden()
                }

                if currentProvider.id == "custom" {
                    TextField("Base URL", text: $model.settings.byokBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model name", text: $model.settings.byokCleanupModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }

        SaysoApiKeyCard(
            providerName: currentProvider.displayName,
            hasKey: model.hasKey(for: currentProvider),
            apiKeyURL: currentProvider.apiKeyURL,
            apiKeyInput: $apiKey,
            onSave: {
                if model.saveProviderKey(apiKey, for: currentProvider) {
                    apiKey = ""
                }
            },
            onClear: {
                model.removeProviderKey(for: currentProvider)
            }
        )
    }

    @ViewBuilder
    private var smartCapabilitiesSection: some View {
        SaysoSwitchCard(
            title: "Adapt formatting to active application",
            subtitle: "Detects frontmost application to dynamically apply app-specific formatting rules",
            isOn: $model.settings.appContextAwarenessEnabled
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppContextCategory.allCases.filter { $0 != .general }) { category in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: category))
                            .foregroundStyle(SaysoPalette.brandAmber)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(category.directive)
                                .font(.caption2)
                                .foregroundStyle(SaysoPalette.muted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if model.settings.language.isIndic {
            let indicTitle = model.settings.language == .tamil ? "Tanglish" : model.settings.language == .hindi ? "Hinglish" : model.settings.language == .malayalam ? "Manglish" : "Latin Script"
            SaysoSwitchCard(
                title: "Transliterate to \(indicTitle)",
                subtitle: "Phonetically convert \(model.settings.language.displayName) speech into English letters (\(indicTitle)).",
                isOn: $model.settings.transliterateIndicToLatin
            )
        }
    }

    @ViewBuilder
    private var promptPresetsSection: some View {
        SaysoCard {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CleanupPreset.allCases) { preset in
                    Button {
                        model.settings.cleanupPreset = preset
                        model.save()
                    } label: {
                        HStack {
                            Image(systemName: model.settings.cleanupPreset == preset ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.settings.cleanupPreset == preset ? SaysoPalette.brandAmber : SaysoPalette.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text(presetDescription(for: preset))
                                    .font(.caption2)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)

                    if preset != CleanupPreset.allCases.last {
                        Divider().background(SaysoPalette.brandNavyContainer)
                    }
                }

                if model.settings.cleanupPreset == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom system prompt:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        TextEditor(text: Binding(
                            get: { model.settings.customCleanupPrompt ?? CleanupPolicy.basePrompt },
                            set: { model.settings.customCleanupPrompt = $0; model.save() }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(SaysoPalette.brandNavyDark, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SaysoPalette.brandOutline, lineWidth: 1))

                        HStack {
                            Spacer()
                            Button("Reset to Base Prompt") {
                                model.settings.customCleanupPrompt = CleanupPolicy.basePrompt
                                model.save()
                            }
                            .buttonStyle(.bordered)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var outputLanguageSection: some View {
        SaysoSwitchCard(
            title: "Translate final cleaned text",
            subtitle: "Translate polished dictation into the target language below",
            isOn: $model.settings.translationEnabled
        )

        SaysoCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Output Language")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Picker("Output language", selection: $model.settings.outputLanguage) {
                    ForEach(DictationLanguage.allCases.filter { $0 != .automatic }) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    private func presetDescription(for preset: CleanupPreset) -> String {
        switch preset {
        case .standard: "Standard: Polishes grammar, punctuation, capitalization, and cleans speech stutters."
        case .developer: "Developer: Preserves CLI commands, flags, camelCase, snake_case, paths, and technical symbols."
        case .minimal: "Minimal: Fixes punctuation and capitalization only, leaving all spoken words unchanged."
        case .casual: "Casual: Keeps a natural, conversational, concise tone suited for quick messages."
        case .custom: "Custom: User-defined system instructions passed to the cleanup engine."
        }
    }

    private func icon(for category: AppContextCategory) -> String {
        switch category {
        case .chat: "bubble.left.and.bubble.right"
        case .email: "envelope"
        case .codeTerminal: "terminal"
        case .docsNotes: "doc.text"
        case .general: "app"
        }
    }
}

private typealias PostProcessingWorkspace = AICleanupWorkspace

private struct VocabularyWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @State private var searchQuery = ""
    @State private var selectedCategory: PronunciationCategory? = nil
    @State private var editingEntry: SaysoPronunciationEntry? = nil
    @State private var isAddingNew = false
    @State private var showResetConfirm = false

    var filteredEntries: [SaysoPronunciationEntry] {
        model.settings.pronunciations.filter { entry in
            let matchesCategory = selectedCategory == nil || entry.category == selectedCategory
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch = query.isEmpty ||
                entry.word.lowercased().contains(query) ||
                entry.pronunciation.lowercased().contains(query) ||
                (entry.replacement?.lowercased().contains(query) == true) ||
                entry.category.displayName.lowercased().contains(query)
            return matchesCategory && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header & Search Toolbar
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Vocabulary & Pronunciation").font(.system(size: 26, weight: .bold))
                            Text("\(model.settings.pronunciations.count)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(SaysoPalette.cobalt.opacity(0.15), in: Capsule())
                                .foregroundStyle(SaysoPalette.cobalt)
                        }
                        Text("Phonetic speech triggers and technical dictionary replacements.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            isAddingNew = true
                        } label: {
                            Label("Add Word", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SaysoPalette.cobalt)

                        Button {
                            importVocabulary()
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            exportVocabulary()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showResetConfirm = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("Reset to standard developer defaults")
                    }
                }

                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search word, pronunciation, or replacement...", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 8))

                // Category filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryChip(title: "All", count: model.settings.pronunciations.count, isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(PronunciationCategory.allCases) { category in
                            let count = model.settings.pronunciations.filter { $0.category == category }.count
                            CategoryChip(title: category.displayName, count: count, isSelected: selectedCategory == category) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(20)
            .background(SaysoPalette.surfaceRaised)

            Divider()

            // Entry List
            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No vocabulary entries found")
                        .font(.headline)
                    Text(searchQuery.isEmpty ? "Tap 'Add Word' to add custom pronunciations." : "No entries match your search query.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(entry.word)
                                        .font(.headline.weight(.semibold))
                                    Text(entry.category.displayName)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(categoryColor(entry.category).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(categoryColor(entry.category))
                                }
                                HStack(spacing: 12) {
                                    HStack(spacing: 4) {
                                        Text("Spoken:").font(.caption).foregroundStyle(.secondary)
                                        Text(entry.pronunciation.isEmpty ? entry.word : entry.pronunciation)
                                            .font(.caption.weight(.medium))
                                    }
                                    if let replacement = entry.replacement, !replacement.isEmpty, replacement != entry.word {
                                        HStack(spacing: 4) {
                                            Text("Produces:").font(.caption).foregroundStyle(.secondary)
                                            Text(replacement)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(SaysoPalette.cobalt)
                                        }
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                editingEntry = entry
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            Button {
                                model.removePronunciation(entry.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(SaysoPalette.crimson)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editingEntry) { (entry: SaysoPronunciationEntry) in
            AddEditPronunciationSheet(entry: entry) { updated in
                model.updatePronunciation(updated)
                editingEntry = nil
            } onCancel: {
                editingEntry = nil
            }
        }
        .sheet(isPresented: $isAddingNew) {
            AddEditPronunciationSheet(entry: nil as SaysoPronunciationEntry?) { newEntry in
                model.addPronunciation(newEntry)
                isAddingNew = false
            } onCancel: {
                isAddingNew = false
            }
        }
        .confirmationDialog("Reset Vocabulary to Defaults?", isPresented: $showResetConfirm) {
            Button("Reset to Defaults", role: .destructive) {
                model.resetPronunciationsToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace current entries with standard developer and system vocabulary.")
        }
    }

    private func categoryColor(_ category: PronunciationCategory) -> Color {
        switch category {
        case .technical: SaysoPalette.cobalt
        case .names: Color.teal
        case .acronyms: SaysoPalette.amber
        case .symbols: Color.purple
        case .brands: Color.orange
        case .medical: Color.red
        case .custom: Color.gray
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.title = "Export Vocabulary Dictionary"
        panel.nameFieldStringValue = "sayso-vocabulary.json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            if let json = model.exportPronunciationsJson() {
                try? json.write(to: url, atomically: true, encoding: .utf8)
                model.notice = "Vocabulary dictionary exported successfully."
            }
        }
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.title = "Import Vocabulary Dictionary"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? String(contentsOf: url, encoding: .utf8) {
                do {
                    try model.importPronunciations(json: data)
                    model.notice = "Vocabulary dictionary imported successfully."
                } catch {
                    model.notice = "Failed to import vocabulary: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct CategoryChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(isSelected ? .bold : .medium))
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? SaysoPalette.cobalt : SaysoPalette.surface, in: Capsule())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .overlay(Capsule().stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct AddEditPronunciationSheet: View {
    @State var word: String
    @State var pronunciation: String
    @State var replacement: String
    @State var category: PronunciationCategory
    @State var isRegex: Bool
    @State var caseSensitive: Bool
    let existingID: String?
    let onSave: (SaysoPronunciationEntry) -> Void
    let onCancel: () -> Void

    init(entry: SaysoPronunciationEntry?, onSave: @escaping (SaysoPronunciationEntry) -> Void, onCancel: @escaping () -> Void) {
        _word = State(initialValue: entry?.word ?? "")
        _pronunciation = State(initialValue: entry?.pronunciation ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _category = State(initialValue: entry?.category ?? .technical)
        _isRegex = State(initialValue: entry?.isRegex ?? false)
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? false)
        existingID = entry?.id
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(existingID == nil ? "Add Vocabulary Entry" : "Edit Vocabulary Entry")
                .font(.headline.weight(.bold))

            Form {
                TextField("Canonical word / target output", text: $word)
                TextField("Spoken phonetic trigger (e.g. 'eye OS')", text: $pronunciation)
                TextField("Optional replacement text (leave blank to use word)", text: $replacement)

                Picker("Category", selection: $category) {
                    ForEach(PronunciationCategory.allCases) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }

                Toggle("Match as regular expression", isOn: $isRegex)
                Toggle("Case sensitive matching", isOn: $caseSensitive)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") {
                    let entry = SaysoPronunciationEntry(
                        id: existingID ?? UUID().uuidString,
                        word: word.trimmingCharacters(in: .whitespacesAndNewlines),
                        pronunciation: pronunciation.trimmingCharacters(in: .whitespacesAndNewlines),
                        replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : replacement.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: category,
                        isRegex: isRegex,
                        caseSensitive: caseSensitive
                    )
                    onSave(entry)
                }
                .buttonStyle(.borderedProminent)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 420, minHeight: 340)
        .padding(16)
    }
}

private struct ModelsWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject private var localEnglishModel: FluidAudioLocalModelManager
    @ObservedObject private var localPunjabiModel: SherpaPunjabiModelManager
    @State private var selectedCategory = 0
    @State private var providerApiKey = ""

    init(model: SaysoAppModel) {
        self.model = model
        _localEnglishModel = ObservedObject(wrappedValue: model.localEnglishModel)
        _localPunjabiModel = ObservedObject(wrappedValue: model.localPunjabiModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $selectedCategory) {
                Text("On-Device Speech").tag(0)
                Text("On-Device SLMs").tag(1)
                Text("Cloud Providers & BYOK").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Form {
                switch selectedCategory {
                case 0:
                    onDeviceSpeechSection
                case 1:
                    onDeviceSlmSection
                default:
                    cloudProvidersSection
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Models & Downloads")
        .onChange(of: model.settings) { _, _ in model.save() }
    }

    @ViewBuilder
    private var onDeviceSpeechSection: some View {
        Section("Speech Route") {
            Picker("Active speech route", selection: $model.settings.route) {
                ForEach(ProviderRoute.dictationRoutes) { route in
                    Text(route.displayName).tag(route)
                }
            }
            Text("Select 'On-device' for 100% private transcription without internet.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Native Streaming Models (Apple Silicon CoreML)") {
            // English FluidAudio
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(FluidAudioLocalModelManager.displayName).fontWeight(.semibold)
                            Text("⚡ Instant").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.yellow.opacity(0.2), in: Capsule())
                            if localEnglishModel.state.isInstalled && model.settings.route == .local && model.settings.language == .english {
                                Text("Active Engine").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(SaysoPalette.cobalt.opacity(0.2), in: Capsule()).foregroundStyle(SaysoPalette.cobalt)
                            }
                        }
                        Text("On-device English streaming. Apple silicon only. 430 MB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(localModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localEnglishModel.state.isInstalled ? SaysoPalette.cobalt : SaysoPalette.muted)
                }

                if case .installing = localEnglishModel.state {
                    let pct = Int(localEnglishModel.downloadProgress * 100)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Downloading English model... \(pct)%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                        }
                        ProgressView(value: localEnglishModel.downloadProgress)
                            .tint(SaysoPalette.brandAmber)
                    }
                }

                HStack {
                    if localEnglishModel.state.isInstalled {
                        Button("Delete model", role: .destructive) { localEnglishModel.delete() }
                            .font(.caption)
                    } else if case .installing = localEnglishModel.state {
                        Button("Downloading (\(Int(localEnglishModel.downloadProgress * 100))%)...") {}
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                            .disabled(true)
                    } else {
                        Button("Download English model") { Task { await localEnglishModel.install() } }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.cobalt)
                            .font(.caption)
                    }
                    Spacer()
                }
            }

            // Indian Language FluidAudio
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(FluidAudioLocalModelManager.multilingualDisplayName).fontWeight(.semibold)
                            Text("⚡ Fast").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.teal.opacity(0.2), in: Capsule())
                        }
                        Text("Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Telugu and Urdu. 1.5 GB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(multilingualModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localEnglishModel.multilingualState.isInstalled ? SaysoPalette.cobalt : SaysoPalette.muted)
                }

                if case .installing = localEnglishModel.multilingualState {
                    let pct = Int(localEnglishModel.multilingualDownloadProgress * 100)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Downloading Indian language model... \(pct)%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                        }
                        ProgressView(value: localEnglishModel.multilingualDownloadProgress)
                            .tint(SaysoPalette.brandAmber)
                    }
                }

                HStack {
                    if localEnglishModel.multilingualState.isInstalled {
                        Button("Delete model", role: .destructive) { localEnglishModel.deleteMultilingual() }
                            .font(.caption)
                    } else if case .installing = localEnglishModel.multilingualState {
                        Button("Downloading (\(Int(localEnglishModel.multilingualDownloadProgress * 100))%)...") {}
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                            .disabled(true)
                    } else {
                        Button("Download Indian language model") { Task { await localEnglishModel.install(language: .hindi) } }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.cobalt)
                            .font(.caption)
                    }
                    Spacer()
                }
            }
        }

        Section("Offline Indic & Sherpa-ONNX Catalog") {
            // Punjabi model
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(SherpaPunjabiModelManager.displayName).fontWeight(.semibold)
                            Text("⚡ Fast").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.teal.opacity(0.2), in: Capsule())
                            Text("★ Best for Punjabi").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2), in: Capsule())
                        }
                        Text("Offline Punjabi final transcription. Apache-2.0. 198 MB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(punjabiModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localPunjabiModel.state.isInstalled ? SaysoPalette.cobalt : SaysoPalette.muted)
                }

                if case .installing = localPunjabiModel.state {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Downloading Punjabi model...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                }

                HStack {
                    if localPunjabiModel.state.isInstalled {
                        Button("Delete model", role: .destructive) { localPunjabiModel.delete() }
                            .font(.caption)
                    } else if case .installing = localPunjabiModel.state {
                        Button("Downloading...") {}
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                            .disabled(true)
                    } else {
                        Button("Download Punjabi model") { Task { await localPunjabiModel.install() } }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.cobalt)
                            .font(.caption)
                    }
                    Spacer()
                }
            }

            // Sherpa-ONNX models
            ForEach(LocalModelCatalog.all) { manifest in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(manifest.displayName).fontWeight(.semibold)
                                if manifest.isRecommended {
                                    Text("Recommended").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(SaysoPalette.cobalt.opacity(0.15), in: Capsule()).foregroundStyle(SaysoPalette.cobalt)
                                }
                                if manifest.id == model.settings.selectedLocalAsrModelId && model.settings.route == .local {
                                    Text("Selected").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.2), in: Capsule()).foregroundStyle(Color.green)
                                }
                            }
                            Text("\(manifest.summary) Size: \(manifest.expectedSizeBytes / 1_000_000) MB. License: \(manifest.license.displayName).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    HStack {
                        if manifest.id != model.settings.selectedLocalAsrModelId {
                            Button("Use for Dictation") {
                                model.settings.selectedLocalAsrModelId = manifest.id
                                model.settings.route = .local
                                model.save()
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder
    private var onDeviceSlmSection: some View {
        Section("On-Device Small Language Models") {
            Text("Small Language Models (SLMs) run locally on CPU and Apple Neural Engine. They polish transcripts, format lists, and fix grammar without sending text to any cloud server.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("SLM Catalog (Qwen & SmolLM)") {
            ForEach(LocalSlmCatalog.all) { slm in
                let status = model.checkSlmStatus(slm)
                let isSelected = model.settings.selectedLocalSlmModelId == slm.id

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(slm.displayName).fontWeight(.semibold)
                                Text(slm.latencyTier.badgeText)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(slm.latencyTier == .instant ? Color.yellow.opacity(0.2) : Color.teal.opacity(0.2), in: Capsule())

                                if slm.isRecommended {
                                    Text("Recommended")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(SaysoPalette.cobalt.opacity(0.15), in: Capsule())
                                        .foregroundStyle(SaysoPalette.cobalt)
                                }

                                if isSelected {
                                    Text("Active SLM")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.2), in: Capsule())
                                        .foregroundStyle(Color.green)
                                }
                            }

                            Text("\(slm.summary) Parameters: \(slm.parameterCount). Quantized: \(slm.sizeDisplay).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()

                        if status.isInstalled {
                            Text("Ready")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.cobalt)
                        } else if case .installing = status {
                            let pct = Int((model.slmDownloadProgress[slm.id] ?? 0.05) * 100)
                            Text("Downloading \(pct)%")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                        } else {
                            Text("Not downloaded")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.muted)
                        }
                    }

                    if case .installing = status {
                        let p = model.slmDownloadProgress[slm.id] ?? 0.05
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Downloading \(slm.displayName)... \(Int(p * 100))%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SaysoPalette.brandAmber)
                            }
                            ProgressView(value: p)
                                .tint(SaysoPalette.brandAmber)
                        }
                    }

                    HStack {
                        if status.isInstalled {
                            if !isSelected {
                                Button("Select as Active") {
                                    model.settings.selectedLocalSlmModelId = slm.id
                                    model.settings.cleanupMode = .localSLM
                                    model.save()
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }

                            Button("Delete", role: .destructive) {
                                model.deleteSlm(slm)
                            }
                            .font(.caption)
                        } else if case .installing = status {
                            let pct = Int((model.slmDownloadProgress[slm.id] ?? 0.05) * 100)
                            Button("Downloading (\(pct)%)...") {}
                                .buttonStyle(.borderedProminent)
                                .tint(SaysoPalette.brandAmber)
                                .font(.caption)
                                .disabled(true)
                        } else {
                            Button("Download \(slm.displayName)") {
                                Task { await model.installSlm(slm) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.cobalt)
                            .font(.caption)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var cloudProvidersSection: some View {
        let providers = CloudProviderCatalog.all
        let selectedProvider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId) ?? CloudProviderCatalog.saysoCloud

        Section("Select Cloud Provider") {
            Picker("Provider", selection: Binding(
                get: { model.settings.selectedCloudProviderId },
                set: { newId in
                    model.settings.selectedCloudProviderId = newId
                    if let p = CloudProviderCatalog.provider(for: newId) {
                        model.settings.byokBaseURL = p.defaultBaseURL
                        if let firstStt = p.transcriptionModels.first {
                            model.settings.selectedCloudModelId = firstStt.id
                            model.settings.byokTranscriptionModel = firstStt.id
                        }
                        if let firstLlm = p.cleanupModels.first {
                            model.settings.selectedCloudCleanupModelId = firstLlm.id
                            model.settings.byokCleanupModel = firstLlm.id
                        }
                    }
                    model.save()
                }
            )) {
                ForEach(providers) { p in
                    Text(p.displayName).tag(p.id)
                }
            }

            HStack {
                Text("Default endpoint: \(selectedProvider.defaultBaseURL)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = selectedProvider.apiKeyURL {
                    Link("Get API Key ↗", destination: url)
                        .font(.caption)
                }
            }
        }

        Section("Provider Configuration") {
            TextField("API Base URL", text: $model.settings.byokBaseURL)

            if selectedProvider.supportsTranscription {
                if !selectedProvider.transcriptionModels.isEmpty {
                    Picker("Transcription model (STT)", selection: Binding(
                        get: { model.settings.selectedCloudModelId },
                        set: {
                            model.settings.selectedCloudModelId = $0
                            model.settings.byokTranscriptionModel = $0
                            model.save()
                        }
                    )) {
                        ForEach(selectedProvider.transcriptionModels) { opt in
                            HStack {
                                Text(opt.displayName)
                                Spacer()
                                Text(opt.latencyTier.badgeText)
                            }
                            .tag(opt.id)
                        }
                    }
                } else {
                    TextField("Transcription model (STT)", text: $model.settings.byokTranscriptionModel)
                }
            }

            if selectedProvider.supportsCleanup {
                if !selectedProvider.cleanupModels.isEmpty {
                    Picker("Cleanup model (LLM)", selection: Binding(
                        get: { model.settings.selectedCloudCleanupModelId },
                        set: {
                            model.settings.selectedCloudCleanupModelId = $0
                            model.settings.byokCleanupModel = $0
                            model.save()
                        }
                    )) {
                        ForEach(selectedProvider.cleanupModels) { opt in
                            HStack {
                                Text(opt.displayName)
                                Spacer()
                                Text(opt.latencyTier.badgeText)
                            }
                            .tag(opt.id)
                        }
                    }
                } else {
                    TextField("Cleanup model (LLM)", text: $model.settings.byokCleanupModel)
                }
            }

            TextField("Translation model", text: $model.settings.byokTranslationModel)
            TextField("Voice edit rewrite model", text: $model.settings.byokRewriteModel)
        }

        Section("API Key & Keychain Security") {
            let hasKey = model.hasKey(for: selectedProvider)
            HStack {
                Label(hasKey ? "API Key stored securely in Keychain" : "No API key stored for \(selectedProvider.displayName)",
                      systemImage: hasKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasKey ? SaysoPalette.cobalt : SaysoPalette.crimson)
                Spacer()
                if hasKey && selectedProvider.id != "ollama" {
                    Button("Remove key", role: .destructive) {
                        model.removeProviderKey(for: selectedProvider)
                    }
                    .font(.caption)
                }
            }

            if selectedProvider.id != "ollama" {
                SecureField("Enter API key", text: $providerApiKey)
                Button("Store in Keychain") {
                    if model.saveProviderKey(providerApiKey, for: selectedProvider) {
                        providerApiKey = ""
                    }
                }
                .disabled(providerApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("Ollama runs locally on http://localhost:11434 and does not require an API key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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

private struct CleanupDirectivesEditor: View {
    let title: String
    @Binding var directives: [String]
    @State private var text: String = ""

    var body: some View {
        TextField(title, text: $text)
            .onAppear {
                text = directives.joined(separator: ", ")
            }
            .onChange(of: text) { _, newValue in
                let parsed = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parsed != directives {
                    directives = parsed
                }
            }
            .onChange(of: directives) { _, newDirectives in
                let parsed = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parsed != newDirectives {
                    text = newDirectives.joined(separator: ", ")
                }
            }
    }
}

private struct SaysoSettingItemCard<Content: View>: View {
    let title: String
    let description: String
    let example: String?
    let content: Content

    init(
        title: String,
        description: String,
        example: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.example = example
        self.content = content()
    }

    var body: some View {
        SaysoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer(minLength: 16)
                    content
                }
                if let example {
                    HStack(spacing: 6) {
                        Text("Example:")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                        Text(example)
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.7), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
                }
            }
        }
    }
}

private struct SaysoSettingsView: View {
    @ObservedObject var model: SaysoAppModel
    @State private var spoken = ""
    @State private var replacement = ""
    @State private var jevKeyInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Section 1: Notch & Desktop HUD
                SaysoSectionHeader(text: "Notch & Desktop HUD")
                SaysoSettingItemCard(
                    title: "Show Notch HUD overlay",
                    description: "Displays the floating or notch-docked status overlay on your desktop.",
                    example: "Quick status pill stays visible near the top of your screen."
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.isNotchOverlayVisible },
                        set: { model.setNotchOverlayVisible($0) }
                    ))
                    .labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Presentation style",
                    description: "Dock alongside MacBook camera cutout or float freely anywhere on the screen.",
                    example: "Notch docks at top edge; Floating stays where you drag it."
                ) {
                    Picker("Presentation style", selection: Binding(
                        get: { model.settings.overlayPresentation },
                        set: { model.setOverlayPresentation($0) }
                    )) {
                        ForEach(OverlayPresentation.allCases) { presentation in
                            Text(presentation.displayName).tag(presentation)
                        }
                    }
                    .labelsHidden()
                }

                SaysoCard {
                    HStack(spacing: 12) {
                        Button(model.isNotchCollapsed ? "Expand HUD" : "Collapse HUD") {
                            model.toggleNotch()
                        }
                        .buttonStyle(.bordered)
                        .tint(SaysoPalette.cobalt)
                        Button("Show HUD") {
                            model.showNotch()
                        }
                        .buttonStyle(.bordered)
                        .tint(SaysoPalette.cobalt)
                        Button("Hide HUD") {
                            model.hideNotch()
                        }
                        .buttonStyle(.bordered)
                        .tint(SaysoPalette.crimson)
                    }
                    .font(.caption.weight(.semibold))
                }

                // Section 2: Keyboard Shortcuts & Triggers
                SaysoSectionHeader(text: "Keyboard Shortcuts & Triggers")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SaysoShortcutRecorderRow(
                            action: .dictation,
                            hotKey: Binding(
                                get: { model.dictationHotKey },
                                set: { model.setDictationHotKey($0) }
                            )
                        )
                        Divider().background(SaysoPalette.brandNavyContainer)
                        SaysoShortcutRecorderRow(
                            action: .control,
                            hotKey: Binding(
                                get: { model.controlHotKey },
                                set: { model.setControlHotKey($0) }
                            )
                        )
                        Divider().background(SaysoPalette.brandNavyContainer)
                        SaysoShortcutRecorderRow(
                            action: .toggleNotch,
                            hotKey: Binding(
                                get: { model.toggleNotchHotKey },
                                set: { model.setToggleNotchHotKey($0) }
                            )
                        )

                        if !model.shortcutConflicts.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.shortcutConflicts) { conflict in
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(SaysoPalette.amber)
                                        Text(conflict.message)
                                            .font(.caption)
                                            .foregroundStyle(SaysoPalette.amber)
                                    }
                                }
                            }
                            .padding(8)
                            .background(SaysoPalette.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                SaysoSettingItemCard(
                    title: "Dictation activation",
                    description: "Toggle dictation with a single tap or hold down the key while speaking.",
                    example: "Tap to talk: tap once to record, tap again to paste."
                ) {
                    Picker("Dictation activation", selection: $model.settings.hotKeyActivation) {
                        ForEach(DictationHotKeyActivation.allCases) { activation in
                            Text(activation.displayName).tag(activation)
                        }
                    }
                    .labelsHidden()
                }

                if model.settings.hotKeyActivation.usesPressAndHold {
                    SaysoSliderCard(
                        title: "Hold threshold",
                        subtitle: "Minimum duration to hold before dictation begins",
                        valueDisplay: String(format: "%.2fs", model.settings.hotKeyHoldThresholdSeconds),
                        value: $model.settings.hotKeyHoldThresholdSeconds,
                        range: 0.2 ... 1,
                        step: 0.05
                    )
                }

                HStack {
                    Spacer()
                    Button("Reset All Shortcuts to Defaults") {
                        model.resetShortcutsToDefaults()
                    }
                    .buttonStyle(.bordered)
                    .tint(SaysoPalette.brandAmber)
                    .font(.caption)
                }

                // Section 3: Spoken Language & Delivery
                SaysoSectionHeader(text: "Language & Delivery")

                SaysoSettingItemCard(
                    title: "Spoken language",
                    description: "Primary language for speech recognition and acoustic model routing.",
                    example: "Choose English, Hindi, Tamil, Spanish, etc."
                ) {
                    Picker("Spoken language", selection: $model.settings.language) {
                        ForEach(DictationLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Speech route",
                    description: "Recognition engine to use for transcribing audio.",
                    example: "Local (On-Device Neural), Apple Speech, or BYOK Cloud."
                ) {
                    Picker("Speech route", selection: $model.settings.route) {
                        ForEach(ProviderRoute.dictationRoutes) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Translate final text",
                    description: "Automatically translates your transcribed words into another language.",
                    example: "Speak in French or Hindi -> text is delivered in English."
                ) {
                    Toggle("", isOn: $model.settings.translationEnabled).labelsHidden()
                }

                if model.settings.language.isIndic {
                    SaysoTransliterationCard(
                        transliterateToLatin: $model.settings.transliterateIndicToLatin,
                        languageCode: model.settings.language.languageCode,
                        onToggle: { _ in model.save() }
                    )
                }

                SaysoSettingItemCard(
                    title: "Insert final text (Automatic paste)",
                    description: "Pastes finalized text directly into your frontmost active application.",
                    example: "Cursor in Slack, Notes, or Terminal gets the transcribed text instantly."
                ) {
                    Toggle("", isOn: $model.settings.autoInsert).labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Insert partial text live in TextEdit and Notes",
                    description: "Streams words into document fields as you speak in supported apps.",
                    example: "Words appear live in Notes before you stop talking."
                ) {
                    Toggle("", isOn: $model.settings.livePartialInsertion)
                        .labelsHidden()
                        .disabled(!model.settings.autoInsert)
                }

                SaysoSettingItemCard(
                    title: "Restore clipboard after paste fallback",
                    description: "Restores your prior clipboard contents after Sayso pastes your dictation.",
                    example: "Previously copied URLs or snippets remain on your clipboard."
                ) {
                    Toggle("", isOn: $model.settings.restoreClipboardAfterPaste)
                        .labelsHidden()
                        .disabled(!model.settings.autoInsert)
                }

                // Section 4: Hands-Free & Silence Detection
                SaysoSectionHeader(text: "Hands-Free & Silence Detection")
                SaysoSettingItemCard(
                    title: "Hands-free dictation",
                    description: "Automatically finalizes and pastes text when speech pauses without pressing keys.",
                    example: "Natural pause ends recording automatically."
                ) {
                    Toggle("", isOn: $model.settings.handsFree).labelsHidden()
                }

                if model.settings.handsFree {
                    SaysoSliderCard(
                        title: "Silence timeout",
                        subtitle: "Seconds of silence before Sayso finalizes your phrase",
                        valueDisplay: String(format: "%.1fs", model.settings.handsFreeSilenceSeconds),
                        value: $model.settings.handsFreeSilenceSeconds,
                        range: 0.5 ... 5,
                        step: 0.1
                    )

                    SaysoSettingItemCard(
                        title: "Continue after each delivered phrase",
                        description: "Keeps listening for new phrases after delivering each sentence.",
                        example: "Dictate multiple sentences continuously without re-triggering."
                    ) {
                        Toggle("", isOn: $model.settings.handsFreeContinuous)
                            .labelsHidden()
                            .disabled(!model.settings.autoInsert)
                    }
                }

                // Section 5: Audio Hardware & Sound Cues
                SaysoSectionHeader(text: "Audio Hardware & Cues")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Microphone Input")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        HStack {
                            Picker("Microphone", selection: $model.settings.preferredAudioInputUID) {
                                Text("macOS default").tag(nil as AudioInputDeviceUID?)
                                ForEach(model.audioInputDevices) { device in
                                    Text(device.displayName).tag(Optional(device.uid))
                                }
                            }
                            .labelsHidden()
                            Spacer()
                            Button("Refresh") { model.refreshAudioInputDevices() }
                                .buttonStyle(.bordered)
                                .tint(SaysoPalette.brandAmber)
                                .font(.caption)
                        }
                    }
                }

                SaysoSettingItemCard(
                    title: "Audio ducking",
                    description: "Lowers background media playback volume while dictation is recording.",
                    example: "Spotify or Apple Music volume dips while you speak."
                ) {
                    Toggle("", isOn: $model.settings.audioDuckingEnabled).labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Sound cues",
                    description: "Plays subtle audio start and stop tones when recording begins and completes.",
                    example: "Chime confirms microphone is hot and audio is delivered."
                ) {
                    Toggle("", isOn: $model.settings.soundCues).labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Save dictation audio in History",
                    description: "Keeps recorded audio locally on this Mac for playback in the History tab.",
                    example: "Replay past dictations anytime from the History tab."
                ) {
                    Toggle("", isOn: $model.settings.saveSessionAudio).labelsHidden()
                }

                // Section 6: Dictation Profile & Text Polishing
                SaysoSectionHeader(text: "Dictation Profile & Text Polishing")
                SaysoSettingItemCard(
                    title: "Normalize whitespace",
                    description: "Collapses duplicate spaces, extra tabs, and redundant blank lines into clean spacing.",
                    example: "\"Hello    world\" -> \"Hello world\""
                ) {
                    Toggle("", isOn: $model.settings.dictationProfile.normalizesWhitespace).labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Capitalize sentences",
                    description: "Automatically capitalizes the first word of each sentence after periods, question marks, and line breaks.",
                    example: "\"how are you. i am good\" -> \"How are you. I am good.\""
                ) {
                    Toggle("", isOn: $model.settings.dictationProfile.capitalizesSentences).labelsHidden()
                }

                // Section 7: App Profile Overrides
                SaysoSectionHeader(text: "App Profile Overrides")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App-specific dictation profiles override global defaults when the matching app is frontmost.")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                        ForEach($model.settings.dictationProfileOverrides) { $override in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("App bundle identifier", text: $override.bundleIdentifier)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Remove", role: .destructive) {
                                        model.settings.dictationProfileOverrides.removeAll { $0.id == override.id }
                                        model.save()
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(SaysoPalette.crimson)
                                }
                                TextField("App profile name", text: $override.profile.name)
                                    .textFieldStyle(.roundedBorder)
                                Picker("Spoken language", selection: $override.profile.languageOverride) {
                                    Text("Use global setting").tag(DictationLanguage?.none)
                                    ForEach(DictationLanguage.allCases) { language in
                                        Text(language.displayName).tag(Optional(language))
                                    }
                                }
                                Picker("Speech route", selection: $override.profile.routeOverride) {
                                    Text("Use global setting").tag(ProviderRoute?.none)
                                    ForEach(ProviderRoute.dictationRoutes) { route in
                                        Text(route.displayName).tag(Optional(route))
                                    }
                                }
                                Toggle("Normalize whitespace for this app", isOn: $override.profile.normalizesWhitespace)
                                Toggle("Capitalize sentences for this app", isOn: $override.profile.capitalizesSentences)
                            }
                            .padding(10)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Button("Add active app profile") { model.addDictationProfileOverrideForLastExternalApp() }
                            .buttonStyle(.bordered)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                    }
                }

                // Section 8: Smart Corrections & Learned Words
                SaysoSectionHeader(text: "Smart Corrections & Learned Words")
                SaysoSettingItemCard(
                    title: "Learn from edits after dictation",
                    description: "Watches the text box after paste. If you manually fix a misheard word, Sayso learns the correction.",
                    example: "If you correct \"teh\" to \"the\", Sayso learns to apply it automatically."
                ) {
                    Toggle("", isOn: $model.settings.autoCorrectionsEnabled).labelsHidden()
                }

                if model.settings.autoCorrectionsEnabled {
                    SaysoCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Stepper(
                                "Promote after \(model.settings.autoCorrectionsPromotionThreshold) edits",
                                value: $model.settings.autoCorrectionsPromotionThreshold,
                                in: 2 ... 10
                            )
                            .font(.subheadline)
                            .foregroundStyle(.white)

                            if model.corrections.isMonitoring {
                                HStack(spacing: 6) {
                                    Image(systemName: "eye.fill")
                                        .foregroundStyle(SaysoPalette.brandAmber)
                                    Text("Watching the last inserted text for edits")
                                        .font(.caption)
                                        .foregroundStyle(SaysoPalette.muted)
                                }
                            }

                            HStack {
                                TextField("Heard", text: $spoken)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Write", text: $replacement)
                                    .textFieldStyle(.roundedBorder)
                                Button("Add") {
                                    model.addLexiconCorrection(spoken, replacement: replacement)
                                    spoken = ""; replacement = ""
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(SaysoPalette.cobalt)
                            }

                            ForEach(model.corrections.rules) { rule in
                                HStack {
                                    Text(rule.aliases.joined(separator: ", ")).foregroundStyle(SaysoPalette.muted)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(SaysoPalette.brandAmber)
                                    Text(rule.canonical).foregroundStyle(.white).fontWeight(.medium)
                                    Spacer()
                                    Button("Remove") { model.removeLexiconCorrection(rule) }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(SaysoPalette.crimson)
                                }
                            }

                            if !model.corrections.candidates.isEmpty {
                                ForEach(model.corrections.candidates) { candidate in
                                    HStack {
                                        Label("\(candidate.original) -> \(candidate.corrected) (\(candidate.seenCount)x)", systemImage: "wand.and.stars")
                                            .font(.caption)
                                            .foregroundStyle(SaysoPalette.brandAmber)
                                        Spacer()
                                        Button("Dismiss") { model.dismissCorrection(candidate) }
                                            .buttonStyle(.bordered)
                                            .font(.caption2)
                                        Button("Promote") { model.promoteCorrection(candidate) }
                                            .buttonStyle(.borderedProminent)
                                            .tint(SaysoPalette.emerald)
                                            .font(.caption2)
                                    }
                                }
                            }
                        }
                    }
                }

                // Section 9: Privacy & Permissions
                SaysoSectionHeader(text: "Privacy & Permissions")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(PermissionKind.allCases) { permission in
                            HStack {
                                Text(permission.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(label(for: model.permissions.states[permission] ?? .undetermined))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(model.permissions.states[permission] == .granted ? SaysoPalette.emerald : SaysoPalette.amber)
                                Button("Request") {
                                    Task { await model.permissions.request(permission) }
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                            if permission != PermissionKind.allCases.last {
                                Divider().background(SaysoPalette.brandNavyContainer)
                            }
                        }
                    }
                }

                SaysoSettingItemCard(
                    title: "Desktop control & automation",
                    description: "Enables hands-free desktop command execution and local automation server.",
                    example: "Say \"open Safari\" or \"click Submit\"."
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.settings.desktopControlEnabled },
                        set: { model.setAutomation($0) }
                    )).labelsHidden()
                }

                if model.settings.desktopControlEnabled {
                    SaysoApiKeyCard(
                        providerName: "TypeSafe / Jev Control",
                        hasKey: model.hasTypeSafeKey,
                        apiKeyURL: URL(string: "https://typesafe.ai"),
                        apiKeyInput: $jevKeyInput,
                        onSave: {
                            model.saveTypeSafeKey(jevKeyInput)
                            jevKeyInput = ""
                        },
                        onClear: {
                            model.removeTypeSafeKey()
                        }
                    )
                }

                SaysoSettingItemCard(
                    title: "Cloud transcription consent",
                    description: "Consent to send audio data to configured BYOK provider for speech recognition.",
                    example: "Required only when using OpenAI, Groq, or Anthropic routes."
                ) {
                    Toggle("", isOn: $model.settings.byokConsentGranted).labelsHidden()
                }

                CloudProviderSettings(model: model)
            }
            .padding(20)
        }
        .background(SaysoPalette.brandNavyDark)
        .navigationTitle("Settings")
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
                handsFreeCycle.disarm()
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
            guard transcriber.canStop || isStartingDictation || handsFreeCycle.isArmed else {
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
            guard !settings.route.transmitsData || settings.hasConsent(for: settings.route) else {
                return .failure(
                    id: request.id,
                    command: request.command,
                    error: .init(code: .transcriptionFailed, message: "Confirm the selected cloud data path before transcribing audio.")
                )
            }
            do {
                let fileURL = URL(fileURLWithPath: path)
                let transcript: Transcript
                if settings.route == .byok {
                    guard let configuration = cloudTranscriptionConfiguration(for: settings) else {
                        throw SaysoError.unavailable("Configure your cloud transcription model and API key before transcribing audio.")
                    }
                    let text = try await OpenAICompatibleAudioTranscriber(configuration: configuration)
                        .transcribe(fileURL: fileURL, language: settings.language)
                    transcript = .init(text: text, language: settings.language, route: .byok, isFinal: true)
                } else {
                    transcript = try await FileTranscriber.transcribe(
                        fileURL: fileURL, language: settings.language, route: settings.route
                    )
                }
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
            Text("Used only for selected cloud dictation, translation, cleanup, or voice edit. API key stays in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Base URL", text: $model.settings.byokBaseURL)
            TextField("Transcription model", text: $model.settings.byokTranscriptionModel)
            TextField("Translation model", text: $model.settings.byokTranslationModel)
            TextField("Voice edit model", text: $model.settings.byokRewriteModel)
            SecureField("API key", text: $apiKey)
            Button("Store key") { if model.saveBYOKKey(apiKey) { apiKey = "" } }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isBYOKBaseURLValid)
        }
    }
}

private struct OnboardingWizard: View {
    @ObservedObject var model: SaysoAppModel
    @State private var page = 0
    @State private var byokAPIKey = ""
    @Environment(\.dismiss) private var dismiss

    private enum WizardStep: Equatable {
        case language
        case engine
        case cloud
        case delivery
        case shortcut
        case permissions
    }

    private var steps: [String] {
        if model.settings.route == .byok {
            return ["Language", "Engine", "Cloud", "Delivery", "Shortcut", "Permissions"]
        } else {
            return ["Language", "Engine", "Delivery", "Shortcut", "Permissions"]
        }
    }

    private var currentStep: WizardStep {
        if model.settings.route == .byok {
            switch page {
            case 0: return .language
            case 1: return .engine
            case 2: return .cloud
            case 3: return .delivery
            case 4: return .shortcut
            default: return .permissions
            }
        } else {
            switch page {
            case 0: return .language
            case 1: return .engine
            case 2: return .delivery
            case 3: return .shortcut
            default: return .permissions
            }
        }
    }

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
                switch currentStep {
                case .language:
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
                case .engine:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose your engine.").font(.title2.bold())
                        Text("On-device keeps recognition local. Download the selected Sayso model before starting, choose Apple Speech to use Apple’s recognizer, or bring your own OpenAI-compatible endpoint.")
                            .foregroundStyle(.secondary)
                        Picker("Speech route", selection: $model.settings.route) {
                            ForEach(ProviderRoute.dictationRoutes) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if model.settings.route == .appleSpeech {
                            Toggle("I understand Apple Speech may transmit voice data", isOn: $model.settings.cloudConsentGranted)
                        }
                        if model.settings.route == .byok {
                            Text("Connect an OpenAI-compatible speech endpoint. You will configure your provider in the next step.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        if !engineReady && model.settings.route != .byok {
                            Label(engineReadinessMessage, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.crimson)
                        }
                    }
                case .cloud:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Configure your provider.").font(.title2.bold())
                        Text("Connect an OpenAI-compatible audio transcription endpoint. Your API key is stored securely in the macOS Keychain and never leaves your Mac except to authenticate requests.")
                            .foregroundStyle(.secondary)

                        Toggle("I understand BYOK transcription transmits voice data to my provider", isOn: $model.settings.byokConsentGranted)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Base URL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("Base URL", text: $model.settings.byokBaseURL)
                                .textFieldStyle(.roundedBorder)
                            if !model.isBYOKBaseURLValid {
                                Text("BYOK provider must use HTTPS, except localhost HTTP.")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.crimson)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transcription model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("Transcription model", text: $model.settings.byokTranscriptionModel)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("API key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack {
                                SecureField("API key", text: $byokAPIKey)
                                    .textFieldStyle(.roundedBorder)
                                Button(model.hasBYOKKey ? "Update key" : "Store key") {
                                    if model.saveBYOKKey(byokAPIKey) {
                                        byokAPIKey = ""
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(SaysoPalette.cobalt)
                                .disabled(byokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isBYOKBaseURLValid)
                            }
                            if model.hasBYOKKey {
                                Label("API key stored in Keychain.", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.cobalt)
                            } else {
                                Label("API key is required to use your provider.", systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.crimson)
                            }
                        }

                        if !engineReady {
                            Label(engineReadinessMessage, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.crimson)
                        }
                    }
                case .delivery:
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
                case .shortcut:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose your shortcut.").font(.title2.bold())
                        Text("Use it once to start or stop dictation. Double-tap with selected text to voice edit.")
                            .foregroundStyle(.secondary)
                        HotKeyRecorder("Start or stop dictation", hotKey: Binding(
                            get: { model.dictationHotKey },
                            set: { model.setDictationHotKey($0) }
                        ))
                        Picker("Activation", selection: $model.settings.hotKeyActivation) {
                            ForEach(DictationHotKeyActivation.allCases) { activation in
                                Text(activation.displayName).tag(activation)
                            }
                        }
                        if model.settings.hotKeyActivation.usesPressAndHold {
                            HStack {
                                Text("Hold for \(model.settings.hotKeyHoldThresholdSeconds, format: .number.precision(.fractionLength(2))) seconds")
                                Slider(value: $model.settings.hotKeyHoldThresholdSeconds, in: 0.2 ... 1, step: 0.05)
                            }
                        }
                        Text("Default: ⌥ Space. You can change this later in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .permissions:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Grant only what you use.").font(.title2.bold())
                        Text(requiresSpeechRecognition
                            ? "Microphone powers dictation. Speech Recognition is required for this setup. Accessibility enables safe text insertion. Input Monitoring is only for the global hotkey."
                            : "Microphone powers dictation. Accessibility enables safe text insertion. Input Monitoring is only for the global hotkey.")
                            .foregroundStyle(.secondary)
                        ForEach(displayedPermissions) { permission in
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
        .onChange(of: model.settings.route) { _, newRoute in
            page = min(page, steps.count - 1)
            model.clearOnboardingTestResult()
            guard newRoute == .local, model.settings.language == .automatic else { return }
            model.settings.language = .english
        }
        .onChange(of: model.settings) { _, _ in model.save() }
        .onAppear { model.refreshBYOKKeyStatus() }
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

    private var requiresSpeechRecognition: Bool {
        model.transcriber.requiresSpeechRecognition(
            language: model.settings.language,
            route: model.settings.route
        )
    }

    private var displayedPermissions: [PermissionKind] {
        if requiresSpeechRecognition {
            return PermissionKind.allCases
        }
        return PermissionKind.allCases.filter { $0 != .speechRecognition }
    }

    private var engineReady: Bool {
        OnboardingReadiness.engineIsReady(
            route: model.settings.route,
            language: model.settings.language,
            hasLocalModel: model.nativeModelReady(for: model.settings.language),
            routeConsentGranted: model.settings.hasConsent(for: model.settings.route),
            byokConfigured: model.isBYOKConfigured
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
            if !model.settings.byokConsentGranted {
                return "Confirm cloud data transmission before continuing."
            }
            if !model.isBYOKBaseURLValid {
                return "BYOK provider must use HTTPS, except localhost HTTP."
            }
            if model.settings.byokTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a transcription model before continuing."
            }
            if !model.hasBYOKKey {
                return "Store an API key in Keychain before continuing."
            }
            return "Configure your provider before continuing."
        }
    }

    private var requiredPermissionsGranted: Bool {
        OnboardingReadiness.hasRequiredPermissions(
            route: model.settings.route,
            microphoneGranted: model.permissions.states[.microphone] == .granted,
            speechRecognitionGranted: model.permissions.states[.speechRecognition] == .granted,
            requiresSpeechRecognition: requiresSpeechRecognition
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
        switch currentStep {
        case .language:
            return true
        case .engine:
            if model.settings.route == .byok {
                return true
            }
            return engineReady
        case .cloud:
            return engineReady
        case .delivery, .shortcut:
            return true
        case .permissions:
            if model.isOnboardingTestActive {
                return model.isStartingDictation || model.transcriber.canStop
            }
            return requiredPermissionsGranted
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
    /// Deep Navy (#1E2A44) - Sayso anchor color from Android Theme
    static let brandNavy = Color(red: 0x1E / 255.0, green: 0x2A / 255.0, blue: 0x44 / 255.0)
    /// Golden Amber (#F4B942) - Sayso accent color from Android Theme
    static let brandAmber = Color(red: 0xF4 / 255.0, green: 0xB9 / 255.0, blue: 0x42 / 255.0)
    static let amberDark = Color(red: 0xD9 / 255.0, green: 0x9B / 255.0, blue: 0x26 / 255.0)
    static let amberContainer = Color(red: 0xFE / 255.0, green: 0xF3 / 255.0, blue: 0xC7 / 255.0)
    static let onAmberContainer = Color(red: 0x92 / 255.0, green: 0x40 / 255.0, blue: 0x0E / 255.0)

    static let cobalt = Color(red: 37 / 255.0, green: 99 / 255.0, blue: 235 / 255.0)
    static let brandCobalt = Color(red: 0x25 / 255.0, green: 0x63 / 255.0, blue: 0xEB / 255.0)
    static let brandCobaltDark = Color(red: 0x1D / 255.0, green: 0x4E / 255.0, blue: 0xD8 / 255.0)
    static let amber = Color(red: 0xF4 / 255.0, green: 0xB9 / 255.0, blue: 0x42 / 255.0)
    static let crimson = Color(red: 239 / 255.0, green: 68 / 255.0, blue: 68 / 255.0)
    static let emerald = Color(red: 0x16 / 255.0, green: 0xA3 / 255.0, blue: 0x4A / 255.0)
    static let obsidian = Color(red: 11 / 255.0, green: 15 / 255.0, blue: 23 / 255.0)
    static let surface = Color(red: 19 / 255.0, green: 27 / 255.0, blue: 42 / 255.0)
    static let surfaceRaised = Color(red: 30 / 255.0, green: 41 / 255.0, blue: 59 / 255.0)
    static let outline = Color(red: 51 / 255.0, green: 65 / 255.0, blue: 85 / 255.0)
    static let muted = Color(red: 148 / 255.0, green: 163 / 255.0, blue: 184 / 255.0)

    static let brandNavyDark = Color(red: 0x0C / 255.0, green: 0x13 / 255.0, blue: 0x22 / 255.0)
    static let brandNavySurface = Color(red: 0x15 / 255.0, green: 0x1F / 255.0, blue: 0x33 / 255.0)
    static let brandNavySurfaceTop = Color(red: 0x1A / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0)
    static let brandNavySurfaceBottom = Color(red: 0x11 / 255.0, green: 0x1A / 255.0, blue: 0x2B / 255.0)
    static let brandNavyElevated = Color(red: 0x1E / 255.0, green: 0x2A / 255.0, blue: 0x44 / 255.0)
    static let brandNavyContainer = Color(red: 0x26 / 255.0, green: 0x36 / 255.0, blue: 0x54 / 255.0)
    static let brandNavyWell = Color(red: 0x09 / 255.0, green: 0x0E / 255.0, blue: 0x1A / 255.0)
    static let brandOutline = Color(red: 0x33 / 255.0, green: 0x46 / 255.0, blue: 0x68 / 255.0)

    static var cardSurfaceGradient: LinearGradient {
        LinearGradient(
            colors: [brandNavySurfaceTop, brandNavySurfaceBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var cardBevelBorder: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.12),
                brandNavyContainer.opacity(0.7),
                Color.black.opacity(0.4)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var activeGlowGradient: LinearGradient {
        LinearGradient(
            colors: [brandAmber, amberDark],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var blueButtonGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0), brandCobaltDark],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var amberButtonGradient: LinearGradient {
        LinearGradient(
            colors: [brandAmber, amberDark],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

