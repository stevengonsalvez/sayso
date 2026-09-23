import Foundation
import Testing
@testable import SaysoCore

@Test func hardGateLanguagesHaveStableLocales() {
    #expect(DictationLanguage.english.localeIdentifier == "en-GB")
    #expect(DictationLanguage.hindi.localeIdentifier == "hi-IN")
    #expect(DictationLanguage.tamil.localeIdentifier == "ta-IN")
    #expect(DictationLanguage.malayalam.localeIdentifier == "ml-IN")
    #expect(DictationLanguage.telugu.localeIdentifier == "te-IN")
    #expect(DictationLanguage.kannada.localeIdentifier == "kn-IN")
}

@Test func onlyImplementedSpeechRoutesAreSelectable() {
    #expect(ProviderRoute.dictationRoutes == [.local, .appleSpeech])
    #expect(!ProviderRoute.byok.supportsDictation)
}

@Test func settingsMigrationDefaultsMissingDictationProfile() throws {
    let legacy = Data("{\"mode\":\"control\",\"language\":\"en-GB\"}".utf8)
    let settings = try JSONDecoder().decode(SaysoSettings.self, from: legacy)

    #expect(settings.mode == .control)
    #expect(settings.language == .english)
    #expect(settings.dictationProfile == .default)
}

@Test func firstRunMigratesAutomaticLanguageToEnglish() {
    var settings = SaysoSettings()
    settings.language = .automatic
    settings.applyFirstRunDefaults()
    #expect(settings.language == .english)

    settings.onboardingCompleted = true
    settings.language = .automatic
    settings.applyFirstRunDefaults()
    #expect(settings.language == .automatic)
}

@Test func permissionRequestsOpenTheirExactPrivacyPanes() {
    #expect(PermissionKind.microphone.settingsURL.absoluteString.contains("Privacy_Microphone"))
    #expect(PermissionKind.speechRecognition.settingsURL.absoluteString.contains("Privacy_SpeechRecognition"))
    #expect(PermissionKind.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"))
    #expect(PermissionKind.inputMonitoring.settingsURL.absoluteString.contains("Privacy_ListenEvent"))
}

@Test func lexiconCorrectionsApplyBeforeOutput() {
    #expect(LexiconCorrections.apply("Ship say so", replacements: ["say so": "Sayso"]) == "Ship Sayso")
}

@Test func lexiconCorrectionsPreferLongestPhrase() {
    #expect(
        LexiconCorrections.apply(
            "say so say",
            replacements: ["say": "SAY", "say so": "Sayso"]
        ) == "Sayso SAY"
    )
}

@Test func voiceEditsRequireExactCommandShape() {
    #expect(VoiceEdits.apply("Sayso replace world with Stevie", to: "Hello world") == "Hello Stevie")
    #expect(VoiceEdits.apply("Sayso delete world", to: "Hello world") == "Hello ")
    #expect(VoiceEdits.apply("replace world", to: "Hello world") == nil)
}

@Test func voiceEditsApplyOneExactTargetAndRejectMissingTargets() {
    #expect(
        VoiceEdits.outcome("Sayso replace world with Stevie", to: "world world")
            == .applied("Stevie world")
    )
    #expect(
        VoiceEdits.outcome("Sayso delete missing", to: "Hello world")
            == .targetNotFound
    )
}

@Test func textOutputTargetIdentityRequiresCurrentAppAndFocusedFieldForEveryDelivery() {
    let start = Date(timeIntervalSinceReferenceDate: 123)
    let captured = TextOutputTargetIdentity(
        processIdentifier: 42,
        bundleIdentifier: "ai.sayso.target",
        launchDate: start
    )

    #expect(captured.matches(captured))
    #expect(captured.allowsDelivery(to: captured, isFrontmost: true, capturedFieldOwnsFocus: true))
    #expect(!captured.allowsDelivery(to: captured, isFrontmost: false, capturedFieldOwnsFocus: true))
    #expect(!captured.allowsDelivery(to: captured, isFrontmost: true, capturedFieldOwnsFocus: false))
    #expect(
        !captured.matches(.init(
            processIdentifier: 42,
            bundleIdentifier: "ai.sayso.reused",
            launchDate: start
        ))
    )
    #expect(
        !captured.matches(.init(
            processIdentifier: 42,
            bundleIdentifier: "ai.sayso.target",
            launchDate: start.addingTimeInterval(1)
        ))
    )
}

