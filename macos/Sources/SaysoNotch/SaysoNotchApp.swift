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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Onboarding Tour...") {
                    model.openOnboardingWizard()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Sayso Onboarding Tour") {
                    model.openOnboardingWizard()
                }
            }
        }
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
        var cycle: JevControlRunState
        var target: NSRunningApplication
        let installedApplications: [InstalledDesktopApplication]
        let isTryNow: Bool
        let calculatorTask: CalculatorControlTask?
        var hasStarted = false
        var waitCount = 0
        var previous: String?
        var clarification: (choices: [String], askedAt: Date)?
        var apiKey: String?
        var calculatorWasCleared = false
        var nextCalculatorCommandIndex = 1

        init(
            cycle: JevControlRunState,
            target: NSRunningApplication,
            installedApplications: [InstalledDesktopApplication],
            isTryNow: Bool,
            calculatorTask: CalculatorControlTask?
        ) {
            self.cycle = cycle
            self.target = target
            self.installedApplications = installedApplications
            self.isTryNow = isTryNow
            self.calculatorTask = calculatorTask
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
    private var pendingControlFinishes = false
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
    @Published private(set) var historyGate = HistoryOperationGate()
    var reprocessingHistoryID: UUID? { historyGate.reprocessingID }
    var isImportingHistoryAudio: Bool { historyGate.isImporting }
    var isClearingHistory: Bool { historyGate.isClearing }
    var isHistoryAudioTaskRunning: Bool { historyGate.isAudioTaskRunning }
    @Published var onboardingDeferredThisLaunch = false
    @Published var isShowingOnboardingWizard = false
    @Published private(set) var isOnboardingTestActive = false
    @Published private(set) var onboardingTestTranscriptID: UUID?
    @Published private(set) var onboardingTestTranscriptText: String?
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var hasBYOKKey = false
    @Published private(set) var isCheckingControlTryNowReadiness = false
    @Published var slmStates: [String: LocalSlmState] = [:]
    @Published var slmDownloadProgress: [String: Double] = [:]
    @Published public var livePreviewText: String = ""

    let permissions = PermissionCenter()
    let transcriber: LiveTranscriber
    let localEnglishModel: FluidAudioLocalModelManager
    let localPunjabiModel: SherpaPunjabiModelManager
    let audioInputDeviceController = CoreAudioInputDeviceController()
    let speech = SpeechOutput()
    private lazy var tts = TtsModule(synthesizer: speech)
    private lazy var historyModule = HistoryModule(port: history)
    private let moduleEvents = SaysoEventBus()
    private var controlAnswerSubscriptions: [SaysoSubscription] = []
    private var dictationPhaseBridge: DictationPhaseBridge?
    private var dictationStopSubscription: SaysoSubscription?
    private var controlOutcome: ControlRunFinished.Outcome = .failed
    private lazy var controlCoordinator = ControlRunCoordinator(bus: moduleEvents)
    private lazy var vocabularyBridge = VocabularyBridge(learning: corrections, bus: moduleEvents)
    private lazy var vocabularyModule = VocabularyModule(port: vocabularyBridge)
    private let externalActivities = ExternalActivitiesModule()
    private var moduleSocket: SaysoModuleSocketServer?
    private lazy var shortcutIntents = ShortcutIntentModule(handler: AppShortcutIntents(model: self))
    private let clipboardModule = ClipboardModule(port: PasteboardClipboardPort(), scheduler: SaysoDispatchScheduler())
    private let fileShelf = FileShelfModule(port: FileSystemShelfPort(), scheduler: SaysoDispatchScheduler())
    private let timerModule = TimerModule(scheduler: SaysoDispatchScheduler())
    private var timerPingSubscription: SaysoSubscription?
    private let caffeineModule = CaffeineModule(port: IOPMAssertionPort(), scheduler: SaysoDispatchScheduler())
    private var terminateObserver: NSObjectProtocol?
    private let worldClocks = WorldClocksModule(
        store: UserDefaultsWorldClocksStore(defaults: SaysoAppModel.settingsDefaults),
        scheduler: SaysoDispatchScheduler(),
        hourCycle: WorldClockHourCycle(locale: .autoupdatingCurrent)
    )
    private lazy var modules = SaysoModuleHost(
        modules: [
            tts, historyModule, vocabularyModule, ModelsModule(), shortcutIntents, DictationModule(), ControlModule(),
            externalActivities, clipboardModule, fileShelf, timerModule, caffeineModule, worldClocks,
        ],
        events: moduleEvents
    )
    let history = HistoryStore(maximumEntries: nil)
    let corrections: SaysoCorrectionLearning
    let sessions = RecordingSessionStore()
    let controller = AXDesktopController()
    let desktopControlSession = ControlSession()
    let controlAudit = ControlAuditStore()
    let secrets = KeychainSecretStore()
    private let automation = SaysoAutomationServer()
    private let settingsStore = SaysoAppModel.makeSettingsStore()
    private let hotKeyEngine = HotKeyEngine()
    private let controlFnHotKeyEngine = HotKeyEngine()
    private let shortcutManager = SaysoShortcutManager()
    private let notch: NotchPanelController
    private var controlKeyDownTime: Date?
    private let launchDate = Date()
    private var mainWindow: NSWindow?
    private var lastExternalApplication: NSRunningApplication?
    private var dictationDestination: TextOutput.Destination?
    private var liveInsertion: TextOutput.LiveInsertion?
    private var voiceEditCapture: SelectedTextEdit.Capture?
    private(set) var activeRecordingSession: RecordingSession?
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
    private var modelInstallObservers: [AnyCancellable] = []
    private var expiryTicker: SaysoExpiryTicker?
    private var modelRetrySubscription: SaysoSubscription?
    private lazy var modelInstallReporter = ModelInstallReporter(bus: moduleEvents)
    private var transcriberChangeObserver: AnyCancellable?
    private var controlRun: ControlCommandRun?
    private var controlExecutionTask: Task<Void, Never>?
    private var controlPreparationTask: Task<Void, Never>?
    private var controlPreparationID: UUID?
    private var controlTryNowArmed = false
    private var controlReadinessTask: Task<Void, Never>?
    private var controlReadinessID: UUID?
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
        if Self.usesFreshSettings { saved.onboardingCompleted = true }
        settings = saved
        corrections = SaysoCorrectionLearning(promotionThreshold: saved.autoCorrectionsPromotionThreshold)
        audioInputDevices = audioInputDeviceController.inputDevices()
        hasBYOKKey = secrets.secret(named: "byok-api-key") != nil
        let shortcutBindings = Self.loadShortcutBindings()
        dictationHotKey = shortcutBindings.dictation
        controlHotKey = shortcutBindings.control
        toggleNotchHotKey = shortcutBindings.toggleNotch
        hotKeyEngine.updateConfiguration(.init(holdThreshold: saved.hotKeyHoldThresholdSeconds, doubleTapWindow: 0.25, gestureCooldown: 0.08))
        controlFnHotKeyEngine.updateConfiguration(.init(holdThreshold: saved.hotKeyHoldThresholdSeconds, doubleTapWindow: 0.25, gestureCooldown: 0.08))
        notch = NotchPanelController()
        isNotchOverlayVisible = notch.isVisible
        permissionsChangeObserver = permissions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        modules.onActivitiesChanged = { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        expiryTicker = SaysoExpiryTicker(host: modules, scheduler: SaysoDispatchScheduler())
        modules.enable("vocabulary")
        modules.enable("models")
        // Timers need no permission and read nothing private, so they run without an opt-in.
        modules.enable(timerModule.descriptor.id)
        timerPingSubscription = moduleEvents.subscribe(TimerPing.self) { _ in
            DispatchQueue.main.async { NSSound(named: "Glass")?.play() }
        }
        // Caffeine holds nothing until the user starts a session, so it is on by default.
        modules.enable(caffeineModule.descriptor.id)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The system also drops the assertion when the process exits; this releases it on a clean quit first.
            MainActor.assumeIsolated { self?.stopCaffeineForQuit() }
        }
        // World clocks only read the clock and need no permission; with an empty list they arm nothing.
        modules.enable(worldClocks.descriptor.id)
        applyOptInModuleSettings()
        startControlModule()
        startExternalAPIIfEnabled()
        startDictationModule()
        observeModelInstalls()
        correctionChanges = corrections.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // objectWillChange fires before the store updates, so read the candidates on the next turn.
            DispatchQueue.main.async { self?.vocabularyBridge.sync() }
        }
        transcriberChangeObserver = transcriber.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        hotKeyEngine.register(gesture: .singleTap) { [weak self] in
            self?.handleMonitoredHotKeyGesture(.singleTap)
        }
        hotKeyEngine.register(gesture: .doubleTap) { [weak self] in
            self?.handleMonitoredHotKeyGesture(.doubleTap)
        }
        hotKeyEngine.register(gesture: .tripleTap) { [weak self] in
            self?.handleMonitoredHotKeyGesture(.tripleTap)
        }
        controlFnHotKeyEngine.register(gesture: .tripleTap) { [weak self] in
            self?.handleControlGestureToggle()
        }
        hotKeyEngine.register(gesture: .holdStart) { [weak self] in
            guard self?.monitoredHotKey == self?.dictationHotKey else { return }
            self?.startHoldDictation()
        }
        hotKeyEngine.register(gesture: .holdEnd) { [weak self] in
            guard self?.monitoredHotKey == self?.dictationHotKey else { return }
            self?.stopHoldDictation()
        }
        modules.enable("shortcut-intents")
        shortcutManager.onActionTriggered = { [weak self] action, isKeyDown in
            self?.moduleEvents.publish(ShortcutTriggered(action: action, isKeyDown: isKeyDown))
        }
        refreshShortcutRegistrations()
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
        if CommandLine.arguments.contains("--ui-test-review") {
            // UI test hook: a review with no pending desktop step, so Approve and Deny cannot act on the desktop.
            DispatchQueue.main.async { [weak self] in
                self?.controlCoordinator.begin(goal: "UI test review")
                self?.controlCoordinator.requestReview(reason: "UI test review")
            }
        }
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

    private static let usesFreshSettings = CommandLine.arguments.contains("--ui-test-fresh-settings")

    /// UI test hook: settings and the world clocks list live in a throwaway suite wiped once at launch, so UI tests
    /// see the defaults and never read or write the user's real settings.
    private static let settingsDefaults: UserDefaults = {
        guard usesFreshSettings else { return .standard }
        let suite = "ai.sayso.notch.ui-test-settings"
        // Falling back to the standard defaults here would write test state into the user's real settings.
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("UI test settings suite unavailable") }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    private static func makeSettingsStore() -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: settingsDefaults)
    }

    func save() {
        if !settings.byokConsentGranted { settings.cloudCleanupEnabled = false }
        corrections.setPromotionThreshold(settings.autoCorrectionsPromotionThreshold)
        if !settings.autoCorrectionsEnabled { corrections.stopMonitoring() }
        hotKeyEngine.updateConfiguration(.init(holdThreshold: settings.hotKeyHoldThresholdSeconds, doubleTapWindow: 0.25, gestureCooldown: 0.08))
        controlFnHotKeyEngine.updateConfiguration(.init(holdThreshold: settings.hotKeyHoldThresholdSeconds, doubleTapWindow: 0.25, gestureCooldown: 0.08))
        applyOptInModuleSettings()
        settingsStore.save(settings)
    }

    /// Modules that read the pasteboard or hold file access run only while the user has opted in;
    /// turning one off stops it and purges what it held.
    private func applyOptInModuleSettings() {
        // Descriptor ids, not literals: the host ignores unknown ids, so a typo would silently skip the purge.
        modules.setEnabled(clipboardModule.descriptor.id, settings.clipboardModuleEnabled)
        modules.setEnabled(fileShelf.descriptor.id, settings.fileShelfEnabled)
    }

    var fileShelfItems: [FileShelfItem] { fileShelf.items }

    /// The Pomodoro, running or paused; the timer module allows only one.
    var pomodoro: TimerSnapshot? {
        timerModule.timers.first { if case .pomodoro = $0.kind { true } else { false } }
    }

    func startPomodoro() {
        objectWillChange.send()
        if timerModule.startPomodoro() == nil { notice = "A Pomodoro is already running." }
    }

    func cancelPomodoro() {
        guard let id = pomodoro?.id else { return }
        objectWillChange.send()
        timerModule.cancel(id)
    }

    var caffeineSession: CaffeineSession? { caffeineModule.session }

    func startCaffeine(_ duration: CaffeineDuration) {
        objectWillChange.send()
        guard !caffeineModule.start(duration) else { return }
        notice = modules.health(of: caffeineModule.descriptor.id) == .quarantined
            ? "Caffeine is paused after repeated failures. Quit and reopen Sayso to use it again."
            : "Caffeine is off. macOS refused to keep the Mac awake."
    }

    func stopCaffeine() {
        objectWillChange.send()
        caffeineModule.stop()
    }

    private func stopCaffeineForQuit() {
        modules.disable(caffeineModule.descriptor.id)
    }

    static let worldClockQuickAdds = [
        WorldClockZone(identifier: "Europe/London", city: "London"),
        WorldClockZone(identifier: "America/New_York", city: "New York"),
        WorldClockZone(identifier: "Asia/Tokyo", city: "Tokyo"),
        WorldClockZone(identifier: "Asia/Kolkata", city: "Kolkata"),
    ]

    /// Read at render time; the pane redraws when the minute changes because the module republishes its
    /// notch line then, so nothing here ticks every second.
    var worldClockReadings: [WorldClockReading] { worldClocks.readings }

    func addWorldClock(_ zone: WorldClockZone) {
        objectWillChange.send()
        do {
            try worldClocks.add(zone.identifier, city: zone.city)
        } catch {
            notice = switch error {
            case .full: "World clocks hold up to \(WorldClocksModule.maxZones) places. Remove one to add another."
            case .duplicate: "\(zone.city) is already in your world clocks."
            case .unknownZone: "\(zone.city) has no time zone this Mac recognises."
            case .disabled: "World clocks are off. Quit and reopen Sayso to turn them back on."
            }
        }
    }

    func removeWorldClock(_ identifier: String) {
        objectWillChange.send()
        worldClocks.remove(identifier)
    }

    func moveWorldClockUp(_ identifier: String) {
        guard let index = worldClocks.zones.firstIndex(where: { $0.identifier == identifier }), index > 0 else { return }
        objectWillChange.send()
        worldClocks.move(identifier, to: index - 1)
    }

    func addToFileShelf(_ urls: [URL]) {
        objectWillChange.send()
        let added = fileShelf.add(urls)
        if added < urls.count {
            notice = "Added \(added) of \(urls.count) to the file shelf. The rest were missing or could not be read."
        }
    }

    func revealOnFileShelf(_ id: FileShelfItem.ID) {
        // The shelf prunes an item whose file has gone, so a failed reveal also changes the list.
        objectWillChange.send()
        if !fileShelf.reveal(id: id) { notice = "That file is no longer where it was, so it was removed from the shelf." }
    }

    func removeFromFileShelf(_ id: FileShelfItem.ID) {
        objectWillChange.send()
        fileShelf.remove(id: id)
    }

    func refreshAudioInputDevices() {
        audioInputDevices = audioInputDeviceController.inputDevices()
    }

    func setDictationHotKey(_ hotKey: HotKey) {
        dictationHotKey = hotKey
        Self.saveHotKey(hotKey, for: .dictation)
        refreshShortcutRegistrations()
    }

    func setControlHotKey(_ hotKey: HotKey) {
        controlHotKey = hotKey
        Self.saveHotKey(hotKey, for: .control)
        refreshShortcutRegistrations()
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

    private var monitoredHotKey: HotKey {
        ShortcutGestureRouter.monitoredHotKey(dictation: dictationHotKey, control: controlHotKey)
    }

    private func refreshShortcutRegistrations() {
        hotKeyEngine.start(for: monitoredHotKey)
        shortcutManager.unregister(action: .dictation)
        controlFnHotKeyEngine.stop()
        if ShortcutGestureRouter.needsSeparateControlMonitor(
            dictation: dictationHotKey,
            control: controlHotKey
        ) {
            controlFnHotKeyEngine.start(for: .fnKey)
        }
        shortcutManager.register(action: .control, hotKey: controlHotKey)
        shortcutManager.register(action: .toggleNotch, hotKey: toggleNotchHotKey)
    }

    private func handleMonitoredHotKeyGesture(_ gesture: HotKeyGesture) {
        if transcriber.canStop || isStartingDictation || handsFreeCycle.isArmed {
            if gesture == .singleTap || gesture == .doubleTap {
                startOrStopDictation()
                return
            }
        }
        switch ShortcutGestureRouter.action(
            for: gesture,
            monitoredHotKey: monitoredHotKey,
            dictation: dictationHotKey,
            control: controlHotKey
        ) {
        case .dictation:
            handleTapDictationShortcut()
        case .control:
            handleControlGestureToggle()
        case .voiceEdit:
            startOrStopVoiceEdit()
        case nil:
            break
        }
    }

    fileprivate func performShortcutIntent(_ intent: AppShortcutIntents.Intent) {
        switch intent {
        case .dictation: handleTapDictationShortcut()
        case .controlDown: handleControlHotKeyDown()
        case .controlUp: handleControlHotKeyUp()
        case .toggleNotch: toggleNotch()
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

    private func handleControlGestureToggle() {
        if settings.mode == .control, transcriber.canStop {
            transcriber.stop()
            return
        }
        controlTryNowArmed = false
        if settings.mode == .control {
            startOrStopDictation()
            return
        }
        if transcriber.canStop {
            transcriber.stop()
        }
        switchMode(.control)
        requestDictationStart(onboardingTest: false)
    }

    func startOrStopControl() {
        handleControlGestureToggle()
    }

    func startControlTryNow() {
        guard transcriber.canStart, !isStartingDictation, controlReadinessTask == nil else { return }
        switch ControlTryNowPolicy.readinessIssue(
            mode: settings.mode,
            desktopControlEnabled: settings.desktopControlEnabled,
            accessibilityGranted: AXIsProcessTrusted()
        ) {
        case .chooseControl:
            controlStatus = "Choose Control before Try now. Nothing executed."
            return
        case .enableDesktopControl:
            controlStatus = "Try now needs Desktop Control enabled in Settings. Nothing executed."
            return
        case .accessibilityPermission:
            controlStatus = "Try now needs Accessibility permission. Nothing executed."
            promptAccessibilityPermission()
            return
        case nil:
            break
        }
        controlStatus = "Checking Jev credential readiness..."
        isCheckingControlTryNowReadiness = true
        let readinessID = UUID()
        controlReadinessID = readinessID
        controlReadinessTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.controlReadinessID == readinessID {
                    self.isCheckingControlTryNowReadiness = false
                    self.controlReadinessTask = nil
                    self.controlReadinessID = nil
                }
            }
            guard await self.typeSafeKey() != nil else {
                self.controlStatus = "Try now needs a TypeSafe / Jev key in Keychain or Bitwarden. Nothing executed."
                return
            }
            guard !Task.isCancelled,
                  self.controlReadinessID == readinessID,
                  self.settings.mode == .control else { return }
            guard self.settings.desktopControlEnabled,
                  AXIsProcessTrusted(),
                  self.transcriber.canStart else {
                self.controlStatus = "Try now readiness changed. Nothing executed."
                return
            }
            self.controlStatus = "Ready. Listening for Open Calculator."
            self.controlTryNowArmed = true
            if !self.requestDictationStart(onboardingTest: false) {
                self.controlTryNowArmed = false
            }
        }
    }

    var controlTryNowReadiness: String {
        if !settings.desktopControlEnabled { return "Enable Desktop Control before trying." }
        if !AXIsProcessTrusted() { return "Accessibility permission required; no action will run." }
        if hasTypeSafeKey { return "Ready: Accessibility and Jev credential configured." }
        return "Accessibility ready; Jev credential checked securely at start."
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

    private static let shortcutDefaultsMigrationVersionKey = "sayso.shortcut-defaults-version"

    private static func loadShortcutBindings() -> SaysoShortcutBindings {
        let defaults = UserDefaults.standard
        let fromVersion = defaults.integer(forKey: shortcutDefaultsMigrationVersionKey)
        let bindings = ShortcutDefaultsMigration.migrate(
            dictation: storedHotKey(for: .dictation, defaults: defaults),
            control: storedHotKey(for: .control, defaults: defaults),
            toggleNotch: storedHotKey(for: .toggleNotch, defaults: defaults),
            fromVersion: fromVersion
        )
        guard fromVersion < ShortcutDefaultsMigration.currentVersion else { return bindings }
        saveHotKey(bindings.dictation, for: .dictation)
        saveHotKey(bindings.control, for: .control)
        saveHotKey(bindings.toggleNotch, for: .toggleNotch)
        defaults.set(ShortcutDefaultsMigration.currentVersion, forKey: shortcutDefaultsMigrationVersionKey)
        return bindings
    }

    private static func storedHotKey(for action: SaysoShortcutAction, defaults: UserDefaults) -> HotKey? {
        guard let data = defaults.data(forKey: action.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotKey.self, from: data)
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
        onboardingTestTranscriptText = nil
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
        guard !historyGate.blocksDictation else {
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
        livePreviewText = ""
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
        liveInsertion = !onboardingTest && capture == nil && sessionSettings.autoInsert && sessionSettings.livePartialInsertion && sessionSettings.transcriptionExecutionMode == .streaming
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
                executionMode: sessionSettings.transcriptionExecutionMode,
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
        livePreviewText = text
        objectWillChange.send()
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
        livePreviewText = transcript.text
        objectWillChange.send()
        if applyPendingVoiceMode() {
            livePreviewText = ""
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
            let isTryNow = controlTryNowArmed
            controlTryNowArmed = false
            liveInsertion?.discard()
            liveInsertion = nil
            discardTranscriptAudio(transcript)
            updateActiveSession { $0.completeControlCommand(transcript.text) }
            activeRecordingSession = nil
            activeDictationSettings = nil
            dictationDestination = nil
            runControl(transcript.text, isTryNow: isTryNow)
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
                    let historyResult = await appendToHistory(updated)
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
        let historyResult = await appendToHistory(completed)
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
        livePreviewText = corrected.displayText
        objectWillChange.send()
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

        let cloudProvider = CloudProviderCatalog.provider(for: currentSettings.selectedCloudCleanupProviderId) ?? CloudProviderCatalog.groq
        let cloudKey = CleanupRoute.needsCloudCredentials(
            mode: currentSettings.cleanupMode,
            cloudCleanupEnabled: currentSettings.cloudCleanupEnabled,
            byokConsentGranted: currentSettings.byokConsentGranted
        ) ? keyForProvider(cloudProvider) : nil
        let cloudBaseURL = currentSettings.normalizedBYOKCleanupBaseURL ?? currentSettings.normalizedBYOKBaseURL
        let cloudModel = currentSettings.byokCleanupModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = CleanupRoute.resolve(
            mode: currentSettings.cleanupMode,
            cloudCleanupEnabled: currentSettings.cloudCleanupEnabled,
            byokConsentGranted: currentSettings.byokConsentGranted,
            hasCloudKey: cloudKey != nil,
            hasCloudBaseURL: cloudBaseURL != nil,
            hasCloudModel: !cloudModel.isEmpty
        )
        let directives = currentSettings.dictationProfile.cleanupDirectives
        var localSLM: (@Sendable (String) async throws -> String)?
        if let endpoint = URL(string: "http://127.0.0.1:11434/v1") {
            let slmModelName = currentSettings.selectedLocalSlmModelId.contains("qwen") ? "qwen2.5:0.5b" : "smollm2:360m"
            localSLM = { raw in
                // Ollama offline: fail fast so the pipeline falls back to rules immediately.
                guard LocalPortProbe.isLocalPortOpen(port: 11434, timeoutMs: 50) else { throw SaysoError.unavailable("Local cleanup model") }
                return try await OpenAICompatibleTranscriptCleaner(baseURL: endpoint, apiKey: "ollama", model: slmModelName)
                    .clean(raw, language: language, lexiconDirectives: directives)
            }
        }
        var cloud: (@Sendable (String) async throws -> String)?
        if let key = cloudKey, let baseURL = cloudBaseURL {
            cloud = { raw in
                try await OpenAICompatibleTranscriptCleaner(baseURL: baseURL, apiKey: key, model: cloudModel)
                    .clean(raw, language: language, lexiconDirectives: directives)
            }
        }
        let outcome = await CleanupPipeline.run(
            text: text,
            route: route,
            rulesOutput: local,
            finish: { [self] provided in
                var cleaned = TranscriptCleanup.smartFormat(
                    provided,
                    capitalizesFirstLetter: true,
                    capitalizesSentences: currentSettings.cleanupPreset != .minimal,
                    addsTerminalPunctuation: currentSettings.cleanupPreset != .developer
                )
                cleaned = currentSettings.dictationProfile.postProcess(cleaned)
                cleaned = LexiconCorrections.apply(cleaned, replacements: currentSettings.lexicon)
                cleaned = LexiconCorrections.apply(cleaned, pronunciations: currentSettings.pronunciations)
                return corrections.apply(to: cleaned).transformedText
            },
            localSLM: localSLM,
            cloud: cloud
        )
        if let notice = outcome.notice { transcriptProcessingNotice = notice }
        return outcome.text
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
        let historyResult = await appendToHistory(transcript)
        let finalText = transcript.displayText
        let output: TextOutput.DeliveryResult
        if let liveInsertion = pendingDelivery.liveInsertion {
            switch liveInsertion.finalize(finalText) {
            case .applied:
                output = .delivered(liveInsertion.deliveryMethod)
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
        onboardingTestTranscriptText = transcript.text
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
        livePreviewText = ""
        objectWillChange.send()
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
        livePreviewText = ""
        objectWillChange.send()
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
        livePreviewText = ""
        objectWillChange.send()
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
        if mode != .control {
            controlReadinessTask?.cancel()
            controlReadinessTask = nil
            controlReadinessID = nil
            isCheckingControlTryNowReadiness = false
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sayso"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0x0C / 255.0, green: 0x13 / 255.0, blue: 0x22 / 255.0, alpha: 1.0)
        window.contentView = NSHostingView(rootView: SettingsHome(model: self).frame(minWidth: 1000, minHeight: 680))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    func minimizeMainWindow() {
        (NSApplication.shared.keyWindow ?? mainWindow)?.miniaturize(nil)
    }

    func openOnboardingWizard() {
        isShowingOnboardingWizard = true
        showMainWindow()
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
        if let key = secrets.secret(named: "\(provider.id)-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let key = secrets.secret(named: "\(provider.id).apiKey"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            try? secrets.store(trimmed, named: "\(provider.id)-api-key")
            try? secrets.store(trimmed, named: "\(provider.id).apiKey")
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
        secrets.remove(named: "\(provider.id)-api-key")
        secrets.remove(named: "\(provider.id).apiKey")
        if provider.id == "openai" || provider.id == "custom" {
            secrets.remove(named: "byok-api-key")
            hasBYOKKey = false
        }
        notice = "\(provider.displayName) key removed from Keychain."
    }

    func keyForProvider(_ provider: CloudProvider) -> String? {
        if provider.id == "ollama" { return "local-ollama" }
        if let key = secrets.secret(named: provider.keychainServiceIdentifier), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let key = secrets.secret(named: "\(provider.id)-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let key = secrets.secret(named: "\(provider.id).apiKey"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if provider.id == "openai" || provider.id == "custom" {
            if let key = secrets.secret(named: "byok-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return key.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    func keyForProvider(id: String) -> String? {
        guard let p = CloudProviderCatalog.provider(for: id) else {
            return secrets.secret(named: "byok-api-key")
        }
        return keyForProvider(p)
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

    func typeSafeKey() async -> String? {
        if let key = secrets.secret(named: "typesafe-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let jevStore = KeychainSecretStore(service: "local.jev-use")
        if let key = jevStore.secret(named: "typesafe-api-key"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return await bitwardenTypeSafeKey()
    }

    private func bitwardenTypeSafeKey(excluding rejectedKey: String? = nil) async -> String? {
        guard let key = await BitwardenSecretsManager.typeSafeKey(), key != rejectedKey else { return nil }
        return key
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
        let sttProvider = CloudProviderCatalog.provider(for: settings.selectedCloudProviderId) ?? CloudProviderCatalog.groq
        return OnboardingReadiness.isBYOKConfigured(
            baseURLString: settings.byokBaseURL,
            transcriptionModel: settings.byokTranscriptionModel,
            hasAPIKey: hasKey(for: sttProvider) || hasBYOKKey
        )
    }

    private func cloudTranscriptionConfiguration(
        for currentSettings: SaysoSettings
    ) -> OpenAICompatibleAudioTranscriptionConfiguration? {
        guard currentSettings.route == .byok,
              currentSettings.byokConsentGranted else {
            return nil
        }
        let sttProvider = CloudProviderCatalog.provider(for: currentSettings.selectedCloudProviderId) ?? CloudProviderCatalog.groq
        guard let apiKey = keyForProvider(sttProvider),
              let baseURL = currentSettings.normalizedBYOKBaseURL else {
            return nil
        }
        let model = currentSettings.byokTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return .init(baseURL: baseURL, apiKey: apiKey, model: model, providerId: sttProvider.id)
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
            clearPendingControlStep()
            controlPreparationTask?.cancel()
            controlPreparationTask = nil
            controlPreparationID = nil
            endControl(.cancelled, message: "Desktop control disabled.")
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
        speak(plan: speechPlan(text, language: language))
    }

    func speakLatest() {
        guard let transcript = lastTranscript else { return }
        let transcriptLanguage = transcript.spokenLanguage(outputLanguage: settings.outputLanguage)
        speak(plan: speechPlan(transcript.displayText, language: transcriptLanguage))
    }

    private func speechPlan(_ text: String, language: DictationLanguage?) -> SpeechPlan? {
        SpeechPlan.resolve(
            text: text,
            language: language,
            settingsLanguage: settings.speechLanguage,
            selectedVoiceID: settings.speechVoiceIdentifier,
            rate: settings.speechRate,
            installedVoiceIDs: { Set(SpeechOutput.availableVoices(for: $0).map(\.id)) }
        )
    }

    /// Every transcript save goes through the history module; the caller still owns the result and its notices.
    private func appendToHistory(_ transcript: Transcript) async -> HistoryAppendResult {
        modules.enable("history")
        // A disabled or quarantined module must never lose a transcript: fall back to the store directly.
        if let result = await historyModule.append(transcript) { return result }
        return await history.appendResult(transcript)
    }

    /// One-line status for the primary module activity (download progress, history failure, suggestions).
    var moduleActivityStatus: String? {
        guard let primary = modules.engine.primary else { return nil }
        let presentation = SaysoActivityPresentation(primary)
        return [presentation.title, presentation.subtitle].compactMap { $0 }.joined(separator: " · ")
    }

    /// The shown module activity, if any.
    var primaryModuleActivity: SaysoActivity? { modules.engine.primary }

    /// Studio tabs by module id; modules without a tab open the first tab.
    private static let studioTabs = [
        "dictation": 0, "control": 1, "history": 2, "models": 4, "vocabulary": 6, "timer": 7, "caffeine": 7, "world-clocks": 7,
        "shortcut-intents": 8,
        "tts": 9,
    ]

    /// Selects the Studio tab for a module through the shared router; permission problems open Settings.
    func openStudio(forModule moduleID: String) {
        let granted = Set(PermissionKind.allCases.filter { permissions.states[$0] == .granted })
        let route = SaysoStudioRouter.route(
            moduleID: moduleID,
            descriptors: modules.descriptors,
            health: { [modules] in modules.health(of: $0) },
            isGranted: { SaysoStudioNavigation.isGranted($0, grantedPermissions: granted) }
        )
        selectedTab = SaysoStudioNavigation.tab(for: route, moduleTabs: Self.studioTabs, settingsTab: 10, defaultTab: 0)
    }

    /// Runs one named action of the shown module activity (used for explicit Approve/Deny buttons).
    func performModuleAction(_ actionID: String) {
        guard let primary = modules.engine.primary else { return }
        modules.perform(actionID: actionID, stackID: primary.stackID, moduleID: primary.moduleID)
    }

    /// Runs the action a tap was bound to, only if that exact activity is still shown (never a replacement).
    func performModuleAction(_ tap: NotchTapAction) {
        guard let primary = modules.engine.primary,
              primary.moduleID == tap.moduleID, primary.stackID == tap.stackID,
              primary.actions.contains(where: { $0.id == tap.actionID }) else { return }
        modules.perform(actionID: tap.actionID, stackID: tap.stackID, moduleID: tap.moduleID)
    }

    /// Dismisses the shown module activity: its own dismiss action if it has one, otherwise just clears it.
    func dismissPrimaryModuleActivity() {
        guard let primary = modules.engine.primary else { return }
        if primary.actions.contains(where: { $0.id == "dismiss" }) {
            modules.perform(actionID: "dismiss", stackID: primary.stackID, moduleID: primary.moduleID)
        } else {
            modules.dismiss(moduleID: primary.moduleID, stackID: primary.stackID)
        }
    }

    private func phase(_ state: FluidAudioLocalModelState) -> ModelInstallReporter.Phase {
        switch state {
        case .notInstalled: .idle
        case .installing: .installing
        case .installed: .installed
        case .failed: .failed
        }
    }

    /// Local scripts can show activities through an owner-only socket, but only when the user opts in:
    /// `defaults write <bundle id> sayso.externalAPI.enabled -bool true`.
    private func startExternalAPIIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "sayso.externalAPI.enabled") else { return }
        modules.enable("external")
        let api = SaysoExternalAPI(host: modules, external: externalActivities)
        let directory = (SaysoAutomationEndpoint.socketPath as NSString).deletingLastPathComponent
        let server = SaysoModuleSocketServer(path: directory + "/modules.sock") { api.handle($0) }
        do {
            try server.start()
            moduleSocket = server
        } catch {
            modules.disable("external")
        }
    }

    /// Feeds model manager state into install events and runs retries requested from the activity.
    private func observeModelInstalls() {
        let reporter = modelInstallReporter
        modelInstallObservers = [
            localEnglishModel.$state.combineLatest(localEnglishModel.$downloadProgress)
                .sink { [weak self] state, fraction in
                    guard let self else { return }
                    reporter.observe(
                        modelID: FluidAudioLocalModelManager.modelID, displayName: FluidAudioLocalModelManager.displayName,
                        phase: self.phase(state), fraction: fraction
                    )
                },
            localEnglishModel.$multilingualState.combineLatest(localEnglishModel.$multilingualDownloadProgress)
                .sink { [weak self] state, fraction in
                    guard let self else { return }
                    reporter.observe(
                        modelID: FluidAudioLocalModelManager.multilingualModelID,
                        displayName: FluidAudioLocalModelManager.multilingualDisplayName,
                        phase: self.phase(state), fraction: fraction
                    )
                },
            localPunjabiModel.$state.sink { state in
                let phase: ModelInstallReporter.Phase = switch state {
                case .notInstalled: .idle
                case .installing: .installing
                case .installed: .installed
                case .failed: .failed
                }
                reporter.observe(
                    modelID: SherpaPunjabiModelManager.modelID, displayName: SherpaPunjabiModelManager.displayName,
                    phase: phase, fraction: nil
                )
            },
        ]
        modelRetrySubscription = moduleEvents.subscribe(ModelInstallRetryRequested.self) { [weak self] request in
            Task { @MainActor in
                guard let self else { return }
                switch request.modelID {
                case FluidAudioLocalModelManager.modelID: await self.localEnglishModel.install()
                case FluidAudioLocalModelManager.multilingualModelID:
                    await self.localEnglishModel.install(language: self.settings.language)
                case SherpaPunjabiModelManager.modelID: await self.localPunjabiModel.install()
                default: break
                }
            }
        }
    }

    private func speak(plan: SpeechPlan?) {
        guard let plan else { return }
        modules.enable("tts")
        tts.speak(plan)
    }

    func reprocessHistory(_ entry: Transcript) async {
        guard historyGate.begin(.reprocess(entry.id)) else {
            notice = "Finish the current history audio task before reprocessing."
            return
        }
        defer { historyGate.end(.reprocess(entry.id)) }
        guard !isStartingDictation, transcriber.phase == .idle else {
            notice = "Stop dictation before reprocessing saved audio."
            return
        }
        guard let audioFileURL = entry.audioFileURL,
              FileManager.default.fileExists(atPath: audioFileURL.path) else {
            notice = "This history item has no saved audio to reprocess."
            return
        }
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
            guard await appendToHistory(completed).didSave else {
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
        guard historyGate.beginAudioTask() else {
            notice = "Finish the current history audio task before reprocessing."
            return
        }
        historyAudioTask = Task { [weak self] in
            guard let self else { return }
            defer { self.historyGate.endAudioTask() }
            await self.reprocessHistory(entry)
            self.historyAudioTask = nil
        }
    }

    func importHistoryAudio(_ sourceURLs: [URL]) async {
        guard historyGate.begin(.importAudio) else {
            notice = "Finish the current history audio task before importing."
            return
        }
        defer { historyGate.end(.importAudio) }
        guard !isStartingDictation, transcriber.phase == .idle else {
            notice = "Stop dictation before importing audio."
            return
        }
        let settingsSnapshot = settings
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
                guard await appendToHistory(completed).didSave else {
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
        guard historyGate.beginAudioTask() else {
            notice = "Finish the current history audio task before importing."
            return
        }
        historyAudioTask = Task { [weak self] in
            guard let self else { return }
            defer { self.historyGate.endAudioTask() }
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
        guard historyGate.begin(.clear) else {
            notice = "Finish the current history audio task before clearing history."
            return false
        }
        defer { historyGate.end(.clear) }
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

    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    func promptAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func captureDesktop() {
        guard desktopControlEnabled() else { return }
        if !AXIsProcessTrusted() {
            promptAccessibilityPermission()
            controlStatus = "Accessibility permission needed. If enabled in System Settings, relaunch Sayso Notch to activate."
            return
        }
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

    func runControl(_ command: String, isTryNow: Bool = false) {
        guard desktopControlEnabled() else { return }
        guard !isTryNow || ControlTryNowPolicy.acceptsTranscript(command) else {
            controlStatus = "Try now expected Open Calculator."
            return
        }
        if let run = controlRun, let pending = run.clarification, controlExecutionTask == nil {
            if ControlClarification.isAnswer(command, to: pending.choices, askedAt: pending.askedAt) {
                do {
                    run.cycle = try JevControlRunState(
                        goal: "\(run.cycle.goal). User clarification: \(command.trimmingCharacters(in: .whitespacesAndNewlines))",
                        recentActions: run.cycle.recentActions
                    )
                    run.clarification = nil
                    controlStatus = "Applying clarification"
                    executeControlRun(run)
                } catch {
                    controlStatus = error.localizedDescription
                }
                return
            }
            // A late or unrelated reply is a new command. beginCommand() resets the session budget.
            endControl(.cancelled, message: controlStatus)
            controlRun = nil
        }
        guard controlRun == nil, controlPreparationTask == nil else {
            controlStatus = "Control command already active."
            return
        }
        do {
            let target = try controlTarget()
            let cycle = try JevControlRunState(goal: command)
            let calculatorTask = ControlPlanner.calculatorTask(from: command)
            // Open + Clear + each key must fit inside the session action budget, or Equals is never checked.
            if let calculatorTask, calculatorTask.commands.count + 1 >= ControlSessionLimits().maxActions {
                throw SaysoError.invalidAction("Calculator control supports shorter numbers. Nothing executed.")
            }
            let preparationID = UUID()
            controlPreparationID = preparationID
            controlStatus = "Preparing control command"
            // A previous run that never announced its end is closed first, so no card is left behind.
            controlCoordinator.end(.cancelled, message: "Replaced by a new command")
            controlCoordinator.begin(goal: command)
            controlPreparationTask = Task { [weak self] in
                let availableApplications = await Task.detached(priority: .utility) {
                    InstalledDesktopApplication.available()
                }.value
                let applications = isTryNow
                    ? ControlTryNowPolicy.candidateApplications(from: availableApplications)
                    : availableApplications
                guard !Task.isCancelled,
                      let self,
                      self.controlPreparationID == preparationID else { return }
                self.controlPreparationTask = nil
                self.controlPreparationID = nil
                guard self.controlRun == nil else { return }
                let run = ControlCommandRun(
                    cycle: cycle,
                    target: target,
                    installedApplications: applications,
                    isTryNow: isTryNow,
                    calculatorTask: calculatorTask
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
            clearPendingControlStep()
            if let run = controlRun { requestControlCancellation(run, status: "Desktop control disabled.") }
            return
        }
        guard let step = pendingControlStep, let run = controlRun else { return }
        clearPendingControlStep()
        let finishes = pendingControlFinishes
        pendingControlFinishes = false
        executeControlRun(run, approvedStep: step, approvedFinishes: finishes)
    }

    func discardPendingControl() {
        clearPendingControlStep()
        pendingControlFinishes = false
        guard let run = controlRun else {
            controlStatus = "Action discarded"
            return
        }
        requestControlCancellation(run, status: "Action discarded")
    }

    /// Mirrors transcriber phases as dictation activities; the Stop action reuses the existing stop path.
    private func startDictationModule() {
        modules.enable("dictation")
        dictationPhaseBridge = DictationPhaseBridge(phases: transcriber.$phase.eraseToAnyPublisher(), bus: moduleEvents)
        dictationStopSubscription = moduleEvents.subscribe(DictationStopRequested.self) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transcriber.canStop || self.isStartingDictation else { return }
                self.startOrStopDictation()
            }
        }
    }

    /// Turns the control module's answers back into the existing guarded control paths.
    private func startControlModule() {
        modules.enable("control")
        // Answers are checked against the exact reviewed step inside the coordinator before they reach here.
        controlCoordinator.onDecision = { [weak self] decision, _ in
            MainActor.assumeIsolated {
                if decision == .approved { self?.approvePendingControl() } else { self?.discardPendingControl() }
            }
        }
        controlAnswerSubscriptions = [
            moduleEvents.subscribe(ControlCancelRequested.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelControl() }
            },
            moduleEvents.subscribe(ControlClarificationChosen.self) { [weak self] chosen in
                MainActor.assumeIsolated { self?.runControl(chosen.choice) }
            },
        ]
    }

    func cancelControl() {
        clearPendingControlStep()
        pendingControlFinishes = false
        if controlPreparationTask != nil {
            controlPreparationTask?.cancel()
            controlPreparationTask = nil
            controlPreparationID = nil
            controlStatus = "Control command cancelled."
            endControl(.cancelled, message: controlStatus)
            return
        }
        guard let run = controlRun else {
            controlStatus = "No active control task"
            return
        }
        requestControlCancellation(run, status: "Cancellation requested. Current macOS action may still finish.")
    }

    private func planWithJevCycle(
        snapshot: DesktopSnapshot,
        run: ControlCommandRun,
        apiKey: String
    ) async throws -> (plan: JevCyclePlan, alternatives: [String]) {
        controlStatus = "Consulting Jev model..."
        let offer = JevControlBridge.makeCycleOffer(
            goal: run.cycle.goal,
            snapshot: snapshot,
            recentActions: run.cycle.recentActions,
            installedApplications: run.installedApplications,
            previous: run.previous
        )
        let decision: JevDecision
        do {
            decision = try await JevClient.cycle(
                state: offer.state,
                operations: offer.operations,
                heads: offer.heads,
                apiKey: apiKey
            )
        } catch let error as JevServiceError where error.status == 401 || error.status == 403 {
            guard let fallback = await bitwardenTypeSafeKey(excluding: apiKey) else { throw error }
            run.apiKey = fallback
            decision = try await JevClient.cycle(
                state: offer.state,
                operations: offer.operations,
                heads: offer.heads,
                apiKey: fallback
            )
        }
        return (
            try JevControlBridge.planCycleStep(from: decision, offer: offer),
            JevControlBridge.cycleAlternatives(from: decision, offer: offer)
        )
    }

    private func executeControlRun(
        _ run: ControlCommandRun,
        approvedStep: ControlPlanStep? = nil,
        approvedFinishes: Bool = false
    ) {
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
                var carriedStep = approvedStep.map { ($0, approvedFinishes) }
                while true {
                    try Task.checkCancellation()
                    let step: ControlPlanStep
                    let finishes: Bool
                    var isApprovedStep = false
                    if let approved = carriedStep {
                        step = approved.0
                        finishes = approved.1
                        carriedStep = nil
                        isApprovedStep = true
                    } else {
                        let snapshot = try controller.capture(application: run.target)
                        currentSnapshot = snapshot
                        if let task = run.calculatorTask,
                           run.target.bundleIdentifier == "com.apple.calculator" {
                            if run.nextCalculatorCommandIndex >= task.commands.count {
                                guard task.resultIsVisible(in: snapshot.observations) else {
                                    throw SaysoError.invalidAction("Calculator did not show the expected result \(task.expectedResult).")
                                }
                                await completeControlRun("Control completed: \(task.expectedResult)")
                                return
                            }
                            let command: String
                            if !run.calculatorWasCleared {
                                guard let clear = snapshot.elements.first(where: {
                                    ["All Clear", "Clear"].contains($0.title) && $0.supportsPress
                                }) else {
                                    throw SaysoError.invalidAction("Calculator Clear control is unavailable.")
                                }
                                command = "click \(clear.title)"
                                run.calculatorWasCleared = true
                            } else {
                                command = task.commands[run.nextCalculatorCommandIndex]
                                run.nextCalculatorCommandIndex += 1
                            }
                            step = try ControlPlanner.plan(
                                command: command,
                                snapshot: snapshot,
                                installedApplications: run.installedApplications
                            )
                            finishes = false
                            isApprovedStep = true
                            controlStatus = "Planned: verified Calculator step"
                            moduleEvents.publish(ControlStepPlanned(reason: "verified Calculator step"))
                        } else {
                            // Resolve once per run: Keychain reads and a bws spawn are not per-cycle work.
                            if run.apiKey == nil { run.apiKey = await typeSafeKey() }
                            guard let jevKey = run.apiKey else {
                                throw SaysoError.unavailable("Configure the TypeSafe / Jev key before using Control.")
                            }
                            let planned = try await planWithJevCycle(snapshot: snapshot, run: run, apiKey: jevKey)
                            switch planned.plan {
                            case .done:
                                await completeControlRun("Control completed")
                                return
                            case .blocked:
                                _ = await desktopControlSession.fail()
                                controlStatus = "Jev could not find a safe next action."
                                finishControlRun()
                                return
                            case .wait:
                                run.waitCount += 1
                                guard run.waitCount <= 2 else {
                                    throw SaysoError.unavailable("The required control did not appear.")
                                }
                                run.cycle.record(action: "WAIT", result: "waited 0.4 seconds", screenChanged: false)
                                try await Task.sleep(for: .milliseconds(400))
                                continue
                            case let .execute(stepCandidate, completesGoal):
                                step = stepCandidate
                                finishes = completesGoal && run.calculatorTask == nil
                            }
                            controlStatus = "Planned: \(step.reason)"
                            moduleEvents.publish(ControlStepPlanned(reason: step.reason))
                            if step.confidence < ControlPolicy.minimumConfidence {
                                let choices = planned.alternatives
                                guard !choices.isEmpty else {
                                    throw SaysoError.invalidAction("Jev was not confident enough to act.")
                                }
                                let question = "Which one: \(choices.joined(separator: ", "))?"
                                run.previous = question
                                run.clarification = (choices, Date())
                                controlStatus = question
                                moduleEvents.publish(ControlClarificationAsked(question: question, choices: choices, askedAt: Date()))
                                controlExecutionTask = nil
                                return
                            }
                            if run.isTryNow, !ControlTryNowPolicy.canApprove(step) {
                                throw SaysoError.invalidAction("Try now refused an unexpected Jev action.")
                            }
                            if ControlPolicy.requiresConfirmation(step) {
                                if run.isTryNow {
                                    isApprovedStep = true
                                } else {
                                    pendingControlStep = step
                                    pendingControlFinishes = finishes
                                    controlStatus = "Review required: \(step.reason)"
                                    controlCoordinator.requestReview(reason: step.reason)
                                    controlExecutionTask = nil
                                    return
                                }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    actionWasDispatched = true
                    let entry = try await controller.execute(step, approved: isApprovedStep, targetApplication: run.target)
                    await controlAudit.append(entry)
                    controlEntries = await controlAudit.entries()
                    guard !Task.isCancelled, controlRun === run else { return }
                    updateControlTarget(after: entry, step: step, run: run)
                    run.cycle.record(
                        action: step.reason,
                        result: entry.result,
                        screenChanged: entry.effect == .observed
                    )
                    run.waitCount = 0
                    let updated = await desktopControlSession.record(.init(entry.effect))
                    actionWasDispatched = false
                    guard updated.canRunAction else {
                        controlStatus = "\(entry.result), \(updated.result?.rawValue ?? "stopped")"
                        finishControlRun()
                        return
                    }
                    controlStatus = entry.result
                    if ControlCycleCompletion.shouldComplete(after: step.action, effect: entry.effect, goal: run.cycle.goal)
                        || finishes && (entry.effect == .observed || entry.effect == .alreadySatisfied) {
                        await completeControlRun("Control completed")
                        return
                    }
                }
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

    private func completeControlRun(_ status: String) async {
        let completed = await desktopControlSession.complete()
        controlStatus = completed.result == .completed ? status : "Control stopped"
        controlOutcome = completed.result == .completed ? .completed : .failed
        finishControlRun()
    }

    /// Tells the control module the pending review no longer applies, whichever path resolved it.
    private func clearPendingControlStep() {
        pendingControlStep = nil
        controlCoordinator.resolveElsewhere()
    }

    /// The only place a Control run is announced as finished; the coordinator ignores later calls for the same run,
    /// so a cancel followed by a late completion cannot show "completed" after the user cancelled.
    private func endControl(_ outcome: ControlRunFinished.Outcome, message: String) {
        pendingControlStep = nil
        controlCoordinator.end(outcome, message: message)
    }

    private func finishControlRun() {
        endControl(controlOutcome, message: controlStatus)
        controlOutcome = .failed
        clearPendingControlStep()
        pendingControlFinishes = false
        controlRun = nil
        controlExecutionTask = nil
    }

    private func updateControlTarget(
        after entry: ControlAuditEntry,
        step: ControlPlanStep,
        run: ControlCommandRun
    ) {
        guard entry.effect == .observed, step.action.mayMoveControlTarget,
              let target = NSWorkspace.shared.frontmostApplication, !target.isTerminated else { return }
        if let bundleIdentifier = step.action.validatedNextTargetBundleIdentifier,
           target.bundleIdentifier != bundleIdentifier { return }
        run.target = target
    }

    private func requestControlCancellation(_ run: ControlCommandRun, status: String) {
        controlExecutionTask?.cancel()
        controlStatus = status
        endControl(.cancelled, message: status)
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
        let isControl = model.settings.mode == .control
        let actionLabel = if model.transcriber.canStop {
            isControl ? "Stop control" : "Stop dictation"
        } else if !isControl, model.isContinuousDictationArmed {
            "Stop continuous dictation"
        } else if model.transcriber.canStart {
            isControl ? "Start control" : "Start dictation"
        } else {
            isControl ? "Finishing control" : "Finishing dictation"
        }
        VStack(alignment: .leading, spacing: 12) {
            Label("Sayso Notch", systemImage: "waveform.circle.fill")
                .font(.headline)
            let activeText = !model.livePreviewText.isEmpty ? model.livePreviewText : model.transcriber.partialText
            Text(activeText.isEmpty ? "Ready" : activeText)
                .lineLimit(2)
            Button(actionLabel) {
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
            Divider()
            Button("Onboarding Tour...") { model.openOnboardingWizard() }
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

                timersSection

                caffeineSection

                worldClocksSection

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

    /// Studio starts and cancels the Pomodoro; its time shows in the notch through the module activity.
    private var timersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Timers").font(.headline)
                Text("A Pomodoro runs 25 minutes of focus, then a 5 minute break, with a 15 minute break after every fourth focus. The time shows in the notch and a sound plays when a phase changes. It lives in memory and stops when Sayso quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let pomodoro = model.pomodoro {
                    Text(pomodoro.title)
                        .font(.body.monospacedDigit())
                        .accessibilityIdentifier("timer-status")
                    Spacer()
                    Button("Cancel Pomodoro") { model.cancelPomodoro() }
                        .accessibilityIdentifier("timer-cancel")
                } else {
                    Button("Start 25 min Pomodoro") { model.startPomodoro() }
                        .accessibilityIdentifier("timer-start-25")
                }
            }
        }
        .padding(20)
        .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Studio starts and stops Caffeine; the time left shows in the notch through the module activity.
    private var caffeineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Caffeine").font(.headline)
                Text("Keeps the display and the Mac from going to sleep while idle. Starting again replaces the running session. It lives in memory and stops when Sayso quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("15 min") { model.startCaffeine(.fifteenMinutes) }
                    .accessibilityIdentifier("caffeine-start-15")
                Button("1 hour") { model.startCaffeine(.oneHour) }
                    .accessibilityIdentifier("caffeine-start-60")
                Button("Until stopped") { model.startCaffeine(.indefinite) }
                    .accessibilityIdentifier("caffeine-start-indefinite")
                if let session = model.caffeineSession {
                    Spacer()
                    Text(session.title)
                        .font(.body.monospacedDigit())
                        .accessibilityIdentifier("caffeine-status")
                    Button("Stop") { model.stopCaffeine() }
                        .accessibilityIdentifier("caffeine-stop")
                }
            }
        }
        .padding(20)
        .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Studio picks the places; the first one also shows in the open notch through the module's ambient line.
    @ViewBuilder
    private var worldClocksSection: some View {
        let readings = model.worldClockReadings
        let listed = Set(readings.map(\.zone.identifier))
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("World clocks").font(.headline)
                Text("Shows the time in up to \(WorldClocksModule.maxZones) places, with +1d or -1d when the date differs from yours. The first place also shows in the open notch when nothing more important is there. The list is saved on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(SaysoAppModel.worldClockQuickAdds, id: \.identifier) { zone in
                    Button("Add \(zone.city)") { model.addWorldClock(zone) }
                        .disabled(listed.contains(zone.identifier) || readings.count >= WorldClocksModule.maxZones)
                        .accessibilityIdentifier("world-clocks-add-\(zone.identifier)")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if readings.isEmpty {
                    Text("No clocks yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(readings.enumerated()), id: \.element.zone.identifier) { index, reading in
                    let identifier = reading.zone.identifier
                    HStack(spacing: 12) {
                        Text(reading.title)
                            .font(.body.monospacedDigit())
                            .accessibilityIdentifier("world-clocks-row-\(identifier)")
                        Spacer()
                        Button("Move up") { model.moveWorldClockUp(identifier) }
                            .disabled(index == 0)
                            .accessibilityIdentifier("world-clocks-move-up-\(identifier)")
                        Button("Remove") { model.removeWorldClock(identifier) }
                            .accessibilityLabel("Remove \(reading.zone.city)")
                            .accessibilityIdentifier("world-clocks-remove-\(identifier)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("world-clocks-list")
        }
        .padding(20)
        .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
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

                    Text("Double-tap Fn for Dictation. Triple-tap Fn for Control. A custom Dictation shortcut keeps double-tap voice edit.")
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
    private static let studioPaneIDs = [
        0: "speak", 1: "control", 2: "history", 3: "transcription", 4: "models", 5: "cleanup",
        6: "vocabulary", 7: "notch", 8: "shortcuts", 9: "tts", 10: "settings",
    ]
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
                    Spacer()
                    Button {
                        model.minimizeMainWindow()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SaysoPalette.muted)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Minimise Sayso (⌘M)")
                    .accessibilityLabel("Minimise Sayso")
                }
                .padding(16)

                List(selection: $model.selectedTab) {
                    Section("Activity") {
                        Label("Speak", systemImage: "waveform").tag(0).accessibilityIdentifier("studio-tab-speak")
                        Label("Control", systemImage: "cursorarrow.click").tag(1).accessibilityIdentifier("studio-tab-control")
                        Label("History", systemImage: "clock.arrow.circlepath").tag(2).accessibilityIdentifier("studio-tab-history")
                    }
                    Section("Pipeline") {
                        Label("Transcription", systemImage: "mic.badge.waveform").tag(3).accessibilityIdentifier("studio-tab-transcription")
                        Label("Models & Downloads", systemImage: "square.stack.3d.up.fill").tag(4).accessibilityIdentifier("studio-tab-models")
                        Label("AI Cleanup", systemImage: "sparkles").tag(5).accessibilityIdentifier("studio-tab-cleanup")
                        Label("Vocabulary Dictionary", systemImage: "character.book.closed").tag(6).accessibilityIdentifier("studio-tab-vocabulary")
                    }
                    Section("Desktop & Triggers") {
                        Label("Notch & HUD", systemImage: "menubar.rectangle").tag(7).accessibilityIdentifier("studio-tab-notch")
                        Label("Shortcuts", systemImage: "keyboard").tag(8).accessibilityIdentifier("studio-tab-shortcuts")
                    }
                    Section("System") {
                        Label("Voice output", systemImage: "speaker.wave.2").tag(9).accessibilityIdentifier("studio-tab-tts")
                        Label("Settings", systemImage: "gearshape").tag(10).accessibilityIdentifier("studio-tab-settings")
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
                    Button {
                        model.openOnboardingWizard()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("Onboarding")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(SaysoPalette.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Open onboarding tour")
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio-pane-\(Self.studioPaneIDs[model.selectedTab] ?? "settings")")
            .navigationTitle(selectedTabTitle)
            .safeAreaInset(edge: .top, spacing: 0) {
                SaysoPalette.brandNavyDark
                    .frame(height: 1)
                    .background(SaysoPalette.brandNavyDark.ignoresSafeArea(.container, edges: .top))
                    .overlay(alignment: .bottom) {
                        Divider().background(SaysoPalette.brandNavyContainer)
                    }
            }
            .toolbarBackground(SaysoPalette.brandNavyDark, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.minimizeMainWindow()
                    } label: {
                        Label("Minimize", systemImage: "minus")
                    }
                    .help("Minimize Sayso window (⌘M)")
                    .accessibilityLabel("Minimize Sayso window")
                }
            }
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
            get: { (!model.settings.onboardingCompleted && !model.onboardingDeferredThisLaunch) || model.isShowingOnboardingWizard },
            set: { if !$0 { model.isShowingOnboardingWizard = false } }
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

struct SaysoAudioLevelMeter: View {
    let level: Float
    private let weights: [CGFloat] = [0.55, 0.85, 0.62, 1.0, 0.6]
    private let maxHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.75, blue: 0.48),
                            Color(red: 0.55, green: 0.80, blue: 0.32),
                            Color(red: 0.90, green: 0.71, blue: 0.24)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    ))
                    .frame(width: 3.5, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return max(3, weights[index] * clamped * maxHeight)
    }
}

struct SaysoRecordDot: View {
    let isLive: Bool
    private let size: CGFloat = 14

    var body: some View {
        Group {
            if isLive {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.5 + 0.5 * sin(elapsed * .pi * 1.6)
                    Circle()
                        .fill(SaysoPalette.crimson)
                        .frame(width: size, height: size)
                        .scaleEffect(0.9 + 0.15 * pulse)
                        .shadow(color: SaysoPalette.crimson.opacity(0.3 + 0.4 * pulse), radius: 3 + 4 * pulse)
                }
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: 20, height: 20, alignment: .center)
    }
}

struct SaysoElapsedTimerLabel: View {
    let startedAt: Date?
    let isLive: Bool

    var body: some View {
        if isLive, let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                let totalSecs = Int(elapsed)
                let mins = totalSecs / 60
                let secs = totalSecs % 60
                let label = mins > 0 ? String(format: "%d:%02ds", mins, secs) : "\(secs)s"
                Text(label)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SaysoPalette.muted)
            }
        } else {
            Text("0s")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(SaysoPalette.muted.opacity(0.6))
        }
    }
}

struct SaysoCompactHUDCapsule: View {
    @ObservedObject var model: SaysoAppModel
    var action: () -> Void

    private var isLive: Bool {
        model.transcriber.canStop || model.transcriber.phase == .listening
    }

    private var shortcutHint: String {
        ShortcutHint.compact(for: .dictation, hotKey: model.dictationHotKey)
    }

    private var microphoneName: String {
        if let uid = model.settings.preferredAudioInputUID,
           let dev = model.audioInputDevices.first(where: { $0.uid == uid }) {
            return dev.name
        }
        return "Default Microphone"
    }

    private var engineBadge: String {
        switch model.settings.route {
        case .local:
            return model.settings.transcriptionExecutionMode == .batch ? "Local Batch Core ML" : "Local Streaming"
        case .byok:
            let provider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId)?.displayName ?? "Cloud"
            return "\(provider) (\(model.settings.transcriptionExecutionMode == .batch ? "Batch" : "Streaming"))"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                // Top row: dot · meter · timer
                HStack(spacing: 10) {
                    SaysoRecordDot(isLive: isLive)
                    Spacer()
                    if isLive {
                        SaysoAudioLevelMeter(level: model.transcriber.audioLevel)
                    }
                    Spacer()
                    SaysoElapsedTimerLabel(startedAt: model.activeRecordingSession?.startedAt, isLive: isLive)
                }
                .frame(height: 24)

                // Middle: text / prompt
                VStack(alignment: .leading, spacing: 6) {
                    let activeText = !model.livePreviewText.isEmpty ? model.livePreviewText : model.transcriber.partialText
                    if !activeText.isEmpty {
                        Text(activeText)
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isLive {
                        Text(model.settings.transcriptionExecutionMode == .batch ? "Listening... (transcribing on stop)" : "Listening for speech...")
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .foregroundStyle(SaysoPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Tap anywhere or press \(shortcutHint) to speak")
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .foregroundStyle(SaysoPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minHeight: 80, alignment: .topLeading)

                // Footer capsule: mic · route badge · click hint
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isLive ? SaysoPalette.crimson : SaysoPalette.muted)
                        Text(microphoneName)
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)
                            .lineLimit(1)
                    }
                    Text("·").font(.caption2).foregroundStyle(SaysoPalette.muted)
                    Text(engineBadge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(SaysoPalette.amber)
                    Spacer()
                    Text(isLive ? "Click to Stop" : "Click to Record")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isLive ? SaysoPalette.crimson : SaysoPalette.cobalt)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((isLive ? SaysoPalette.crimson : SaysoPalette.cobalt).opacity(0.15), in: Capsule())
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SaysoPalette.brandNavySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isLive ? SaysoPalette.crimson.opacity(0.6) : SaysoPalette.brandNavyContainer, lineWidth: 1.5)
            )
            .shadow(color: isLive ? SaysoPalette.crimson.opacity(0.2) : Color.black.opacity(0.25), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!model.transcriber.canStop && !model.transcriber.canStart)
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

            SaysoCompactHUDCapsule(model: model) {
                model.startOrStopDictation()
            }

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

                        if !AXIsProcessTrusted() {
                            Divider().background(SaysoPalette.brandNavyContainer)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(SaysoPalette.brandAmber)
                                    Text("Accessibility Permission Required")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(SaysoPalette.brandAmber)
                                }

                                Text("macOS requires Accessibility access to inspect and control visible UI elements. If you just toggled this on in System Settings, you must relaunch Sayso Notch for macOS to activate the permission.")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.muted)

                                HStack(spacing: 10) {
                                    Button {
                                        model.promptAccessibilityPermission()
                                    } label: {
                                        Label("Open Accessibility Settings ↗", systemImage: "gearshape")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(SaysoPalette.brandAmber)
                                    .font(.caption.weight(.semibold))

                                    Button {
                                        model.relaunchApp()
                                    } label: {
                                        Label("Relaunch Sayso Notch", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(SaysoPalette.cobalt)
                                    .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(10)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1))
                        }

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
                                    Text(entry.planningSource.rawValue.capitalized)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(entry.planningSource == .jev ? SaysoPalette.amber : SaysoPalette.muted)
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
            HStack(spacing: 18) {
                Label("\(insights.entries) \(isFiltered ? "matching" : "entries")", systemImage: "text.quote")
                Label("\(insights.words) words", systemImage: "textformat")
                Label("\(insights.activeDays) days", systemImage: "calendar")
                if insights.totalDurationSeconds > 0 {
                    Label(insights.formattedDuration, systemImage: "clock")
                }
                if insights.averageWordsPerMinute > 0 {
                    Label(String(format: "%.0f WPM", insights.averageWordsPerMinute), systemImage: "speedometer")
                }
                if insights.estimatedCloudSpendUSD > 0 {
                    Label(String(format: "$%.2f cloud spend", insights.estimatedCloudSpendUSD), systemImage: "dollarsign.circle")
                }
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
    var embeddedInCard: Bool = false
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
        if embeddedInCard {
            cardContent
        } else {
            SaysoCard {
                cardContent
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Indic Transliteration (\(langTitle))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Format spoken Indian language into English letters or native script")
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

private struct SaysoSpokenLanguageModelWidget: View {
    @ObservedObject var model: SaysoAppModel

    private var activeHeaderTitle: String {
        "Selected: \(model.settings.language.displayName) · \(activeModelDisplayName)"
    }

    private var activeModelDisplayName: String {
        switch model.settings.route {
        case .local:
            if let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId),
               manifest.supports(model.settings.language) {
                return manifest.displayName
            }
            return LocalModelCatalog.recommendedModel(for: model.settings.language).displayName
        case .byok:
            let provider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId)
            return "\(provider?.displayName ?? "Cloud") / \(model.settings.selectedCloudModelId)"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    private var recommendationBannerText: String {
        let name = activeModelDisplayName
        switch model.settings.language {
        case .english:
            if model.settings.route == .local, let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId) {
                return "★ \(manifest.displayName) Active · \(manifest.summary)"
            } else if model.settings.route == .appleSpeech {
                return "★ Apple Speech Active · macOS native speech recognition"
            } else if model.settings.route == .byok {
                return "★ \(name) Active · Cloud streaming dictation"
            }
            return "★ \(name) Active · Best for English dictation, fast streaming & punctuation"
        case .tamil:
            return "★ \(name) Active · Best for colloquial Tamil, Tanglish & dialects"
        case .hindi:
            return "★ \(name) Active · Best for conversational Hindi & Hinglish"
        case .malayalam:
            return "★ \(name) Active · Best for colloquial Malayalam, Manglish & dialects"
        case .punjabi:
            return "★ \(name) Active · Best for colloquial Punjabi & conversational dialects"
        default:
            return "★ \(name) Active · Dedicated on-device neural model"
        }
    }

    private func modelSubtitle(for language: DictationLanguage) -> String {
        if model.settings.language == language {
            return activeModelDisplayName
        }
        return LocalModelCatalog.recommendedModel(for: language).displayName
    }

    private func modelDownloadSize(for language: DictationLanguage) -> Int {
        if model.settings.language == language && model.settings.route == .local {
            if let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId),
               manifest.supports(language) {
                return Int(manifest.expectedSizeBytes / 1_000_000)
            }
        }
        let rec = LocalModelCatalog.recommendedModel(for: language)
        return Int(rec.expectedSizeBytes / 1_000_000)
    }

    private var compatibleLocalModels: [LocalModelManifest] {
        LocalModelCatalog.models(for: model.settings.language)
    }

    private var isEnglishInstalled: Bool {
        model.localEnglishModel.state.isInstalled
    }

    private var isEnglishInstalling: Bool {
        if case .installing = model.localEnglishModel.state { return true }
        return false
    }

    private var englishDownloadProgress: Double {
        model.localEnglishModel.downloadProgress
    }

    var body: some View {
        SaysoCard {
            VStack(alignment: .leading, spacing: 14) {
                // Header inside card
                VStack(alignment: .leading, spacing: 3) {
                    Text(activeHeaderTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Each language activates its dedicated on-device neural model")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                }

                // 2x2 Language Quick Select Grid
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    quickLanguageCard(
                        language: .english,
                        title: "English",
                        modelSubtitle: modelSubtitle(for: .english),
                        downloadSizeMb: modelDownloadSize(for: .english)
                    )

                    quickLanguageCard(
                        language: .tamil,
                        title: "Tamil (தமிழ்)",
                        modelSubtitle: modelSubtitle(for: .tamil),
                        downloadSizeMb: modelDownloadSize(for: .tamil)
                    )

                    quickLanguageCard(
                        language: .hindi,
                        title: "Hindi (हिंदी)",
                        modelSubtitle: modelSubtitle(for: .hindi),
                        downloadSizeMb: modelDownloadSize(for: .hindi)
                    )

                    quickLanguageCard(
                        language: .malayalam,
                        title: "Malayalam (മലയാളം)",
                        modelSubtitle: modelSubtitle(for: .malayalam),
                        downloadSizeMb: modelDownloadSize(for: .malayalam)
                    )
                }

                // Below grid: English download CTA OR recommendation banner
                if model.settings.language == .english {
                    if !isEnglishInstalled {
                        // Download & Activate banner card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(SaysoPalette.brandAmber)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Parakeet 110M (104 MB)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                    Text("Download required to activate English")
                                        .font(.caption)
                                        .foregroundStyle(SaysoPalette.muted)
                                }
                                Spacer()
                            }

                            if isEnglishInstalling {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        ProgressView().controlSize(.small)
                                        Text("Downloading English model... \(Int(englishDownloadProgress * 100))%")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(SaysoPalette.brandAmber)
                                    }
                                    ProgressView(value: englishDownloadProgress)
                                        .tint(SaysoPalette.brandAmber)
                                }
                            } else {
                                Button {
                                    Task { await model.localEnglishModel.install() }
                                } label: {
                                    HStack {
                                        Spacer()
                                        Text("Download & Activate (104 MB)")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(SaysoPalette.brandNavyDark)
                                        Spacer()
                                    }
                                    .padding(.vertical, 10)
                                    .background(SaysoPalette.amberButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                                    .shadow(color: SaysoPalette.brandAmber.opacity(0.4), radius: 6, x: 0, y: 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1)
                        )
                    } else {
                        // English Active Recommendation Banner (Cream / Amber style matching Android)
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(red: 217 / 255.0, green: 119 / 255.0, blue: 6 / 255.0))
                            Text(recommendationBannerText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 120 / 255.0, green: 53 / 255.0, blue: 15 / 255.0))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(red: 254 / 255.0, green: 243 / 255.0, blue: 199 / 255.0), in: RoundedRectangle(cornerRadius: 8))

                        // English Model Choices Switcher
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speech Engine / Model")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Choose between ultra-fast streaming, multilingual, or Apple native")
                                    .font(.caption2)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                            Spacer()
                            Picker("Model", selection: Binding(
                                get: {
                                    if model.settings.route == .appleSpeech {
                                        return "appleSpeech"
                                    } else if model.settings.route == .byok {
                                        return "byok"
                                    }
                                    if compatibleLocalModels.contains(where: { $0.id == model.settings.selectedLocalAsrModelId }) {
                                        return model.settings.selectedLocalAsrModelId
                                    }
                                    return LocalModelCatalog.recommendedModel(for: .english).id
                                },
                                set: { choice in
                                    if choice == "appleSpeech" {
                                        model.settings.route = .appleSpeech
                                    } else if choice == "byok" {
                                        model.settings.route = .byok
                                    } else {
                                        model.settings.route = .local
                                        model.settings.selectedLocalAsrModelId = choice
                                    }
                                    model.save()
                                }
                            )) {
                                ForEach(compatibleLocalModels) { manifest in
                                    Text("\(manifest.displayName) (\(manifest.expectedSizeBytes / 1_000_000) MB)")
                                        .tag(manifest.id)
                                }
                                Text("Apple Speech (macOS Native)").tag("appleSpeech")
                                Text("Cloud BYOK").tag("byok")
                            }
                            .labelsHidden()
                        }
                    }
                } else if model.settings.language.isIndic {
                    // Indic Recommendation Banner
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 217 / 255.0, green: 119 / 255.0, blue: 6 / 255.0))
                        Text(recommendationBannerText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 120 / 255.0, green: 53 / 255.0, blue: 15 / 255.0))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 254 / 255.0, green: 243 / 255.0, blue: 199 / 255.0), in: RoundedRectangle(cornerRadius: 8))

                    // Indic Transliteration Section (Only shown for Indic languages!)
                    SaysoTransliterationCard(
                        transliterateToLatin: $model.settings.transliterateIndicToLatin,
                        languageCode: model.settings.language.languageCode,
                        embeddedInCard: true,
                        onToggle: { _ in model.save() }
                    )
                } else {
                    // Non-Indic other language banner
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 217 / 255.0, green: 119 / 255.0, blue: 6 / 255.0))
                        Text(recommendationBannerText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 120 / 255.0, green: 53 / 255.0, blue: 15 / 255.0))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 254 / 255.0, green: 243 / 255.0, blue: 199 / 255.0), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider().background(SaysoPalette.brandNavyContainer)

                // More languages footer menu
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.subheadline)
                        .foregroundStyle(SaysoPalette.cobalt)
                    Text("More languages (Spanish, French, German, Japanese, Punjabi, etc.)")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                    Spacer()

                    Menu {
                        ForEach(DictationLanguage.allCases.filter { !isQuickLanguage($0) }) { lang in
                            Button {
                                selectLanguage(lang)
                            } label: {
                                HStack {
                                    Text(lang.displayName)
                                    if model.settings.language == lang {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isQuickLanguage(model.settings.language) ? "Choose" : model.settings.language.displayName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(SaysoPalette.brandAmber)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isQuickLanguage(_ lang: DictationLanguage) -> Bool {
        lang == .english || lang == .tamil || lang == .hindi || lang == .malayalam
    }

    private func selectLanguage(_ lang: DictationLanguage) {
        model.settings.language = lang
        if model.settings.route == .local {
            model.settings.selectedLocalAsrModelId = LocalModelCatalog.recommendedModel(for: lang).id
        }
        model.save()
    }

    @ViewBuilder
    private func quickLanguageCard(
        language: DictationLanguage,
        title: String,
        modelSubtitle: String,
        downloadSizeMb: Int
    ) -> some View {
        let isSelected = model.settings.language == language
        let isDownloaded: Bool = {
            if language == .english {
                if model.settings.route == .appleSpeech || model.settings.route == .byok {
                    return true
                }
                return isEnglishInstalled
            }
            return true
        }()

        Button {
            selectLanguage(language)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isSelected ? .white : Color(white: 0.9))
                    Spacer()
                    if isSelected {
                        Circle()
                            .fill(SaysoPalette.brandAmber)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(modelSubtitle)
                    .font(.caption)
                    .foregroundStyle(SaysoPalette.muted)

                HStack(spacing: 4) {
                    if isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.emerald)
                        Text(isSelected ? "Active" : "Ready (\(downloadSizeMb) MB)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.emerald)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.brandAmber)
                        Text("Download (\(downloadSizeMb) MB)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? LinearGradient(colors: [Color(red: 0x1E / 255.0, green: 0x2C / 255.0, blue: 0x46 / 255.0), Color(red: 0x14 / 255.0, green: 0x20 / 255.0, blue: 0x36 / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color(red: 0x0E / 255.0, green: 0x15 / 255.0, blue: 0x24 / 255.0), Color(red: 0x0A / 255.0, green: 0x10 / 255.0, blue: 0x1C / 255.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? SaysoPalette.brandAmber : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSelected ? SaysoPalette.brandAmber.opacity(0.25) : Color.black.opacity(0.3),
                radius: isSelected ? 6 : 3,
                x: 0,
                y: isSelected ? 2 : 1
            )
        }
        .buttonStyle(.plain)
    }
}

private typealias SaysoLanguageModelCard = SaysoSpokenLanguageModelWidget

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
                // Section: Transcription Mode (JustSpeakToIt Parity)
                SaysoCard {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TRANSCRIPTION MODE")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Text("Choose where and how speech is converted to text")
                                .font(.subheadline)
                                .foregroundStyle(SaysoPalette.muted)
                        }

                        // Location: Remote vs Local
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Where transcription runs")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Picker("Location", selection: Binding(
                                get: { model.settings.route == .byok ? 0 : 1 },
                                set: {
                                    model.settings.route = ($0 == 0 ? .byok : .local)
                                    model.save()
                                }
                            )) {
                                Text("Remote").tag(0)
                                Text("Local").tag(1)
                            }
                            .pickerStyle(.segmented)

                            Text(model.settings.route == .byok
                                ? "Remote: Fast, accurate cloud models (OpenAI, Groq)"
                                : "Local: Private on-device models, no internet required")
                                .font(.caption2)
                                .foregroundStyle(SaysoPalette.muted)
                        }

                        // Type: Streaming vs Batch
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transcription type")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Picker("Type", selection: Binding(
                                get: { model.settings.transcriptionExecutionMode == .streaming ? 0 : 1 },
                                set: {
                                    model.settings.transcriptionExecutionMode = ($0 == 0 ? .streaming : .batch)
                                    model.save()
                                }
                            )) {
                                Text("Streaming").tag(0)
                                Text("Batch").tag(1)
                            }
                            .pickerStyle(.segmented)

                            Text(model.settings.transcriptionExecutionMode == .streaming
                                ? "Streaming: Text appears in real-time as you speak"
                                : "Batch: Transcribed after you finish speaking (more accurate, no sentence butchering)")
                                .font(.caption2)
                                .foregroundStyle(SaysoPalette.muted)
                        }
                    }
                }

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
                                            Text(opt.speedBadge)
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
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(SaysoPalette.cobalt)
                                Text("Uses Apple Speech recognition framework built into macOS.")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.muted)
                            }

                            Toggle("Allow Apple Speech audio processing", isOn: Binding(
                                get: { model.settings.cloudConsentGranted },
                                set: {
                                    model.settings.cloudConsentGranted = $0
                                    model.save()
                                }
                            ))
                            .toggleStyle(.switch)
                            .accessibilityHint("Required before Apple Speech dictation can start")
                        }
                    }
                }

                // Section: Spoken Language & Model
                SaysoSectionHeader(text: "Spoken Language & Model")

                SaysoSpokenLanguageModelWidget(model: model)

                SaysoSwitchCard(
                    title: "Automatic language routing (Early LID)",
                    subtitle: "Uses Whisper neural detector to route Tamil, Hindi, or Malayalam to AI4Bharat and English to Parakeet",
                    isOn: $model.settings.autoLanguageRouting
                )

                // Section: Delivery & Text Insertion
                SaysoSectionHeader(text: "Delivery & Text Insertion")

                SaysoSettingItemCard(
                    title: "Insert final text (Automatic paste)",
                    description: "Pastes finalized text directly into your frontmost active application.",
                    example: "Cursor in Slack, Notes, or Terminal gets the transcribed text instantly."
                ) {
                    Toggle("", isOn: $model.settings.autoInsert).labelsHidden()
                }

                SaysoSettingItemCard(
                    title: "Insert partial text live in focused editors",
                    description: "Streams words only while the verified editable field, selection, process, and focus stay unchanged.",
                    example: "Words appear live in TextEdit and other accessible editors before you stop talking."
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

                SaysoSettingItemCard(
                    title: "Translate final text",
                    description: "Automatically translates your transcribed words into another language.",
                    example: "Speak in French or Hindi -> text is delivered in English."
                ) {
                    Toggle("", isOn: $model.settings.translationEnabled).labelsHidden()
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
                                HStack(spacing: 8) {
                                    Text(language.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    let modelName = LocalModelCatalog.recommendedModel(for: language).displayName
                                    Text(modelName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(SaysoPalette.brandAmber)
                                }
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
                        if isSelected {
                            HStack(spacing: 5) {
                                Circle().fill(SaysoPalette.brandAmber).frame(width: 7, height: 7)
                                Text("In Use")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(SaysoPalette.brandAmber)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SaysoPalette.brandAmber.opacity(0.15), in: Capsule())
                        } else {
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
                        }
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
                    if isSelected {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Text("Active for AI Cleanup · Rewriting transcripts privately")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Spacer()
                        }
                        .padding(10)
                        .background(SaysoPalette.brandAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1)
                        )
                    } else {
                        HStack {
                            Text("Model installed on disk")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                            Spacer()
                            Button("Use for AI Cleanup", action: onSelect)
                                .buttonStyle(.borderedProminent)
                                .tint(SaysoPalette.brandCobalt)
                                .font(.caption.weight(.bold))
                        }
                        .padding(8)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 10))
                    }
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

private struct SaysoProviderPill: View {
    let name: String
    let isSelected: Bool
    let speedHint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(name)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : SaysoPalette.muted)
                if let speedHint {
                    Text(speedHint)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted.opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SaysoCloudModelRowCard: View {
    let model: CloudModelOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)

                        Text(model.speedBadge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                model.isFast ? Color.yellow.opacity(0.2) : (model.tags.contains(where: { $0.contains("Reasoning") }) ? Color.purple.opacity(0.2) : Color.teal.opacity(0.2)),
                                in: Capsule()
                            )
                            .foregroundStyle(
                                model.isFast ? Color.yellow : (model.tags.contains(where: { $0.contains("Reasoning") }) ? Color.purple : Color.teal)
                            )

                        if model.isRecommended {
                            Text("Recommended")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SaysoPalette.cobalt.opacity(0.18), in: Capsule())
                                .foregroundStyle(SaysoPalette.cobalt)
                        }
                    }

                    Text(model.summary)
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(model.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(SaysoPalette.brandNavyWell, in: Capsule())
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()

                if isSelected {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                        Text("Active")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(SaysoPalette.brandAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SaysoPalette.brandAmber.opacity(0.15), in: Capsule())
                } else {
                    Text("Select")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SaysoPalette.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SaysoPalette.brandNavyWell, in: Capsule())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? SaysoPalette.brandAmber.opacity(0.8) : SaysoPalette.brandNavyContainer, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
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
                            model.settings.byokCleanupBaseURL = p.defaultBaseURL
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
                                Text(opt.speedBadge)
                            }
                            .tag(opt.id)
                        }
                    }
                    .labelsHidden()
                }

                if currentProvider.id == "custom" {
                    TextField("Base URL", text: $model.settings.byokCleanupBaseURL)
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
                .foregroundStyle(.white)

            SaysoCard {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Canonical Word / Target Output")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.muted)
                        TextField("e.g. Kubernetes, TypeScript", text: $word)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spoken Phonetic Trigger")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.muted)
                        TextField("e.g. koober-netties", text: $pronunciation)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional Replacement Text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.muted)
                        TextField("Leave blank to use canonical word", text: $replacement)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                            .foregroundStyle(.white)
                    }

                    HStack {
                        Text("Category")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.muted)
                        Spacer()
                        Picker("Category", selection: $category) {
                            ForEach(PronunciationCategory.allCases) { cat in
                                Text(cat.displayName).tag(cat)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().background(SaysoPalette.brandNavyContainer)

                    Toggle("Match as regular expression", isOn: $isRegex)
                        .font(.caption)
                    Toggle("Case sensitive matching", isOn: $caseSensitive)
                        .font(.caption)
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
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
                .tint(SaysoPalette.brandAmber)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 440, minHeight: 380)
        .padding(20)
        .background(SaysoPalette.brandNavyDark)
    }
}

