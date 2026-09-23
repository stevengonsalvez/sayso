import AppKit
import AVFoundation
import SaysoCore
import SpeakUpstreamBridge
import SwiftUI

@main
struct SaysoNotchApp: App {
    @StateObject private var model = SaysoAppModel()

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
}

@MainActor
final class SaysoAppModel: ObservableObject {
    @Published var settings: SaysoSettings
    @Published var lastTranscript: Transcript?
    @Published var controlStatus = "Ready"
    @Published var currentSnapshot: DesktopSnapshot?
    @Published var controlEntries: [ControlAuditEntry] = []
    @Published var pendingControlStep: ControlPlanStep?
    @Published var selectedTab = 0
    @Published var notice: String?
    @Published var dictationHotKey = HotKey.custom(keyCode: 49, modifiers: .option)

    let permissions = PermissionCenter()
    let transcriber: LiveTranscriber
    let localEnglishModel: FluidAudioLocalModelManager
    let speech = SpeechOutput()
    let history = HistoryStore()
    let sessions = RecordingSessionStore()
    let controller = AXDesktopController()
    let desktopControlSession = ControlSession()
    let controlAudit = ControlAuditStore()
    let secrets = KeychainSecretStore()
    private let automation = SaysoAutomationServer()
    private let settingsStore = UserDefaultsSettingsStore()
    private let hotKeyEngine = HotKeyEngine()
    private let notch: NotchPanelController
    private var mainWindow: NSWindow?
    private var lastExternalApplication: NSRunningApplication?
    private var dictationDestination: TextOutput.Destination?
    private var activeRecordingSession: RecordingSession?
    private var workspaceObserver: NSObjectProtocol?

    init() {
        let localEnglishModel = FluidAudioLocalModelManager()
        self.localEnglishModel = localEnglishModel
        transcriber = LiveTranscriber(fluidAudioModels: localEnglishModel)
        var saved = UserDefaultsSettingsStore().load()
        if !saved.route.supportsDictation { saved.route = .local }
        if CommandLine.arguments.contains("--automation-server") {
            saved.desktopControlEnabled = true
            saved.onboardingCompleted = true
        }
        settings = saved
        dictationHotKey = Self.loadDictationHotKey()
        notch = NotchPanelController()
        hotKeyEngine.register(gesture: .singleTap) { [weak self] in
            self?.startOrStopDictation()
        }
        hotKeyEngine.start(for: dictationHotKey)
        observeExternalApplications()
        notch.install(model: self)
        if saved.desktopControlEnabled { startAutomation() }
        DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        Task { controlEntries = await controlAudit.entries() }
    }

    func save() { settingsStore.save(settings) }

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

    func startOrStopDictation() {
        if transcriber.phase == .listening {
            transcriber.stop()
            return
        }
        Task {
            _ = await startDictation()
        }
    }