@Test func historyInsightsCountWordsAndDays() {
    let entries = [Transcript(text: "two words", language: .english, route: .local, isFinal: true)]
    #expect(HistoryInsights.make(from: entries).words == 2)
    #expect(HistoryInsights.make(from: entries).activeDays == 1)
}

@Test func historyClearRemovesPersistedEntries() async {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = HistoryStore(fileURL: file)
    await store.append(Transcript(text: "private note", language: .english, route: .local, isFinal: true))
    #expect(await store.all().count == 1)
    await store.clear()
    #expect(await store.all().isEmpty)
}

@Test func historyExportUsesTranslatedText() async {
    let store = HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    await store.append(Transcript(text: "hello", translatedText: "नमस्ते", language: .english, route: .local, isFinal: true))
    #expect(await store.plainTextExport().contains("नमस्ते"))
}

@Test func controlRejectsLowConfidence() {
    let step = ControlPlanStep(
        action: .scroll(lines: 1, expectedFingerprint: "target"), confidence: 0.59, reason: "uncertain target"
    )
    #expect(!ControlPolicy.canAutoRun(step))
}

@Test func controlAllowsConfiguredThreshold() {
    let step = ControlPlanStep(
        action: .scroll(lines: 1, expectedFingerprint: "target"), confidence: 0.60, reason: "grounded"
    )
    #expect(ControlPolicy.canAutoRun(step))
}

@Test func controlOutcomeRequiresObservedEffect() {
    let before = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "before", isProtected: false
    )
    let type = DesktopAction.type(text: "after", expectedFingerprint: before.fingerprint)
    #expect(ControlOutcome.result(for: type, before: before, after: before) == "no observed text change")

    let after = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "after", isProtected: false
    )
    #expect(ControlOutcome.result(for: type, before: before, after: after) == "observed text change")
}

@Test func controlObservationStopsAtFirstObservedRecapture() async throws {
    actor Snapshots {
        private var values: [DesktopSnapshot]
        private(set) var captures = 0

        init(_ values: [DesktopSnapshot]) {
            self.values = values
        }

        func capture() -> DesktopSnapshot? {
            captures += 1
            return values.isEmpty ? nil : values.removeFirst()
        }
    }

    let before = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "before", isProtected: false
    )
    let after = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "after", isProtected: false
    )
    let snapshots = Snapshots([before, after, after])
    let observation = try await ControlObservation.observe(
        maximumAttempts: 3,
        interval: .zero,
        capture: { await snapshots.capture() },
        hasObservedEffect: { $0.focusedValue != before.focusedValue }
    )

    #expect(observation.effectObserved)
    #expect(observation.attempts == 2)
    #expect(observation.snapshot == after)
    #expect(await snapshots.captures == 2)
}

@Test func controlObservationReturnsLastRecaptureAtBound() async throws {
    actor Snapshots {
        private var captures = 0
        private let snapshot: DesktopSnapshot

        init(_ snapshot: DesktopSnapshot) {
            self.snapshot = snapshot
        }

        func capture() -> DesktopSnapshot {
            captures += 1
            return snapshot
        }

        func captureCount() -> Int { captures }
    }

    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "same", isProtected: false
    )
    let snapshots = Snapshots(snapshot)
    let observation = try await ControlObservation.observe(
        maximumAttempts: 2,
        interval: .zero,
        capture: { await snapshots.capture() },
        hasObservedEffect: { _ in false }
    )

    #expect(!observation.effectObserved)
    #expect(observation.attempts == 2)
    #expect(observation.snapshot == snapshot)
    #expect(await snapshots.captureCount() == 2)
}