private struct SaysoActivePipelineSummaryCard: View {
    @ObservedObject var model: SaysoAppModel

    private var activeDictationName: String {
        switch model.settings.route {
        case .appleSpeech:
            return "Apple Speech"
        case .byok:
            let provider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId)
            let modelOption = provider?.transcriptionModels.first { $0.id == model.settings.selectedCloudModelId }
            return "\(provider?.displayName ?? "Cloud") / \(modelOption?.displayName ?? model.settings.selectedCloudModelId)"
        case .local:
            if let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId),
               manifest.supports(model.settings.language) {
                return manifest.displayName
            }
            return LocalModelCatalog.recommendedModel(for: model.settings.language).displayName
        }
    }

    private var activeDictationSize: String {
        switch model.settings.route {
        case .appleSpeech:
            return "Built-in"
        case .byok:
            return "Cloud API"
        case .local:
            if let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId),
               manifest.supports(model.settings.language) {
                return "\(manifest.expectedSizeBytes / 1_000_000) MB"
            }
            let rec = LocalModelCatalog.recommendedModel(for: model.settings.language)
            return "\(rec.expectedSizeBytes / 1_000_000) MB"
        }
    }

    private var activeDictationSpeedBadge: String {
        switch model.settings.route {
        case .appleSpeech:
            return "⚡ Instant"
        case .byok:
            let provider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId)
            let opt = provider?.transcriptionModels.first { $0.id == model.settings.selectedCloudModelId }
            return opt?.speedBadge ?? "⚡ Fast"
        case .local:
            if let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId),
               manifest.supports(model.settings.language) {
                if manifest.expectedSizeBytes < 150_000_000 { return "⚡ Instant (50ms)" }
                if manifest.expectedSizeBytes < 300_000_000 { return "⚡ Fast (180ms)" }
                return "🎯 Accurate (220ms)"
            }
            return "⚡ Fast"
        }
    }

    private var activeDictationRouteBadge: String {
        switch model.settings.route {
        case .appleSpeech: return "Apple Native"
        case .byok: return "Cloud BYOK"
        case .local: return "On-Device Neural"
        }
    }

    private var activeDictationSummary: String {
        switch model.settings.route {
        case .appleSpeech:
            return "macOS native on-device speech recognition framework."
        case .byok:
            return "Audio is streamed to cloud provider using your API key."
        case .local:
            if let manifest = LocalModelCatalog.model(id: model.settings.selectedLocalAsrModelId),
               manifest.supports(model.settings.language) {
                return manifest.summary
            }
            return LocalModelCatalog.recommendedModel(for: model.settings.language).summary
        }
    }

    private var activeCleanupName: String {
        switch model.settings.cleanupMode {
        case .rules:
            return "Rules Engine (No LLM)"
        case .cloudLLM:
            let provider = CloudProviderCatalog.provider(for: model.settings.selectedCloudCleanupProviderId)
            let modelOption = provider?.cleanupModels.first { $0.id == model.settings.selectedCloudCleanupModelId }
            return "\(provider?.displayName ?? "Cloud") / \(modelOption?.displayName ?? model.settings.selectedCloudCleanupModelId)"
        case .localSLM:
            if let slm = LocalSlmCatalog.find(id: model.settings.selectedLocalSlmModelId) {
                return slm.displayName
            }
            return LocalSlmCatalog.defaultSlm.displayName
        }
    }

    private var activeCleanupModeBadge: String {
        switch model.settings.cleanupMode {
        case .rules: return "Deterministic"
        case .cloudLLM: return "Cloud LLM"
        case .localSLM: return "On-Device SLM"
        }
    }

    private var activeCleanupSize: String {
        switch model.settings.cleanupMode {
        case .rules: return "0 MB"
        case .cloudLLM: return "Cloud API"
        case .localSLM:
            if let slm = LocalSlmCatalog.find(id: model.settings.selectedLocalSlmModelId) {
                return "\(slm.sizeDisplay) · \(slm.parameterCount)"
            }
            return LocalSlmCatalog.defaultSlm.sizeDisplay
        }
    }

    private var activeCleanupSpeedBadge: String {
        switch model.settings.cleanupMode {
        case .rules: return "⚡ Instant (<1ms)"
        case .cloudLLM:
            let provider = CloudProviderCatalog.provider(for: model.settings.selectedCloudCleanupProviderId)
            let opt = provider?.cleanupModels.first { $0.id == model.settings.selectedCloudCleanupModelId }
            return opt?.speedBadge ?? "🧠 Reasoning"
        case .localSLM:
            if let slm = LocalSlmCatalog.find(id: model.settings.selectedLocalSlmModelId) {
                return slm.latencyTier == .instant ? "⚡ Instant Polish" : "⚡ Fast Polish"
            }
            return "⚡ Instant Polish"
        }
    }

    private var activeCleanupSummary: String {
        switch model.settings.cleanupMode {
        case .rules:
            return "Zero memory punctuation, capitalization, and formatting without AI."
        case .cloudLLM:
            return "Context-aware intelligence, tone, and grammar via cloud provider."
        case .localSLM:
            if let slm = LocalSlmCatalog.find(id: model.settings.selectedLocalSlmModelId) {
                return slm.summary
            }
            return LocalSlmCatalog.defaultSlm.summary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ACTIVE PIPELINE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SaysoPalette.brandAmber)
                    .tracking(1.0)
                Spacer()
                Text("Language: \(model.settings.language.displayName)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(SaysoPalette.muted)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                // STT Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform.badge.mic")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                        Text("Speech Dictation (STT)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SaysoPalette.muted)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(SaysoPalette.emerald).frame(width: 6, height: 6)
                            Text("Active")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SaysoPalette.emerald)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SaysoPalette.emerald.opacity(0.15), in: Capsule())
                    }

                    Text(activeDictationName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(activeDictationRouteBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SaysoPalette.cobalt.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(SaysoPalette.cobalt)

                        Text(activeDictationSize)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color(white: 0.85))

                        Text(activeDictationSpeedBadge)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.yellow)
                    }

                    Text(activeDictationSummary)
                        .font(.caption2)
                        .foregroundStyle(SaysoPalette.muted)
                        .lineLimit(2)
                }
                .padding(14)
                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SaysoPalette.brandAmber.opacity(0.4), lineWidth: 1)
                )

                // SLM / Cleanup Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "cpu.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(SaysoPalette.brandCobalt)
                        Text("Post-Processing (Cleanup)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SaysoPalette.muted)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(model.settings.cleanupMode == .rules ? SaysoPalette.muted : SaysoPalette.emerald).frame(width: 6, height: 6)
                            Text(model.settings.cleanupMode == .rules ? "Rules Only" : "Active")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(model.settings.cleanupMode == .rules ? SaysoPalette.muted : SaysoPalette.emerald)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((model.settings.cleanupMode == .rules ? SaysoPalette.muted : SaysoPalette.emerald).opacity(0.15), in: Capsule())
                    }

                    Text(activeCleanupName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(activeCleanupModeBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SaysoPalette.brandCobalt.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(SaysoPalette.brandCobalt)

                        Text(activeCleanupSize)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color(white: 0.85))

                        Text(activeCleanupSpeedBadge)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.teal)
                    }

                    Text(activeCleanupSummary)
                        .font(.caption2)
                        .foregroundStyle(SaysoPalette.muted)
                        .lineLimit(2)
                }
                .padding(14)
                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SaysoPalette.brandCobalt.opacity(0.4), lineWidth: 1)
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(SaysoPalette.brandNavySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1)
        )
    }
}