    private func startDictation() async -> Bool {
        notch.show()
        guard settings.route.supportsDictation else {
            notice = "Your provider supports translation, not transcription."
            return false
        }
        guard !settings.route.transmitsData || settings.cloudConsentGranted else {
            notice = "Confirm the Apple Speech data path before recording."
            return false
        }
        dictationDestination = settings.autoInsert
            ? TextOutput.captureDestination(targetProcessIdentifier: lastExternalApplication?.processIdentifier)
            : nil
        let session = RecordingSession(
            language: settings.language,
            route: settings.route,
            destination: dictationDestination?.recordingDestination
        )
        activeRecordingSession = session
        await sessions.upsert(session)
        await permissions.request(.microphone)
        guard permissions.states[.microphone] == .granted else {
            notice = "Microphone access is required before Sayso can listen."
            failActiveSession(notice ?? "Microphone access denied")
            return false
        }
        if transcriber.requiresSpeechRecognition(language: settings.language, route: settings.route) {
            await permissions.request(.speechRecognition)
            guard permissions.states[.speechRecognition] == .granted else {
                notice = "Speech Recognition access is required before Sayso can transcribe."
                failActiveSession(notice ?? "Speech Recognition access denied")
                return false
            }
        }
        let started = await transcriber.start(
                language: settings.language,
                route: settings.route,
                handsFree: settings.handsFree,
                onPartial: { [weak self] text in
                    Task { @MainActor [weak self] in self?.handleVoiceModeSwitch(text) }
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
            failActiveSession(transcriber.error?.localizedDescription ?? "Could not start dictation")
            return false
        }
        updateActiveSession { $0.transition(to: .listening) }
        try? await Task.sleep(for: .milliseconds(250))
        return transcriber.phase == .listening
    }

    func accept(_ transcript: Transcript) {
        guard settings.mode == .dictation else {
            runControl(transcript.text)
            return
        }
        if let current = lastTranscript, let edited = VoiceEdits.apply(transcript.text, to: current.translatedText ?? current.text) {
            var updated = current
            updated.text = edited
            updated.translatedText = nil
            lastTranscript = updated
            Task { await history.append(updated) }
            notice = "Voice edit applied."
            return
        }
        updateActiveSession { $0.transition(to: .processing) }
        Task {
            await finish(await translated(transcript))
        }
    }

    private func translated(_ transcript: Transcript) async -> Transcript {
        let currentSettings = settings
        var corrected = transcript
        corrected.text = currentSettings.dictationProfile.postProcess(transcript.text)
        corrected.text = LexiconCorrections.apply(corrected.text, replacements: currentSettings.lexicon)
        guard currentSettings.translationEnabled else { return corrected }
        guard currentSettings.cloudConsentGranted else {
            notice = "Translation needs cloud consent and a selected provider."
            return corrected
        }
        guard let key = secrets.secret(named: "byok-api-key"),
              let baseURL = URL(string: currentSettings.byokBaseURL) else {
            notice = "Configure BYOK translation in Settings."
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
            notice = "Translation unavailable. Inserted original transcript."
        }
        return translated
    }

    private func finish(_ transcript: Transcript) async {
        lastTranscript = transcript
        await history.append(transcript)
        let finalText = transcript.translatedText ?? transcript.text
        let destination = dictationDestination
        dictationDestination = nil
        let delivery: TextDeliveryMethod
        if settings.autoInsert {
            delivery = TextOutput.insertOrCopy(
                finalText,
                destination: destination,
                restoreClipboardAfterPaste: settings.restoreClipboardAfterPaste
            )
        } else {
            TextOutput.copy(finalText)
            delivery = .clipboard
        }
        if delivery == .clipboard { notice = "Final text copied to clipboard." }
        updateActiveSession { $0.complete(text: finalText, delivery: delivery) }
        activeRecordingSession = nil
        notch.hideAfterDelay()
    }

    private func updateActiveSession(_ update: (inout RecordingSession) -> Void) {
        guard var session = activeRecordingSession else { return }
        update(&session)
        activeRecordingSession = session
        Task { await sessions.upsert(session) }
    }

    private func failActiveSession(_ message: String) {
        updateActiveSession { $0.fail(message) }
        activeRecordingSession = nil
        dictationDestination = nil
    }

    private func handleTranscriptionTermination(_ termination: TranscriptionTermination) {
        guard activeRecordingSession != nil else { return }
        switch termination {
        case .cancelled:
            updateActiveSession { $0.transition(to: .cancelled) }
            activeRecordingSession = nil
            dictationDestination = nil
        case let .failed(message):
            failActiveSession(message)
        }
    }

    func switchMode(_ mode: SaysoMode) {
        guard mode == settings.mode || (transcriber.phase != .listening && transcriber.phase != .processing) else {
            notice = "Stop dictation before changing modes."
            return
        }
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
        selectedTab = 5
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
        settings.lexicon[spoken] = replacement
        save()
    }

    func removeLexiconCorrection(_ spoken: String) {
        settings.lexicon.removeValue(forKey: spoken)
        save()
    }

    func setAutomation(_ enabled: Bool) {
        settings.desktopControlEnabled = enabled
        if enabled { startAutomation() } else { automation.stop() }
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
        if command.contains("sayso switch to control") { switchMode(.control) }
        if command.contains("sayso switch to dictation") { switchMode(.dictation) }
    }

    func speakLatest() {
        guard let text = lastTranscript?.translatedText ?? lastTranscript?.text else { return }
        speech.speak(text, language: settings.outputLanguage)
    }

    func captureDesktop() {
        do {
            currentSnapshot = try controller.capture(application: controlTarget())
            controlStatus = "Grounded \(currentSnapshot?.applicationName ?? "desktop")"
        } catch {
            controlStatus = error.localizedDescription
        }
    }

    func runSafeDemoControl() {
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
        do {
            let target = try controlTarget()
            let snapshot = try controller.capture(application: target)
            currentSnapshot = snapshot
            let step = try ControlPlanner.plan(command: command, snapshot: snapshot)
            controlStatus = "Planned: \(step.reason)"
            if ControlPolicy.requiresConfirmation(step) {
                pendingControlStep = step
                controlStatus = "Review required: \(step.reason)"
                return
            }
            execute(step, target: target, approved: false)
        } catch {
            controlStatus = error.localizedDescription
        }
    }

    func approvePendingControl() {
        guard let step = pendingControlStep else { return }
        pendingControlStep = nil
        do {
            try execute(step, target: controlTarget(), approved: true)
        } catch {
            controlStatus = error.localizedDescription
        }
    }

    func discardPendingControl() {
        pendingControlStep = nil
        controlStatus = "Action discarded"
    }

    func cancelControl() {
        pendingControlStep = nil
        Task {
            let state = await desktopControlSession.cancel()
            controlStatus = state.result == .cancelled ? "Control cancelled" : "No active control task"
        }
    }

    private func execute(_ step: ControlPlanStep, target: NSRunningApplication, approved: Bool) {
        Task {
            do {
                let state = await desktopControlSession.currentState()
                if state.phase != .running { _ = await desktopControlSession.start() }
                let entry = try await controller.execute(step, approved: approved, targetApplication: target)
                await controlAudit.append(entry)
                controlEntries = await controlAudit.entries()
                let stepResult: ControlSessionStepResult = entry.result.hasPrefix("observed")
                    ? .effectObserved
                    : entry.result.hasPrefix("no observed") ? .noEffectObserved : .actionFailed
                let updated = await desktopControlSession.record(stepResult)
                controlStatus = updated.result.map { "\(entry.result), \($0.rawValue)" } ?? entry.result
            } catch {
                controlStatus = error.localizedDescription
            }
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
            Button(model.transcriber.phase == .listening ? "Stop dictation" : "Start dictation") {
                model.startOrStopDictation()
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
                    }
                    Label("Settings", systemImage: "gearshape").tag(5)
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
            default: SaysoSettingsView(model: model)
            }
        }
        .tint(SaysoPalette.cobalt)
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { !model.settings.onboardingCompleted },
            set: { _ in }
        )) {
            OnboardingWizard(model: model)
        }
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
                Text(model.transcriber.phase == .listening ? "LISTENING" : "DICTATION")
                    .font(.caption.weight(.black)).foregroundStyle(SaysoPalette.amber)
                Text(model.transcriber.partialText.isEmpty ? "Tap to start talking" : model.transcriber.partialText)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                Button {
                    model.startOrStopDictation()
                } label: {
                    Label(
                        model.transcriber.phase == .listening ? "Stop" : "Start dictation",
                        systemImage: model.transcriber.phase == .listening ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.transcriber.phase == .listening ? SaysoPalette.crimson : SaysoPalette.cobalt)
            }
            .padding(28)
            .background(SaysoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            if let transcript = model.lastTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LAST RESULT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(transcript.translatedText ?? transcript.text).font(.title3)
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
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let insights = HistoryInsights.make(from: entries)
            HStack(spacing: 24) {
                Label("\(insights.entries) entries", systemImage: "text.quote")
                Label("\(insights.words) words", systemImage: "textformat")
                Label("\(insights.activeDays) days", systemImage: "calendar")
                Spacer()
                Button("Copy export") { Task { TextOutput.copy(await model.history.plainTextExport()) } }
                Button("Clear history", role: .destructive) { confirmClear = true }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal)
            List(entries) { entry in
                VStack(alignment: .leading) {
                    Text(entry.translatedText ?? entry.text)
                    Text(entry.createdAt, style: .date).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("History")
        .task { entries = await model.history.all() }
        .alert("Clear Sayso history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { Task { await model.history.clear(); entries = [] } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes saved transcripts from this Mac.") }
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
                        Label(
                            SpeechCapabilities.supports(language) ? "Available" : "Unavailable",
                            systemImage: SpeechCapabilities.supports(language) ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpeechCapabilities.supports(language) ? SaysoPalette.cobalt : SaysoPalette.muted)
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
    @State private var apiKey = ""

    init(model: SaysoAppModel) {
        self.model = model
        _localEnglishModel = ObservedObject(wrappedValue: model.localEnglishModel)
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
            Section("Your provider") {
                Text("Optional. Used only after explicit cloud consent. API key stays in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Base URL", text: $model.settings.byokBaseURL)
                TextField("Translation model", text: $model.settings.byokTranslationModel)
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
                Text(SpeechCapabilities.supports(model.settings.language) ? "Available on this Mac" : "Unavailable on this Mac, choose another language or cloud route")
                    .font(.caption).foregroundStyle(SpeechCapabilities.supports(model.settings.language) ? .secondary : SaysoPalette.crimson)
                Picker("Speech route", selection: $model.settings.route) {
                    ForEach(ProviderRoute.dictationRoutes) { Text($0.displayName).tag($0) }
                }
                Toggle("Translate final text", isOn: $model.settings.translationEnabled)
                Toggle("Insert final text", isOn: $model.settings.autoInsert)
                Toggle("Restore clipboard after paste fallback", isOn: $model.settings.restoreClipboardAfterPaste)
                    .disabled(!model.settings.autoInsert)
                Toggle("Hands-free, stop after 1.2 seconds of silence", isOn: $model.settings.handsFree)
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
                Text("Default: ⌥ Space. Use any supported global shortcut.")
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
            Section("Lexicon corrections") {
                HStack {
                    TextField("Heard", text: $spoken)
                    TextField("Write", text: $replacement)
                    Button("Add") {
                        model.addLexiconCorrection(spoken, replacement: replacement)
                        spoken = ""; replacement = ""
                    }
                }
                ForEach(model.settings.lexicon.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text(model.settings.lexicon[key] ?? "")
                        Spacer()
                        Button("Remove") { model.removeLexiconCorrection(key) }
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
                    model: "\(settings.route.displayName); local-English=\(localEnglishModelStatus); microphone=\(permissionSummary(.microphone)); raw=\(microphoneSystemStatus); speech=\(permissionSummary(.speechRecognition))",
                    sessionActive: transcriber.phase == .listening,
                    appVersion: "1.0.0"
                )
            )
        case .startDictation:
            guard transcriber.phase != .listening else {
                return .failure(id: request.id, command: request.command, error: .init(code: .alreadyRecording, message: "Sayso is already listening."))
            }
            guard await startDictation() else {
                return .failure(id: request.id, command: request.command, error: .init(code: .appUnavailable, message: transcriber.error?.localizedDescription ?? "Speech engine did not start."))
            }
            return .success(id: request.id, command: request.command, result: .init(sessionActive: true))
        case .stopDictation:
            guard transcriber.phase == .listening else {
                return .failure(id: request.id, command: request.command, error: .init(code: .notRecording, message: "Sayso is not listening."))
            }
            transcriber.stop()
            return .success(id: request.id, command: request.command, result: .init(sessionActive: false))
        case .history:
            let entries = await history.all().prefix(request.resolvedLimit).map {
                AutomationHistoryEntry(
                    id: $0.id.uuidString,
                    text: $0.translatedText ?? $0.text,
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
                let final = await translated(transcript)
                lastTranscript = final
                await history.append(final)
                return .success(
                    id: request.id, command: request.command,
                    result: .init(text: final.translatedText ?? final.text, model: final.route.displayName)
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
                    Button("Skip") { complete() }
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
                        Text("Choose the spoken language. Automatic follows your Mac, while an explicit language keeps recognition focused.")
                            .foregroundStyle(.secondary)
                        Picker("Spoken language", selection: $model.settings.language) {
                            ForEach(DictationLanguage.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Label("Indian languages included: Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Punjabi, Telugu, and Urdu.", systemImage: "character.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose your engine.").font(.title2.bold())
                        Text("On-device keeps recognition local when macOS supports the selected language. Apple Speech can use Apple’s recognition service.")
                            .foregroundStyle(.secondary)
                        Picker("Speech route", selection: $model.settings.route) {
                            ForEach(ProviderRoute.dictationRoutes) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if model.settings.route.transmitsData {
                            Toggle("I understand Apple Speech may transmit voice data", isOn: $model.settings.cloudConsentGranted)
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
                        Text("Microphone and Speech Recognition power dictation. Accessibility enables safe text insertion. Input Monitoring is only for the global hotkey.")
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
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Back") { page = max(0, page - 1) }.disabled(page == 0)
                Spacer()
                Button(page == steps.count - 1 ? "Start dictating" : "Continue") {
                    if page == steps.count - 1 {
                        complete()
                        model.startOrStopDictation()
                    } else {
                        page += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(page == 1 && model.settings.route.transmitsData && !model.settings.cloudConsentGranted)
            }
        }
        .padding(32)
        .frame(width: 560, height: 500)
    }

    private func complete() {
        model.settings.onboardingCompleted = true
        model.save()
        dismiss()
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