@Test func controlOutcomeRequiresObservedApplicationEffect() {
    let before = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false
    )
    let action = DesktopAction.activate(bundleIdentifier: "com.apple.Safari")

    #expect(ControlOutcome.result(for: action, before: before, after: nil) == "unknown effect")
    #expect(ControlOutcome.result(for: action, before: before, after: nil, externalEffectObserved: false) == "no observed target active")
    #expect(ControlOutcome.result(for: action, before: before, after: nil, externalEffectObserved: true) == "observed target active")
}

@Test func externalControlEffectsRequireExactTargetAndNavigation() {
    let targetURL = URL(string: "https://example.com/docs?version=1#read")!

    #expect(ControlExternalEffect.isTargetActive(observedProcessIdentifier: 42, targetProcessIdentifier: 42))
    #expect(!ControlExternalEffect.isTargetActive(observedProcessIdentifier: 43, targetProcessIdentifier: 42))
    #expect(ControlExternalEffect.isProcessTerminated(targetProcessIdentifier: 42, runningProcessIdentifiers: [43]))
    #expect(!ControlExternalEffect.isProcessTerminated(targetProcessIdentifier: 42, runningProcessIdentifiers: [42, 43]))
    #expect(ControlExternalEffect.openedTarget(
        targetBundleIdentifier: "com.apple.Safari",
        observedBundleIdentifier: "com.apple.Safari",
        targetURL: targetURL,
        observedURL: targetURL
    ))
    #expect(!ControlExternalEffect.openedTarget(
        targetBundleIdentifier: "com.apple.Safari",
        observedBundleIdentifier: "com.google.Chrome",
        targetURL: targetURL,
        observedURL: targetURL
    ))
    #expect(!ControlExternalEffect.openedTarget(
        targetBundleIdentifier: "com.apple.Safari",
        observedBundleIdentifier: "com.apple.Safari",
        targetURL: targetURL,
        observedURL: URL(string: "https://example.com/other?version=1#read")!
    ))
}

@Test func controlPlannerGroundsTypeAgainstCurrentTarget() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false
    )
    let plan = try ControlPlanner.plan(command: "type hello", snapshot: snapshot)
    #expect(plan.action == .type(text: "hello", expectedFingerprint: snapshot.fingerprint))
    #expect(plan.confidence >= ControlPolicy.minimumConfidence)
}

@Test func controlPlannerRejectsUnsafeOrAmbiguousCommands() {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false
    )
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "delete everything", snapshot: snapshot) }
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "open example.com", snapshot: snapshot) }
}

@Test func controlPlannerUsesOnlyExactVisibleControlTitle() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false,
        elements: [.init(id: "AXButton|Send", role: "AXButton", title: "Send")]
    )
    let plan = try ControlPlanner.plan(command: "click Send", snapshot: snapshot)
    #expect(plan.action == .press(elementID: "AXButton|Send", expectedFingerprint: snapshot.fingerprint))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "click sen", snapshot: snapshot) }
}

@Test func controlPlannerRequiresReviewForDestructiveVisibleControl() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Mail", windowTitle: "Compose",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false,
        elements: [.init(id: "stable-send", role: "AXButton", title: "Send")]
    )

    let step = try ControlPlanner.plan(command: "click Send", snapshot: snapshot)
    #expect(ControlPolicy.requiresConfirmation(step))
}

@Test func controlPlannerRequiresExactBundleIdentifier() throws {
    let snapshot = DesktopSnapshot(processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft", focusedRole: "AXTextField", focusedValue: "", isProtected: false)
    #expect(try ControlPlanner.plan(command: "activate com.apple.Safari", snapshot: snapshot).action == .activate(bundleIdentifier: "com.apple.Safari"))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "quit Safari", snapshot: snapshot) }
}