private struct SaysoModelGridCard: View {
    let manifest: LocalModelManifest
    let isActive: Bool
    let onSelect: () -> Void

    private var speedBadgeText: String {
        if manifest.expectedSizeBytes < 150_000_000 {
            return "⚡ Instant"
        } else if manifest.expectedSizeBytes < 300_000_000 {
            return "⚡ Fast"
        } else {
            return "🎯 Accurate"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Name + In Use dot
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(manifest.expectedSizeBytes / 1_000_000) MB · \(manifest.architecture.displayName)")
                        .font(.caption2)
                        .foregroundStyle(SaysoPalette.muted)
                }
                Spacer()
                if isActive {
                    HStack(spacing: 4) {
                        Circle().fill(SaysoPalette.brandAmber).frame(width: 7, height: 7)
                        Text("In Use")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SaysoPalette.brandAmber.opacity(0.15), in: Capsule())
                }
            }

            // Badges row
            HStack(spacing: 6) {
                if manifest.isRecommended {
                    Text("Recommended")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SaysoPalette.cobalt.opacity(0.2), in: Capsule())
                        .foregroundStyle(SaysoPalette.cobalt)
                }
                Text(speedBadgeText)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.yellow)

                Text(manifest.license.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(Color(white: 0.8))
            }

            // Summary
            Text(manifest.summary)
                .font(.caption)
                .foregroundStyle(SaysoPalette.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

            Spacer(minLength: 4)

            // Action button or Active indicator
            if isActive {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                    Text("Active for Dictation")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(SaysoPalette.brandAmber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(SaysoPalette.brandAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1))
            } else {
                Button(action: onSelect) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                        Text("Use for Dictation")
                            .font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(
            isActive ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isActive ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                    lineWidth: isActive ? 1.5 : 1
                )
        )
    }
}

