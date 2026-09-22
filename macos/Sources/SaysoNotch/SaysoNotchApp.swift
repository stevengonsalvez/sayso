import AppKit
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
    @Published var selectedTab = 0
    @Published var notice: String?

    let permissions = PermissionCenter()
    let transcriber = LiveTranscriber()
    let speech = SpeechOutput()
    let history = HistoryStore()
    let controller = AXDesktopController()
    let controlAudit = ControlAuditStore()
    let secrets = KeychainSecretStore()
    private let automation = SaysoAutomationServer()
    private let settingsStore = UserDefaultsSettingsStore()
    private let notch: NotchPanelController
    private var mainWindow: NSWindow?

    init() {
        var saved = UserDefaultsSettingsStore().load()
        if CommandLine.arguments.contains("--automation-server") {
            saved.desktopControlEnabled = true
            saved.onboardingCompleted = true
        }
        settings = saved
        notch = NotchPanelController()
        notch.install(model: self)
        if saved.desktopControlEnabled { startAutomation() }
        DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        Task { controlEntries = await controlAudit.entries() }
    }

    func save() { settingsStore.save(settings) }

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
        let started = await transcriber.start(
                language: settings.language,
                route: settings.route,
                handsFree: settings.handsFree,
                onPartial: { [weak self] text in
                    Task { @MainActor [weak self] in self?.handleVoiceModeSwitch(text) }
                }
            ) { [weak self] transcript in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.accept(transcript)
                }
            }
        guard started else { return false }
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
        Task {
            await finish(await translated(transcript))
        }
    }

    private func translated(_ transcript: Transcript) async -> Transcript {
        let currentSettings = settings
        var corrected = transcript
        corrected.text = LexiconCorrections.apply(transcript.text, replacements: currentSettings.lexicon)
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
        if settings.autoInsert { _ = TextOutput.insertOrCopy(transcript.translatedText ?? transcript.text) }
        notch.hideAfterDelay()
    }

    func switchMode(_ mode: SaysoMode) {
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
        selectedTab = 3
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
            currentSnapshot = try controller.capture()
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
                _ = try controller.verify(snapshot)
                controlStatus = "Verified focused target"
            } catch {
                controlStatus = error.localizedDescription
            }
        }
    }

    func runControl(_ command: String) {
        do {
            let snapshot = try controller.capture()
            currentSnapshot = snapshot
            let step = try ControlPlanner.plan(command: command, snapshot: snapshot)
            controlStatus = "Planned: \(step.reason)"
            Task {
                do {
                    let entry = try await controller.execute(step)
                    await controlAudit.append(entry)
                    controlEntries = await controlAudit.entries()
                    controlStatus = entry.result
                } catch {
                    controlStatus = error.localizedDescription
                }
            }
        } catch {
            controlStatus = error.localizedDescription
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
                    Label("Settings", systemImage: "gearshape").tag(3)
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
            default: SaysoSettingsView(model: model)
            }
        }
        .tint(SaysoPalette.cobalt)
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { !model.settings.onboardingCompleted },
            set: { presented in
                if !presented {
                    model.settings.onboardingCompleted = true
                    model.save()
                }
            }
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
                Button(model.transcriber.phase == .listening ? "Stop" : "Start dictation") {
                    model.startOrStopDictation()
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
                VStack(alignment: .leading) {
                    Text("Desktop control").font(.largeTitle.bold())
                    Text("Ground. Act. Verify.").foregroundStyle(.secondary)
                }
                Spacer()
                ModePicker(model: model)
            }
            HStack(spacing: 12) {
                Button("Capture desktop") { model.captureDesktop() }.buttonStyle(.borderedProminent)
                Button("Verify focused target") { model.runSafeDemoControl() }
            }
            HStack {
                TextField("Type, scroll down, or open https://…", text: $command)
                    .onSubmit { model.runControl(command) }
                Button("Run") { model.runControl(command) }
                    .buttonStyle(.borderedProminent)
            }
            GroupBox("Control status") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.controlStatus)
                    if let snapshot = model.currentSnapshot {
                        Text("\(snapshot.applicationName)  •  \(snapshot.windowTitle)")
                        Text(snapshot.isProtected ? "Protected target, blocked" : "Target eligible for verified actions")
                            .foregroundStyle(snapshot.isProtected ? SaysoPalette.crimson : .secondary)
                        if !snapshot.elements.isEmpty {
                            Text("Visible controls: \(snapshot.elements.prefix(4).map(\.title).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.controlEntries.isEmpty {
                GroupBox("Recent verified actions") {
                    ForEach(model.controlEntries.prefix(3)) { entry in
                        Text("\(entry.timestamp.formatted(date: .omitted, time: .shortened))  \(entry.result)")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Say “type hello”, “click Send”, “scroll down”, or “open https://…”. Secure fields, stale targets, and low-confidence plans are rejected.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
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
                    ForEach(ProviderRoute.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Translate final text", isOn: $model.settings.translationEnabled)
                Toggle("Insert final text", isOn: $model.settings.autoInsert)
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
            return .success(
                id: request.id, command: request.command,
                result: .init(
                    model: settings.route.displayName,
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

    private let pages = ["Welcome", "Permissions", "Voice", "Ready"]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(SaysoPalette.cobalt)
                VStack(alignment: .leading) {
                    Text("Sayso Notch").font(.title.bold())
                    Text("Private voice, right where you look.").foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(page + 1), total: Double(pages.count))
                .tint(SaysoPalette.cobalt)
            Group {
                switch page {
                case 0:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your voice stays yours.").font(.title2.bold())
                        Text("Sayso starts on-device. Cloud speech, translation, cleanup, and control planning remain off until you select a provider and consent to its data path.")
                        Toggle("I understand selected cloud routes transmit data", isOn: $model.settings.cloudConsentGranted)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Grant only what you use.").font(.title2.bold())
                        ForEach(PermissionKind.allCases) { permission in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(permission.displayName).fontWeight(.semibold)
                                    Text(permission == .inputMonitoring ? "Enable in System Settings for global hotkeys." : "Required for this Sayso capability.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Request") { Task { await model.permissions.request(permission) } }
                            }
                        }
                    }
                case 2:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Set your voice path.").font(.title2.bold())
                        Picker("Language", selection: $model.settings.language) {
                            ForEach(DictationLanguage.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Route", selection: $model.settings.route) {
                            ForEach(ProviderRoute.allCases) { Text($0.displayName).tag($0) }
                        }
                        Toggle("Insert final text into active app", isOn: $model.settings.autoInsert)
                    }
                default:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ready to say it.").font(.title2.bold())
                        Text("Use the menu-bar control, then watch your live transcript appear in the notch. You can enable Desktop Control later, after Accessibility is granted.")
                        Button("Test Sayso dictation") { model.startOrStopDictation() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Back") { page = max(0, page - 1) }.disabled(page == 0)
                Spacer()
                Button(page == pages.count - 1 ? "Finish" : "Continue") {
                    if page == pages.count - 1 {
                        model.settings.onboardingCompleted = true
                        model.save()
                    } else {
                        page += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 560, height: 460)
    }
}

struct ModePicker: View {
    @ObservedObject var model: SaysoAppModel

    var body: some View {
        Picker("Mode", selection: Binding(
            get: { model.settings.mode },
            set: { model.switchMode($0) }
        )) {
            Text("Dictation").tag(SaysoMode.dictation)
            Text("Control").tag(SaysoMode.control)
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
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