private struct SaysoSlmGridCard: View {
    let slm: LocalSlmManifest
    let isActive: Bool
    let status: LocalSlmState
    let progress: Double?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Name + Active / Installed badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slm.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(slm.parameterCount) params · \(slm.sizeDisplay) · GGUF")
                        .font(.caption2)
                        .foregroundStyle(SaysoPalette.muted)
                }
                Spacer()
                if isActive {
                    HStack(spacing: 4) {
                        Circle().fill(SaysoPalette.brandAmber).frame(width: 7, height: 7)
                        Text("In Use")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SaysoPalette.brandAmber.opacity(0.15), in: Capsule())
                } else if status.isInstalled {
                    Text("Installed")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SaysoPalette.emerald)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SaysoPalette.emerald.opacity(0.15), in: Capsule())
                }
            }

            // Tags row
            HStack(spacing: 6) {
                ForEach(slm.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tag.contains("⚡") ? Color.yellow.opacity(0.15) : (tag == "Recommended" ? SaysoPalette.cobalt.opacity(0.2) : Color.white.opacity(0.08)), in: Capsule())
                        .foregroundStyle(tag.contains("⚡") ? Color.yellow : (tag == "Recommended" ? SaysoPalette.cobalt : Color(white: 0.85)))
                }
            }

            // Summary
            Text(slm.summary)
                .font(.caption)
                .foregroundStyle(SaysoPalette.muted)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

            Spacer(minLength: 4)

            // Action area
            if status.isInstalled {
                HStack(spacing: 8) {
                    if isActive {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                            Text("Active for AI Cleanup")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(SaysoPalette.brandAmber)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(SaysoPalette.brandAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandAmber.opacity(0.3), lineWidth: 1))
                    } else {
                        Button(action: onSelect) {
                            HStack(spacing: 6) {
                                Image(systemName: "cpu.fill")
                                    .font(.caption)
                                Text("Use for AI Cleanup")
                                    .font(.caption.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(SaysoPalette.brandCobalt, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.crimson)
                            .padding(7)
                            .background(SaysoPalette.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete model from disk")
                }
            } else if case .installing = status {
                let currentProgress = max(0.05, progress ?? 0.05)
                let pct = Int(currentProgress * 100)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading \(pct)%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                    ProgressView(value: currentProgress)
                        .tint(SaysoPalette.brandAmber)
                }
                .padding(.vertical, 4)
            } else {
                Button(action: onDownload) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption.weight(.bold))
                        Text("Download (\(slm.sizeDisplay))")
                            .font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(SaysoPalette.blueButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(
            isActive ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isActive ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                    lineWidth: isActive ? 1.5 : 1
                )
        )
    }
}

private struct ModelsWorkspace: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject private var localEnglishModel: FluidAudioLocalModelManager
    @ObservedObject private var localPunjabiModel: SherpaPunjabiModelManager
    @State private var selectedCategory = 0
    @State private var sttApiKey = ""
    @State private var cleanupApiKey = ""
    @State private var showSttKey = false
    @State private var showCleanupKey = false

    init(model: SaysoAppModel) {
        self.model = model
        _localEnglishModel = ObservedObject(wrappedValue: model.localEnglishModel)
        _localPunjabiModel = ObservedObject(wrappedValue: model.localPunjabiModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Prominent Hero Active Pipeline Summary Card
                SaysoActivePipelineSummaryCard(model: model)

                // Neomorphic Category Switcher
                HStack(spacing: 10) {
                    categoryTabButton(title: "On-Device Speech", icon: "waveform", tag: 0)
                    categoryTabButton(title: "On-Device SLMs", icon: "cpu", tag: 1)
                    categoryTabButton(title: "Cloud Providers & BYOK", icon: "cloud.fill", tag: 2)
                }

                switch selectedCategory {
                case 0:
                    onDeviceSpeechSection
                case 1:
                    onDeviceSlmSection
                default:
                    cloudProvidersSection
                }
            }
            .padding(20)
        }
        .background(SaysoPalette.brandNavyDark)
        .navigationTitle("Models & Downloads")
        .onChange(of: model.settings) { _, _ in model.save() }
    }

    @ViewBuilder
    private func categoryTabButton(title: String, icon: String, tag: Int) -> some View {
        let isSelected = selectedCategory == tag
        Button {
            selectedCategory = tag
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted)
                Text(title)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : SaysoPalette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var onDeviceSpeechSection: some View {
        SaysoSectionHeader(text: "Speech Route")

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

        SaysoSectionHeader(text: "High-Accuracy Batch Models (Apple Silicon Core ML / WhisperKit)")

        // WhisperKit Large v3 Turbo (Image 3 Parity)
        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("WhisperKit Large v3 Turbo")
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                            Text("★ Recommended")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.orange)
                            Text("Apple Neural Engine")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SaysoPalette.cobalt.opacity(0.2), in: Capsule())
                                .foregroundStyle(SaysoPalette.cobalt)
                        }
                        Text("High-accuracy Whisper Large v3 Turbo Core ML model (632 MB) on Apple Silicon. Recommended for batch transcription.")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                    Text("Installed")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SaysoPalette.emerald)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("COMPUTE UNITS").font(.caption2.weight(.bold)).foregroundStyle(SaysoPalette.muted)
                        Text("Neural Engine + GPU").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                    Divider().frame(height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ESTIMATED MEMORY").font(.caption2.weight(.bold)).foregroundStyle(SaysoPalette.muted)
                        Text("≈ 1.2 GB RAM").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                    Divider().frame(height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SPEED (RTFX)").font(.caption2.weight(.bold)).foregroundStyle(SaysoPalette.muted)
                        Text("≈ 4.2x real-time").font(.caption.weight(.semibold)).foregroundStyle(SaysoPalette.emerald)
                    }
                    Spacer()
                }
                .padding(10)
                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
            }
        }

        SaysoSectionHeader(text: "Native Streaming Models (Apple Silicon CoreML)")

        // English FluidAudio
        SaysoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(FluidAudioLocalModelManager.displayName).fontWeight(.semibold).foregroundStyle(.white)
                            Text("⚡ Instant (50ms)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.yellow.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.yellow)
                            if localEnglishModel.state.isInstalled && model.settings.route == .local && model.settings.language == .english {
                                Text("Active Engine")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(SaysoPalette.cobalt.opacity(0.2), in: Capsule())
                                    .foregroundStyle(SaysoPalette.cobalt)
                            }
                        }
                        Text("On-device English streaming. Apple silicon only. 430 MB.")
                            .font(.caption).foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                    Text(localModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localEnglishModel.state.isInstalled ? SaysoPalette.emerald : SaysoPalette.muted)
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
                            .tint(SaysoPalette.brandCobalt)
                            .font(.caption)
                    }
                    Spacer()
                }
            }
        }

        // Indian Language FluidAudio
        SaysoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(FluidAudioLocalModelManager.multilingualDisplayName).fontWeight(.semibold).foregroundStyle(.white)
                            Text("⚡ Fast (180ms)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.teal.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.teal)
                        }
                        Text("Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Telugu and Urdu. 1.5 GB.")
                            .font(.caption).foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                    Text(multilingualModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localEnglishModel.multilingualState.isInstalled ? SaysoPalette.emerald : SaysoPalette.muted)
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
                            .tint(SaysoPalette.brandCobalt)
                            .font(.caption)
                    }
                    Spacer()
                }
            }
        }

        SaysoSectionHeader(text: "Offline Indic & Sherpa-ONNX Catalog")

        // Punjabi Model
        SaysoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(SherpaPunjabiModelManager.displayName).fontWeight(.semibold).foregroundStyle(.white)
                            Text("⚡ Fast").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.teal.opacity(0.2), in: Capsule()).foregroundStyle(Color.teal)
                            Text("★ Best for Punjabi").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(Color.orange)
                        }
                        Text("Offline Punjabi final transcription. Apache-2.0. 198 MB.")
                            .font(.caption).foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                    Text(punjabiModelStatus)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localPunjabiModel.state.isInstalled ? SaysoPalette.emerald : SaysoPalette.muted)
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
                            .tint(SaysoPalette.brandCobalt)
                            .font(.caption)
                    }
                    Spacer()
                }
            }
        }

        // Offline Sherpa-ONNX Speech Models (Clustered 2-column Grid)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(LocalModelCatalog.all) { manifest in
                SaysoModelGridCard(
                    manifest: manifest,
                    isActive: manifest.id == model.settings.selectedLocalAsrModelId && model.settings.route == .local,
                    onSelect: {
                        model.settings.selectedLocalAsrModelId = manifest.id
                        model.settings.route = .local
                        if let singleLang = manifest.supportedLanguages.first, manifest.supportedLanguages.count == 1 {
                            model.settings.language = singleLang
                        }
                        model.save()
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var onDeviceSlmSection: some View {
        SaysoSectionHeader(text: "On-Device Small Language Models")

        SaysoCard {
            HStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.title2)
                    .foregroundStyle(SaysoPalette.brandAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zero Network Polish")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Small Language Models (SLMs) run locally on Apple Neural Engine and CPU. They polish transcripts, format lists, and fix grammar without sending text to any cloud server.")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.muted)
                }
            }
        }

        SaysoSectionHeader(text: "Local SLM Catalog (Qwen & SmolLM)")

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(LocalSlmCatalog.all) { slm in
                SaysoSlmGridCard(
                    slm: slm,
                    isActive: model.settings.cleanupMode == .localSLM && model.settings.selectedLocalSlmModelId == slm.id,
                    status: model.checkSlmStatus(slm),
                    progress: model.slmDownloadProgress[slm.id],
                    onSelect: {
                        model.settings.selectedLocalSlmModelId = slm.id
                        model.settings.cleanupMode = .localSLM
                        model.save()
                    },
                    onDownload: {
                        Task { await model.installSlm(slm) }
                    },
                    onDelete: {
                        model.deleteSlm(slm)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var cloudProvidersSection: some View {
        let sttProviders = CloudProviderCatalog.transcriptionProviders
        let currentSttProvider = CloudProviderCatalog.provider(for: model.settings.selectedCloudProviderId) ?? CloudProviderCatalog.saysoCloud

        let cleanupProviders = CloudProviderCatalog.cleanupProviders
        let currentCleanupProvider = CloudProviderCatalog.provider(for: model.settings.selectedCloudCleanupProviderId) ?? CloudProviderCatalog.groq

        // Speech-to-Text (STT) Cloud BYOK
        SaysoSectionHeader(text: "Speech-to-Text (STT) Cloud BYOK")

        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Cloud STT Provider")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Audio is streamed directly to this provider when Speech Route is set to Cloud LLM / ASR.")
                    .font(.caption)
                    .foregroundStyle(SaysoPalette.muted)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sttProviders) { p in
                            let hint = p.speedHint
                            SaysoProviderPill(
                                name: p.displayName,
                                isSelected: model.settings.selectedCloudProviderId == p.id,
                                speedHint: hint
                            ) {
                                model.settings.selectedCloudProviderId = p.id
                                model.settings.byokBaseURL = p.defaultBaseURL
                                if let first = p.transcriptionModels.first {
                                    model.settings.selectedCloudModelId = first.id
                                    model.settings.byokTranscriptionModel = first.id
                                }
                                model.save()
                            }
                        }
                    }
                }
            }
        }

        SaysoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(currentSttProvider.displayName) STT Configuration")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Default endpoint: \(currentSttProvider.defaultBaseURL)")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                    if let url = currentSttProvider.apiKeyURL {
                        Link("Get API Key ↗", destination: url)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Base URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SaysoPalette.muted)
                    HStack {
                        TextField("API Base URL", text: $model.settings.byokBaseURL)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                            .foregroundStyle(.white)

                        if model.settings.byokBaseURL != currentSttProvider.defaultBaseURL {
                            Button("Reset") {
                                model.settings.byokBaseURL = currentSttProvider.defaultBaseURL
                                model.save()
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }

                // STT API Key
                let hasSttKey = model.hasKey(for: currentSttProvider)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            hasSttKey ? "API Key stored securely in Keychain" : "No API key stored for \(currentSttProvider.displayName)",
                            systemImage: hasSttKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hasSttKey ? SaysoPalette.emerald : SaysoPalette.amber)

                        Spacer()

                        if hasSttKey && currentSttProvider.id != "ollama" {
                            Button("Remove key", role: .destructive) {
                                model.removeProviderKey(for: currentSttProvider)
                            }
                            .font(.caption)
                        }
                    }

                    if currentSttProvider.id != "ollama" {
                        HStack(spacing: 8) {
                            Group {
                                if showSttKey {
                                    TextField("Enter \(currentSttProvider.displayName) API key...", text: $sttApiKey)
                                } else {
                                    SecureField("Enter \(currentSttProvider.displayName) API key...", text: $sttApiKey)
                                }
                            }
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))

                            Button {
                                showSttKey.toggle()
                            } label: {
                                Image(systemName: showSttKey ? "eye.slash" : "eye")
                                    .foregroundStyle(SaysoPalette.muted)
                                    .frame(width: 32, height: 32)
                                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            Button("Save Key") {
                                if model.saveProviderKey(sttApiKey, for: currentSttProvider) {
                                    sttApiKey = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.brandAmber)
                            .disabled(sttApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }

        SaysoSectionHeader(text: "\(currentSttProvider.displayName) STT Models")

        if !currentSttProvider.transcriptionModels.isEmpty {
            VStack(spacing: 8) {
                ForEach(currentSttProvider.transcriptionModels) { opt in
                    SaysoCloudModelRowCard(
                        model: opt,
                        isSelected: model.settings.selectedCloudModelId == opt.id
                    ) {
                        model.settings.selectedCloudModelId = opt.id
                        model.settings.byokTranscriptionModel = opt.id
                        model.save()
                    }
                }
            }
        } else {
            SaysoCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom STT Model Identifier")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SaysoPalette.muted)
                    TextField("e.g. whisper-large-v3", text: $model.settings.byokTranscriptionModel)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                }
            }
        }

        // AI Cleanup & Formatting (LLM) Cloud BYOK
        SaysoSectionHeader(text: "AI Cleanup & Formatting (LLM) BYOK")

        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Cloud Cleanup LLM Provider")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Polishes text, removes fillers, and formats paragraphs without altering your STT provider.")
                    .font(.caption)
                    .foregroundStyle(SaysoPalette.muted)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cleanupProviders) { p in
                            let hint: String? = {
                                if p.id == "groq" { return "⚡ ~110ms" }
                                if p.id == "anthropic" { return "🎯 ~290ms" }
                                if p.id == "deepseek" { return "🧠 ~350ms" }
                                if p.id == "openai" { return "⚡ ~320ms" }
                                if p.id == "ollama" { return "Offline" }
                                return nil
                            }()
                            SaysoProviderPill(
                                name: p.displayName,
                                isSelected: model.settings.selectedCloudCleanupProviderId == p.id,
                                speedHint: hint
                            ) {
                                model.settings.selectedCloudCleanupProviderId = p.id
                                model.settings.byokCleanupBaseURL = p.defaultBaseURL
                                if let first = p.cleanupModels.first {
                                    model.settings.selectedCloudCleanupModelId = first.id
                                    model.settings.byokCleanupModel = first.id
                                }
                                model.save()
                            }
                        }
                    }
                }
            }
        }

        SaysoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(currentCleanupProvider.displayName) LLM Configuration")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Default endpoint: \(currentCleanupProvider.defaultBaseURL)")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                    if let url = currentCleanupProvider.apiKeyURL {
                        Link("Get API Key ↗", destination: url)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SaysoPalette.brandAmber)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Base URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SaysoPalette.muted)
                    HStack {
                        TextField("API Base URL", text: $model.settings.byokCleanupBaseURL)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                            .foregroundStyle(.white)

                        if model.settings.byokCleanupBaseURL != currentCleanupProvider.defaultBaseURL {
                            Button("Reset") {
                                model.settings.byokCleanupBaseURL = currentCleanupProvider.defaultBaseURL
                                model.save()
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }

                // Cleanup API Key
                let hasCleanupKey = model.hasKey(for: currentCleanupProvider)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            hasCleanupKey ? "API Key stored securely in Keychain" : (currentCleanupProvider.id == "ollama" ? "Local server (no API key required)" : "No API key stored for \(currentCleanupProvider.displayName)"),
                            systemImage: hasCleanupKey ? "checkmark.seal.fill" : (currentCleanupProvider.id == "ollama" ? "server.rack" : "exclamationmark.triangle.fill")
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hasCleanupKey ? SaysoPalette.emerald : (currentCleanupProvider.id == "ollama" ? SaysoPalette.cobalt : SaysoPalette.amber))

                        Spacer()

                        if hasCleanupKey && currentCleanupProvider.id != "ollama" {
                            Button("Remove key", role: .destructive) {
                                model.removeProviderKey(for: currentCleanupProvider)
                            }
                            .font(.caption)
                        }
                    }

                    if currentCleanupProvider.id != "ollama" {
                        HStack(spacing: 8) {
                            Group {
                                if showCleanupKey {
                                    TextField("Enter \(currentCleanupProvider.displayName) API key...", text: $cleanupApiKey)
                                } else {
                                    SecureField("Enter \(currentCleanupProvider.displayName) API key...", text: $cleanupApiKey)
                                }
                            }
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))

                            Button {
                                showCleanupKey.toggle()
                            } label: {
                                Image(systemName: showCleanupKey ? "eye.slash" : "eye")
                                    .foregroundStyle(SaysoPalette.muted)
                                    .frame(width: 32, height: 32)
                                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            Button("Save Key") {
                                if model.saveProviderKey(cleanupApiKey, for: currentCleanupProvider) {
                                    cleanupApiKey = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SaysoPalette.brandAmber)
                            .disabled(cleanupApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }

        SaysoSectionHeader(text: "\(currentCleanupProvider.displayName) Cleanup Models")

        if !currentCleanupProvider.cleanupModels.isEmpty {
            VStack(spacing: 8) {
                ForEach(currentCleanupProvider.cleanupModels) { opt in
                    SaysoCloudModelRowCard(
                        model: opt,
                        isSelected: model.settings.selectedCloudCleanupModelId == opt.id
                    ) {
                        model.settings.selectedCloudCleanupModelId = opt.id
                        model.settings.byokCleanupModel = opt.id
                        model.save()
                    }
                }
            }
        } else {
            SaysoCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Cleanup Model Identifier")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SaysoPalette.muted)
                    TextField("e.g. gpt-4o-mini", text: $model.settings.byokCleanupModel)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                }
            }
        }

        // Advanced Overrides
        SaysoSectionHeader(text: "Advanced Routing Overrides")

        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Translation Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SaysoPalette.muted)
                    TextField("e.g. gpt-4o-mini", text: $model.settings.byokTranslationModel)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Edit Rewrite Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SaysoPalette.muted)
                    TextField("e.g. gpt-4.1-mini", text: $model.settings.byokRewriteModel)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1))
                        .foregroundStyle(.white)
                }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Section 1: Spoken Language & Neural Model (Android Parity Widget)
                SaysoSectionHeader(text: "Spoken Language & Model")
                SaysoSpokenLanguageModelWidget(model: model)

                // Section 2: Workspaces & Dedicated Pipelines
                SaysoSectionHeader(text: "Workspaces & Dedicated Pipelines")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    workspaceLinkCard(
                        title: "Transcription & Delivery",
                        subtitle: "Routes, auto-paste, live partial insertion & cues",
                        icon: "mic.badge.waveform",
                        tab: 3
                    )
                    workspaceLinkCard(
                        title: "Models & Downloads",
                        subtitle: "On-device neural models, SLMs & Cloud BYOK",
                        icon: "square.stack.3d.up.fill",
                        tab: 4
                    )
                    workspaceLinkCard(
                        title: "AI Cleanup & SLM",
                        subtitle: "Qwen 0.5B local cleanup, punctuation & grammar",
                        icon: "sparkles",
                        tab: 5
                    )
                    workspaceLinkCard(
                        title: "Desktop Control & Jev",
                        subtitle: "Hands-free Mac control & TypeSafe / Jev API",
                        icon: "cursorarrow.click",
                        tab: 1
                    )
                    workspaceLinkCard(
                        title: "Notch & HUD Style",
                        subtitle: "Notch pill, floating HUD, and visual behaviors",
                        icon: "menubar.rectangle",
                        tab: 7
                    )
                    workspaceLinkCard(
                        title: "Shortcuts & Hotkeys",
                        subtitle: "Global keys, tap-to-talk, hold threshold",
                        icon: "keyboard",
                        tab: 8
                    )
                    workspaceLinkCard(
                        title: "Vocabulary & Dictionary",
                        subtitle: "Acoustic bias words, learned rules & replacements",
                        icon: "character.book.closed",
                        tab: 6
                    )
                    workspaceLinkCard(
                        title: "Voice Output (TTS)",
                        subtitle: "Spoken feedback, system voices, speech rate",
                        icon: "speaker.wave.2",
                        tab: 9
                    )
                }

                // Section 3: Setup & Onboarding Tour
                SaysoSectionHeader(text: "Setup & Onboarding")
                SaysoCard {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.title2)
                            .foregroundStyle(SaysoPalette.brandAmber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Replay Onboarding Tour")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Review primary language, on-device models, AI cleanup, and test dictation.")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                        }
                        Spacer()
                        Button(action: {
                            model.isShowingOnboardingWizard = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption.weight(.bold))
                                Text("Launch Tour")
                                    .font(.caption.weight(.bold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(SaysoPalette.blueButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Section 4: App Profile Overrides
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

                // Section 4: Privacy & Permissions
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
                    title: "Watch the clipboard (off by default)",
                    description: "When on, Sayso checks your clipboard twice a second to keep a short in-memory list of text you copy and to offer to clean tracking links. Items that password managers mark as private are skipped. Nothing is saved to disk or sent anywhere.",
                    example: "Copy a link with tracking parameters and the notch offers Clean."
                ) {
                    Toggle("Watch the clipboard", isOn: $model.settings.clipboardModuleEnabled)
                        .labelsHidden()
                        .accessibilityIdentifier("settings-clipboard-toggle")
                }
                SaysoSettingItemCard(
                    title: "File shelf (off by default)",
                    description: "When on, you can keep up to \(FileShelfModule.defaultLimit) files or folders on a shelf, shown in the notch, and reveal them in Finder later; adding more drops the oldest. Files stay where they are and are never copied or uploaded. Every few seconds Sayso checks that shelved files still exist and drops any that moved or were deleted. The shelf lives only in memory: it is cleared when Sayso quits, and turning this off clears it.",
                    example: "Add a screenshot here, then reveal it in Finder when you need it."
                ) {
                    Toggle("File shelf", isOn: $model.settings.fileShelfEnabled)
                        .labelsHidden()
                        .accessibilityIdentifier("settings-file-shelf-toggle")
                }
                if model.settings.fileShelfEnabled {
                    fileShelfCard
                }

                // Section 5: Reset & Maintenance
                SaysoSectionHeader(text: "Reset & Maintenance")
                SaysoCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keyboard Shortcuts")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Restores dictation, control, and notch hotkeys to default bindings")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                            Spacer()
                            Button("Reset Shortcuts") {
                                model.resetShortcutsToDefaults()
                            }
                            .buttonStyle(.bordered)
                            .tint(SaysoPalette.brandAmber)
                            .font(.caption)
                        }

                        Divider().background(SaysoPalette.brandNavyContainer)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Factory Reset All Settings")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Reverts all preferences, routes, and custom dictionaries back to defaults")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                            Spacer()
                            Button("Reset All Settings", role: .destructive) {
                                model.settings = SaysoSettings()
                                model.save()
                            }
                            .buttonStyle(.bordered)
                            .tint(SaysoPalette.crimson)
                            .font(.caption)
                        }

                        Divider().background(SaysoPalette.brandNavyContainer)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sayso macOS")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Version 1.0.0 (On-Device Neural Engine)")
                                    .font(.caption)
                                    .foregroundStyle(SaysoPalette.muted)
                            }
                            Spacer()
                            Text("Ready")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.emerald)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(SaysoPalette.emerald.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(SaysoPalette.brandNavyDark)
        .navigationTitle("Settings")
        .onChange(of: model.settings) { _, _ in model.save() }
    }

    @ViewBuilder
    private func workspaceLinkCard(title: String, subtitle: String, icon: String, tab: Int) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(SaysoPalette.brandAmber)
                    .frame(width: 32, height: 32)
                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(SaysoPalette.muted)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SaysoPalette.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var fileShelfCard: some View {
        SaysoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.fileShelfItems.isEmpty ? "The shelf is empty" : "On the shelf")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Add files\u{2026}") { chooseFilesForShelf() }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .accessibilityIdentifier("settings-file-shelf-add")
                }
                ForEach(model.fileShelfItems) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(SaysoPalette.muted)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !item.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(SaysoPalette.muted)
                        }
                        Spacer()
                        Button("Reveal") { model.revealOnFileShelf(item.id) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .accessibilityLabel("Reveal \(item.name) in Finder")
                        Button("Remove") { model.removeFromFileShelf(item.id) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .accessibilityLabel("Remove \(item.name) from the shelf")
                    }
                }
            }
        }
    }

    private func chooseFilesForShelf() {
        let panel = NSOpenPanel()
        panel.title = "Add to File Shelf"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.addToFileShelf(panel.urls)
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
                _ = await appendToHistory(final)
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
    @State private var showOtherModelsDialog = false
    @Environment(\.dismiss) private var dismiss

    private let stepTitles = [
        "Language & Script",
        "Speech Engine",
        "AI Cleanup & Polish",
        "Permissions & Test"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Top Header: Logo + Title + Step Indicator + Finish Later
            headerView
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

            // Step Progress Bars (4 segments)
            progressBarView
                .padding(.horizontal, 28)
                .padding(.bottom, 18)

            Divider()
                .background(SaysoPalette.brandNavyContainer)

            // Scrollable Content per Step
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case 0:
                        StepZeroLanguagesView(model: model)
                    case 1:
                        StepOneSttEngineView(
                            model: model,
                            onOpenOtherModels: { showOtherModelsDialog = true }
                        )
                    case 2:
                        StepTwoPostProcessingView(model: model)
                    case 3:
                        StepThreePermissionsView(model: model)
                    default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(SaysoPalette.brandNavyContainer)

            // Bottom Navigation Bar
            bottomBarView
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(SaysoPalette.brandNavyDark)
        }
        .frame(width: 720, height: 680)
        .background(SaysoPalette.brandNavyBase)
        .sheet(isPresented: $showOtherModelsDialog) {
            otherModelsSheet
        }
        .onAppear {
            model.clearOnboardingTestResult()
            if model.settings.language == .automatic {
                model.settings.language = .english
                model.settings.selectedLocalAsrModelId = LocalModelCatalog.recommendedModel(for: .english).id
                model.save()
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 14) {
            // Sayso Bubble Gradient Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [SaysoPalette.brandCobalt, SaysoPalette.brandAmber],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: SaysoPalette.brandCobalt.opacity(0.35), radius: 6)

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Sayso")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("Step \(page + 1) of 4 · \(stepTitles[page])")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SaysoPalette.brandAmber)
            }

            Spacer()

            Button("Finish later") {
                deferSetup()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(SaysoPalette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var progressBarView: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(
                        index == page
                            ? SaysoPalette.brandAmber
                            : (index < page ? SaysoPalette.brandCobalt : SaysoPalette.brandNavyContainer)
                    )
                    .frame(height: 4)
                    .shadow(
                        color: index == page ? SaysoPalette.brandAmber.opacity(0.5) : .clear,
                        radius: 3
                    )
            }
        }
    }

    private var bottomBarView: some View {
        HStack {
            if page > 0 {
                Button(action: {
                    model.clearOnboardingTestResult()
                    page -= 1
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                            .font(.caption.weight(.bold))
                        Text("Back")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if page < 3 {
                Button(action: {
                    advanceStep()
                }) {
                    HStack(spacing: 6) {
                        Text(nextButtonTitle)
                            .font(.caption.weight(.bold))
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(SaysoPalette.blueButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    complete()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                        Text("Finish Setup")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(SaysoPalette.emerald, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var nextButtonTitle: String {
        "Continue"
    }

    private func advanceStep() {
        if page == 0 {
            let lang = model.settings.language
            let recModel = LocalModelCatalog.recommendedModel(for: lang)
            model.settings.selectedLocalAsrModelId = recModel.id
            model.settings.route = .local
            model.save()
        }
        page = min(3, page + 1)
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

    private var otherModelsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Select On-Device Speech Model")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") {
                    showOtherModelsDialog = false
                }
                .buttonStyle(.bordered)
            }
            Text("Choose any installed or available on-device model from the local catalog.")
                .font(.caption)
                .foregroundStyle(SaysoPalette.muted)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(LocalModelCatalog.all) { manifest in
                        let isSelected = model.settings.selectedLocalAsrModelId == manifest.id
                        Button(action: {
                            model.settings.selectedLocalAsrModelId = manifest.id
                            model.settings.route = .local
                            if let singleLang = manifest.supportedLanguages.first, manifest.supportedLanguages.count == 1 {
                                model.settings.language = singleLang
                            }
                            model.save()
                            showOtherModelsDialog = false
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(manifest.displayName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white)
                                        if manifest.isRecommended {
                                            Text("Recommended")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(SaysoPalette.brandCobalt.opacity(0.3), in: Capsule())
                                                .foregroundStyle(SaysoPalette.brandAmber)
                                        }
                                    }
                                    Text("\(manifest.summary) · \(manifest.expectedSizeBytes / 1_000_000) MB")
                                        .font(.caption)
                                        .foregroundStyle(SaysoPalette.muted)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(
                                isSelected ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        isSelected ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
        .background(SaysoPalette.brandNavyBase)
    }
}

private struct StepZeroLanguagesView: View {
    @ObservedObject var model: SaysoAppModel

    private struct PrimaryLanguageOption: Identifiable {
        let id: String
        let language: DictationLanguage
        let name: String
        let nativeScript: String
        let badge: String
        let isIndic: Bool
    }

    private let options = [
        PrimaryLanguageOption(
            id: "en",
            language: .english,
            name: "English",
            nativeScript: "English",
            badge: "★ Recommended for English (Parakeet 110M: fast, high accuracy)",
            isIndic: false
        ),
        PrimaryLanguageOption(
            id: "ta",
            language: .tamil,
            name: "Tamil",
            nativeScript: "தமிழ்",
            badge: "★ Recommended: AI4Bharat is superior for Tamil & Tanglish",
            isIndic: true
        ),
        PrimaryLanguageOption(
            id: "hi",
            language: .hindi,
            name: "Hindi",
            nativeScript: "हिंदी",
            badge: "★ Recommended: AI4Bharat is superior for Hindi & Hinglish",
            isIndic: true
        ),
        PrimaryLanguageOption(
            id: "ml",
            language: .malayalam,
            name: "Malayalam",
            nativeScript: "മലയാളം",
            badge: "★ Recommended: AI4Bharat is superior for Malayalam",
            isIndic: true
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Primary Language & Script")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Each language activates its dedicated on-device neural model.")
                    .font(.subheadline)
                    .foregroundStyle(SaysoPalette.muted)
            }

            // 4 Language Cards
            VStack(spacing: 8) {
                ForEach(options) { opt in
                    let isSelected = model.settings.language == opt.language
                    Button(action: {
                        model.settings.language = opt.language
                        let rec = LocalModelCatalog.recommendedModel(for: opt.language)
                        model.settings.selectedLocalAsrModelId = rec.id
                        model.save()
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(opt.name)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                    Text("(\(opt.nativeScript))")
                                        .font(.caption)
                                        .foregroundStyle(SaysoPalette.muted)
                                }
                                Text(opt.badge)
                                    .font(.caption2.weight(isSelected ? .bold : .medium))
                                    .foregroundStyle(
                                        isSelected && opt.isIndic
                                            ? SaysoPalette.brandAmber
                                            : SaysoPalette.muted
                                    )
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            isSelected ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isSelected ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // More Languages Box
            HStack(alignment: .top, spacing: 10) {
                Text("🌐").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("More languages in Transcription Settings")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Need Spanish, French, German, Italian, Portuguese, Japanese, or other languages? Select them in Transcription Settings using Whisper Multilingual or Cloud providers.")
                        .font(.caption2)
                        .foregroundStyle(SaysoPalette.muted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SaysoPalette.brandNavySurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(SaysoPalette.brandNavyContainer.opacity(0.5), lineWidth: 1)
            )

            // Transliteration Section for Indian Languages
            if model.settings.language.isIndic {
                transliterationSection
            }

            // Recommended Model Card
            recommendedModelCard
        }
    }

    private var transliterationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How should Indian text appear?")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Text("Choose whether your speech appears in English letters or native script.")
                .font(.caption)
                .foregroundStyle(SaysoPalette.muted)

            let isLatin = model.settings.transliterateIndicToLatin
            let targetName = model.settings.language.transliterationTarget
            let (exampleLatin, exampleNative): (String, String) = switch model.settings.language {
            case .hindi: ("Namaste, aap kaise hain?", "नमस्ते, आप कैसे हैं?")
            case .malayalam: ("Namaskaram, sugamano?", "നമസ്കാരം, സുഖമാണോ?")
            default: ("Vanakkam, eppadi irukkeenga?", "வணக்கம், எப்படி இருக்கீங்க?")
            }

            HStack(spacing: 10) {
                // Card 1: Latin letters (Tanglish / Hinglish / Manglish)
                Button(action: {
                    model.settings.transliterateIndicToLatin = true
                    model.save()
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: isLatin ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isLatin ? SaysoPalette.brandAmber : SaysoPalette.muted)
                            Text(targetName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        Text("English letters")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Example:")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Text("\"\(exampleLatin)\"")
                                .font(.caption.italic())
                                .foregroundStyle(.white)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        isLatin ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isLatin ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                                lineWidth: isLatin ? 1.5 : 1
                            )
                    )
                }
                .buttonStyle(.plain)

                // Card 2: Native Script
                Button(action: {
                    model.settings.transliterateIndicToLatin = false
                    model.save()
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: !isLatin ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(!isLatin ? SaysoPalette.brandAmber : SaysoPalette.muted)
                            Text("Native Script")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        Text("Original script")
                            .font(.caption2)
                            .foregroundStyle(SaysoPalette.muted)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Example:")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                            Text("\"\(exampleNative)\"")
                                .font(.caption.italic())
                                .foregroundStyle(.white)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        !isLatin ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                !isLatin ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                                lineWidth: !isLatin ? 1.5 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recommendedModelCard: some View {
        let rec = LocalModelCatalog.recommendedModel(for: model.settings.language)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.settings.language.isIndic ? "★ RECOMMENDED: AI4BHARAT" : "★ RECOMMENDED MODEL")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SaysoPalette.brandAmber, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(SaysoPalette.brandNavyBase)

                Text("Dedicated On-Device Speech Model")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }

            Text("\(rec.displayName) (\(rec.expectedSizeBytes / 1_000_000) MB)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            Text(
                model.settings.language.isIndic
                    ? "AI4Bharat IndicConformer is the most superior on-device model for Indian dialects and conversational speech."
                    : rec.summary
            )
            .font(.caption)
            .foregroundStyle(SaysoPalette.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SaysoPalette.brandAmber.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct StepOneSttEngineView: View {
    @ObservedObject var model: SaysoAppModel
    let onOpenOtherModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Your Speech Engine")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Transcribe voice into text with on-device AI or private cloud.")
                    .font(.subheadline)
                    .foregroundStyle(SaysoPalette.muted)
            }

            // Card 1: On-Device Model (★ RECOMMENDED)
            let isLocal = model.settings.route == .local
            let recModel = LocalModelCatalog.recommendedModel(for: model.settings.language)
            let isInstalled = model.nativeModelReady(for: model.settings.language)
            let isDownloading: Bool = {
                if model.settings.language == .english {
                    return model.localEnglishModel.state == .installing
                } else if model.settings.language == .punjabi {
                    return model.localPunjabiModel.state == .installing
                } else {
                    return model.localEnglishModel.multilingualState == .installing
                }
            }()
            let downloadProgress: Double = {
                if model.settings.language == .english {
                    return model.localEnglishModel.downloadProgress
                } else if model.settings.language == .punjabi {
                    return 0.5
                } else {
                    return model.localEnglishModel.multilingualDownloadProgress
                }
            }()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isLocal ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isLocal ? SaysoPalette.brandAmber : SaysoPalette.muted)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("On-Device Neural Model")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SaysoPalette.emerald.opacity(0.25), in: Capsule())
                                .foregroundStyle(SaysoPalette.emerald)
                        }

                        Text(recModel.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SaysoPalette.brandAmber)

                        Text("Private and instant. Runs locally on Apple Neural Engine and CPU. Zero audio or text ever leaves your Mac.")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                            .lineSpacing(2)

                        HStack(spacing: 8) {
                            Text("\(recModel.expectedSizeBytes / 1_000_000) MB")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)

                            Text("⚡ Instant (50ms)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SaysoPalette.brandAmber.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(SaysoPalette.brandAmber)

                            Spacer()

                            Button("See other models") {
                                onOpenOtherModels()
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SaysoPalette.brandCobalt)
                        }
                        .padding(.top, 4)
                    }
                }

                // Download / Installed Status Card
                if isInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SaysoPalette.emerald)
                        Text("\(recModel.displayName) installed & ready")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SaysoPalette.emerald)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SaysoPalette.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                } else if isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Downloading neural weights (\(Int(downloadProgress * 100))%)...")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SaysoPalette.brandAmber)
                        }
                        ProgressView(value: max(0.05, downloadProgress))
                            .tint(SaysoPalette.brandAmber)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Button(action: {
                        model.settings.route = .local
                        model.save()
                        Task {
                            if model.settings.language == .punjabi {
                                await model.localPunjabiModel.install()
                            } else {
                                await model.localEnglishModel.install(language: model.settings.language)
                            }
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption.weight(.bold))
                            Text("Download \(recModel.displayName) (\(recModel.expectedSizeBytes / 1_000_000) MB)")
                                .font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(SaysoPalette.blueButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(
                isLocal ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isLocal ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                        lineWidth: isLocal ? 1.5 : 1
                    )
            )
            .onTapGesture {
                model.settings.route = .local
                model.save()
            }

            // Card 2: Cloud Speech (BYOK)
            let isCloud = model.settings.route == .byok
            Button(action: {
                model.settings.route = .byok
                model.save()
            }) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isCloud ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isCloud ? SaysoPalette.brandAmber : SaysoPalette.muted)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cloud Speech (BYOK)")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Groq Whisper, OpenAI Whisper, Deepgram, Cerebras")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SaysoPalette.muted)

                        Text("Ultra-accurate cloud transcription with your own API key. Low memory and CPU usage.")
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                            .lineSpacing(2)
                    }
                    Spacer()
                }
                .padding(16)
                .background(
                    isCloud ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            isCloud ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                            lineWidth: isCloud ? 1.5 : 1
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StepTwoPostProcessingView: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Cleanup & Post-Processing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Choose how your speech is formatted, punctuated, and polished.")
                    .font(.subheadline)
                    .foregroundStyle(SaysoPalette.muted)
            }

            // Transformation Example Card
            VStack(alignment: .leading, spacing: 8) {
                Text("TRANSFORMATION EXAMPLE")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(SaysoPalette.brandAmber)
                    .tracking(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("RAW SPOKEN")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SaysoPalette.muted)
                    Text("\"uh hey can you like schedule the meeting for tomorrow at 2 pm question mark\"")
                        .font(.caption.italic())
                        .foregroundStyle(SaysoPalette.muted)
                }

                HStack(spacing: 8) {
                    Rectangle().fill(SaysoPalette.brandNavyContainer).frame(height: 1)
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(SaysoPalette.brandAmber)
                    Rectangle().fill(SaysoPalette.brandNavyContainer).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("POLISHED OUTPUT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SaysoPalette.emerald)
                    Text("\"Hey, can you schedule the meeting for tomorrow at 2:00 PM?\"")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(SaysoPalette.brandAmber.opacity(0.4), lineWidth: 1)
            )

            // 4 Polish Options
            VStack(spacing: 10) {
                // 1. Smart Rules Cleanup
                polishRow(
                    mode: .rules,
                    title: "Smart Rules Cleanup",
                    badge: "RECOMMENDED",
                    badgeColor: SaysoPalette.emerald,
                    subtitle: "Instant on-device syntax cleanup, spoken punctuation, capitalization, and filler word removal. Zero memory or latency overhead."
                )

                // 2. On-Device SLM
                let slm = LocalSlmCatalog.defaultModel
                let slmStatus = model.checkSlmStatus(slm)
                let isDownloading = model.slmDownloadProgress[slm.id] != nil
                polishRow(
                    mode: .localSLM,
                    title: "On-Device SLM (Qwen 2.5 / SmolLM)",
                    badge: "OFFLINE AI",
                    badgeColor: SaysoPalette.brandCobalt,
                    subtitle: "Local Small Language Model runs entirely on Apple Silicon. Fixes grammar, formats action items, and rewrites context without internet.",
                    extraContent: {
                        if model.settings.cleanupMode == .localSLM {
                            if slmStatus == .installed {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(SaysoPalette.emerald)
                                    Text("\(slm.displayName) installed & ready")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(SaysoPalette.emerald)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(SaysoPalette.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            } else if isDownloading {
                                let pct = Int((model.slmDownloadProgress[slm.id] ?? 0.05) * 100)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Downloading \(slm.displayName) (\(pct)%)...")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(SaysoPalette.brandAmber)
                                    ProgressView(value: model.slmDownloadProgress[slm.id] ?? 0.05)
                                        .tint(SaysoPalette.brandAmber)
                                }
                                .padding(8)
                                .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 6))
                            } else {
                                Button(action: {
                                    Task { await model.installSlm(slm) }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("Download \(slm.displayName) (\(slm.sizeDisplay))")
                                    }
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(SaysoPalette.brandCobalt, in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                )

                // 3. Cloud LLM
                polishRow(
                    mode: .cloudLLM,
                    title: "Cloud LLM (BYOK)",
                    badge: nil,
                    badgeColor: .clear,
                    subtitle: "Advanced cleanup via OpenAI GPT-4o mini, Anthropic Claude 3.5 Haiku, or Groq Llama 3."
                )
            }
        }
    }

    private func polishRow(
        mode: CleanupMode,
        title: String,
        badge: String?,
        badgeColor: Color,
        subtitle: String,
        @ViewBuilder extraContent: () -> some View = { EmptyView() }
    ) -> some View {
        let isSelected = model.settings.cleanupMode == mode
        return Button(action: {
            model.settings.cleanupMode = mode
            model.save()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? SaysoPalette.brandAmber : SaysoPalette.muted)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            if let badge = badge {
                                Text(badge)
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badgeColor.opacity(0.25), in: Capsule())
                                    .foregroundStyle(badgeColor)
                            }
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(SaysoPalette.muted)
                            .lineSpacing(2)
                    }
                    Spacer()
                }

                extraContent()
            }
            .padding(12)
            .background(
                isSelected ? SaysoPalette.brandNavyWell : SaysoPalette.brandNavySurface,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? SaysoPalette.brandAmber : SaysoPalette.brandNavyContainer,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StepThreePermissionsView: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions & Verification")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Grant required system access and verify your setup with a test dictation.")
                    .font(.subheadline)
                    .foregroundStyle(SaysoPalette.muted)
            }

            // Permission Rows
            VStack(spacing: 8) {
                permissionRow(
                    kind: .microphone,
                    title: "Microphone Access",
                    desc: "Required to record audio when you trigger dictation."
                )
                permissionRow(
                    kind: .accessibility,
                    title: "Accessibility Service",
                    desc: "Required to type and insert your dictated text directly into other apps (Slack, Notes, Cursor, WhatsApp) without copy-pasting."
                )
                permissionRow(
                    kind: .inputMonitoring,
                    title: "Input Monitoring",
                    desc: "Required to listen for global hotkeys (⌥ Space) across all applications."
                )
            }

            // Live Dictation Test Card
            VStack(alignment: .leading, spacing: 10) {
                Text("TEST YOUR SETUP")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(SaysoPalette.brandAmber)
                    .tracking(0.8)

                if model.permissions.states[.microphone] != .granted {
                    Label("Grant Microphone permission above before testing dictation.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(SaysoPalette.crimson)
                } else if model.isOnboardingTestActive {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(SaysoPalette.crimson)
                            .frame(width: 12, height: 12)
                            .shadow(color: SaysoPalette.crimson, radius: 4)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Listening... speak now")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Say a short sentence like 'Hey Sayso, this is my first test'.")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                        }

                        Spacer()

                        Button(action: {
                            model.startOrStopDictation()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "stop.circle.fill")
                                Text("Stop Test")
                            }
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(SaysoPalette.crimson, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 10))
                } else if let testText = model.onboardingTestTranscriptText, !testText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(SaysoPalette.emerald)
                            Text("First Transcript Received!")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(SaysoPalette.emerald)
                            Spacer()
                            Button("Test Again") {
                                model.startOnboardingTest()
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SaysoPalette.brandCobalt)
                        }

                        Text("\"\(testText)\"")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(12)
                    .background(SaysoPalette.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start a short test dictation")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Verifies your microphone capture and on-device transcription engine.")
                                .font(.caption)
                                .foregroundStyle(SaysoPalette.muted)
                        }

                        Spacer()

                        Button(action: {
                            model.startOnboardingTest()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill")
                                Text("Start Test")
                            }
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(SaysoPalette.blueButtonGradient, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(SaysoPalette.brandNavyWell, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1)
            )
        }
    }

    private func permissionRow(kind: PermissionKind, title: String, desc: String) -> some View {
        let isGranted = model.permissions.states[kind] == .granted
        return HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isGranted ? SaysoPalette.emerald : SaysoPalette.muted)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(SaysoPalette.muted)
            }

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SaysoPalette.emerald)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SaysoPalette.emerald.opacity(0.15), in: Capsule())
            } else {
                Button(action: {
                    Task { await model.permissions.request(kind) }
                }) {
                    Text(kind == .microphone || model.permissions.states[kind] == .undetermined ? "Grant" : "Open Settings")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(SaysoPalette.brandCobalt, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(SaysoPalette.brandNavySurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SaysoPalette.brandNavyContainer, lineWidth: 1)
        )
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
    static let brandNavyBase = brandNavyDark
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


/// Hops shortcut intents onto the main actor and calls the original handlers; nothing else decides what a shortcut does.
private final class AppShortcutIntents: ShortcutIntentHandling, @unchecked Sendable {
    enum Intent { case dictation, controlDown, controlUp, toggleNotch }
    private weak var model: SaysoAppModel?

    init(model: SaysoAppModel) { self.model = model }

    private func run(_ intent: Intent) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { model?.performShortcutIntent(intent) }
        } else {
            Task { @MainActor [weak model] in model?.performShortcutIntent(intent) }
        }
    }

    func dictationShortcutPressed() { run(.dictation) }
    func controlShortcutPressed() { run(.controlDown) }
    func controlShortcutReleased() { run(.controlUp) }
    func toggleNotchShortcutPressed() { run(.toggleNotch) }
}
