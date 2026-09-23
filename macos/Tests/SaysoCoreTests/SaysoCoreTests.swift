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
    #expect(!settings.voiceEditCloudConsent)
    #expect(settings.byokRewriteModel == "gpt-4.1-mini")
    #expect(!settings.legacyLexiconMigrated)
    #expect(!settings.autoCorrectionsEnabled)
    #expect(settings.autoCorrectionsPromotionThreshold == 3)
    #expect(!settings.cleanupEnabled)
    #expect(!settings.cloudCleanupEnabled)
    #expect(settings.byokCleanupModel == "gpt-4.1-mini")
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

@Test func onboardingReadinessRequiresSelectedEngineAndPermissions() {
    #expect(!OnboardingReadiness.engineIsReady(
        route: .local, language: .automatic, hasLocalModel: true, cloudConsentGranted: false
    ))
    #expect(OnboardingReadiness.engineIsReady(
        route: .local, language: .english, hasLocalModel: true, cloudConsentGranted: false
    ))
    #expect(!OnboardingReadiness.engineIsReady(
        route: .appleSpeech, language: .english, hasLocalModel: false, cloudConsentGranted: false
    ))
    #expect(OnboardingReadiness.engineIsReady(
        route: .appleSpeech, language: .english, hasLocalModel: false, cloudConsentGranted: true
    ))
    #expect(OnboardingReadiness.hasRequiredPermissions(
        route: .local, microphoneGranted: true, speechRecognitionGranted: false
    ))
    #expect(!OnboardingReadiness.hasRequiredPermissions(
        route: .appleSpeech, microphoneGranted: true, speechRecognitionGranted: false
    ))
    #expect(OnboardingReadiness.hasRequiredPermissions(
        route: .appleSpeech, microphoneGranted: true, speechRecognitionGranted: true
    ))
}

@Test func lexiconCorrectionsApplyBeforeOutput() {
    #expect(LexiconCorrections.apply("Ship say so", replacements: ["say so": "Sayso"]) == "Ship Sayso")
}

@Test func selectedTextEditAnchorRequiresExactUTF16Selection() throws {
    let value = "Hi 👋 Stevie"
    let location = "Hi 👋 ".utf16.count
    let range = TextUTF16Range(location: location, length: "Stevie".utf16.count)
    let anchor = try #require(SelectedTextEditAnchor(value: value, range: range))

    #expect(anchor.selectedText == "Stevie")
    #expect(anchor.stillMatches(value: value, range: range))
    #expect(!anchor.stillMatches(value: value, range: .init(location: 0, length: "Stevie".utf16.count)))
    #expect(!anchor.stillMatches(value: "Hi 👋 Steven", range: range))
    #expect(anchor.replacing(with: "team", in: value) == "Hi 👋 team")
    #expect(anchor.replacing(with: "team", in: "Yo 👋 Stevie") == "Yo 👋 team")
    #expect(SelectedTextEditAnchor(value: value, range: .init(location: location, length: 0)) == nil)
    #expect(SelectedTextEditAnchor(value: value, range: .init(location: value.utf16.count, length: 1)) == nil)
    #expect(SelectedTextEditAnchor(value: value, range: .init(location: 4, length: 1)) == nil)

    let decomposed = "Cafe\u{301}"
    let accent = try #require(SelectedTextEditAnchor(
        value: decomposed,
        range: .init(location: "Caf".utf16.count, length: "e\u{301}".utf16.count)
    ))
    #expect(accent.selectedText == "e\u{301}")
    #expect(accent.replacing(with: "é", in: decomposed) == "Café")

    let flag = "A 🇮🇳 B"
    let flagRange = TextUTF16Range(location: "A ".utf16.count, length: "🇮🇳".utf16.count)
    let flagAnchor = try #require(SelectedTextEditAnchor(value: flag, range: flagRange))
    #expect(flagAnchor.selectedText == "🇮🇳")
    #expect(flagAnchor.replacing(with: "🇬🇧", in: flag) == "A 🇬🇧 B")
}

@Test func selectedTextEditUnverifiedWriteDoesNotAskForPaste() {
    #expect(SelectedTextEdit.ApplyResult.replacementUnverified.userMessage.contains("copied to clipboard") == false)
}

@Test func providerEndpointsRequireHTTPSOutsideLocalhost() throws {
    #expect(ProviderEndpointPolicy.allows(try #require(URL(string: "https://api.example.com/v1"))))
    #expect(ProviderEndpointPolicy.allows(try #require(URL(string: "http://localhost:11434/v1"))))
    #expect(ProviderEndpointPolicy.allows(try #require(URL(string: "http://[::1]:11434/v1"))))
    #expect(!ProviderEndpointPolicy.allows(try #require(URL(string: "http://api.example.com/v1"))))
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
    #expect(VoiceEdits.apply("Sayso delete world", to: "Hello world") == "Hello")
    #expect(VoiceEdits.apply("replace world", to: "Hello world") == nil)
}

@Test func voiceEditsApplyEveryExactTargetAndRejectMissingTargets() {
    #expect(
        VoiceEdits.outcome("Sayso replace world with Stevie", to: "world world")
            == .applied("Stevie Stevie")
    )
    #expect(
        VoiceEdits.outcome("Sayso delete missing", to: "Hello world")
            == .targetNotFound
    )
}

@Test func voiceEditsMatchWholeTokensOnly() {
    #expect(VoiceEdits.outcome("Sayso delete cat", to: "concatenate cat cat") == .applied("concatenate"))
    #expect(VoiceEdits.outcome("Sayso delete cat", to: "one cat two cat three") == .applied("one two three"))
    #expect(VoiceEdits.outcome("Sayso delete cat", to: "concatenate") == .targetNotFound)
    #expect(VoiceEdits.outcome("Sayso replace art with craft", to: "start art artful art") == .applied("start craft artful craft"))
    #expect(VoiceEdits.outcome("Sayso replace new york with Delhi", to: "I love New York.") == .applied("I love Delhi."))
    #expect(VoiceEdits.outcome("Sayso delete world", to: "world's end") == .targetNotFound)
    #expect(VoiceEdits.outcome("Sayso delete world", to: "world’s end") == .targetNotFound)
    #expect(VoiceEdits.outcome("Sayso delete very", to: "a very good day") == .applied("a good day"))
    #expect(VoiceEdits.outcome("Sayso delete Hello", to: "Hello world") == .applied("world"))
    #expect(VoiceEdits.outcome("Sayso delete world", to: "Hello world.") == .applied("Hello."))
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

@Test func clipboardRestorePreservesUserChangesAndCoalescesOwnedPastes() {
    #expect(ClipboardRestorePolicy.ownsPasteboard(expectedChangeCount: 8, currentChangeCount: 8))
    #expect(!ClipboardRestorePolicy.ownsPasteboard(expectedChangeCount: 8, currentChangeCount: 9))
}

@MainActor
@Test func pasteFailureMessagesMatchVerifiedClipboardOutcomes() {
    let retained = TextOutput.PasteFailure.finalTextCopiedToClipboard
    #expect(retained.fallbackDelivery == .clipboard)
    #expect(retained.userMessage == "Could not paste final text. Final text copied to clipboard.")

    let restored = TextOutput.PasteFailure.clipboardRestored
    #expect(restored.fallbackDelivery == nil)
    #expect(restored.userMessage == "Could not paste final text. Clipboard was restored.")

    let changed = TextOutput.PasteFailure.clipboardChangedBeforeRestore
    #expect(changed.fallbackDelivery == nil)
    #expect(changed.userMessage == "Could not paste final text. Clipboard changed before Sayso could restore it.")

    let restoreFailed = TextOutput.PasteFailure.clipboardRestoreFailed
    #expect(restoreFailed.fallbackDelivery == nil)
    #expect(restoreFailed.userMessage == "Could not paste final text. Clipboard could not be restored.")

    let unavailable = TextOutput.PasteFailure.clipboardUnavailable
    #expect(unavailable.fallbackDelivery == nil)
    #expect(unavailable.userMessage == "Could not paste final text or copy it to the clipboard.")
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

@Test func historyExportFallsBackFromWhitespaceTranslation() async {
    let store = HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    await store.append(Transcript(text: "hello", translatedText: "   ", language: .english, route: .local, isFinal: true))
    #expect(await store.plainTextExport().contains("hello"))
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
    #expect(ControlOutcome.effect(for: type, before: before, after: before) == .notObserved)
    #expect(ControlOutcome.effect(for: type, before: before, after: nil) == .unknown)

    let after = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "after", isProtected: false
    )
    #expect(ControlOutcome.effect(for: type, before: before, after: after) == .observed)
    #expect(ControlOutcome.result(for: type, effect: .observed) == "observed text change")
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

    #expect(ControlOutcome.effect(for: action, before: before, after: before) == .unknown)
    #expect(ControlOutcome.effect(for: action, before: before, after: nil, externalEffect: .notObserved) == .notObserved)
    #expect(ControlOutcome.result(for: action, effect: .unknown) == "unknown effect")
    #expect(ControlOutcome.result(for: action, effect: .notObserved) == "no observed target active")
    #expect(ControlOutcome.result(for: action, effect: .observed) == "observed target active")
}

@Test func externalControlEffectsRequireExactTargetAndNavigation() {
    let targetURL = URL(string: "https://example.com/docs?version=1#read")!

    #expect(ControlExternalEffect.isTargetActive(observedProcessIdentifier: 42, targetProcessIdentifier: 42))
    #expect(!ControlExternalEffect.isTargetActive(observedProcessIdentifier: 43, targetProcessIdentifier: 42))
    #expect(ControlExternalEffect.isProcessTerminated(targetProcessIdentifier: 42, runningProcessIdentifiers: [43]))
    #expect(!ControlExternalEffect.isProcessTerminated(targetProcessIdentifier: 42, runningProcessIdentifiers: [42, 43]))
    #expect(openOutcome(beforeURL: nil, observedURL: targetURL) == .navigated)
    #expect(openOutcome(beforeURL: URL(string: "https://example.com/")!, observedURL: targetURL) == .navigated)
    #expect(openOutcome(beforeURL: nil, targetWasFrontmost: true, observedURL: targetURL) == .targetAlreadyActive)
    #expect(openOutcome(beforeURL: nil, targetWasFrontmost: true, observedURL: targetURL).effect == .unknown)
    #expect(openOutcome(beforeURL: nil, observedBundle: "com.google.Chrome", observedURL: targetURL) == .notObserved)
    #expect(openOutcome(beforeURL: nil, observedURL: nil) == .notObserved)
}

@Test func openNavigationDoesNotClaimAlreadyOpenOrRedirectedTargets() {
    let targetURL = URL(string: "https://example.com/docs?version=1#read")!
    let redirected = URL(string: "https://www.example.com/docs?version=1#read")!
    let previous = URL(string: "https://news.example.org/")!

    #expect(openOutcome(beforeURL: targetURL, observedURL: targetURL) == .alreadyOpen)
    #expect(openOutcome(beforeURL: targetURL, observedURL: targetURL).effect == .unknown)
    #expect(openOutcome(beforeURL: previous, observedURL: redirected) == .differentURL(redirected))
    #expect(openOutcome(beforeURL: previous, observedURL: redirected).effect == .unknown)
    #expect(openOutcome(beforeURL: previous, observedURL: previous) == .notObserved)
    #expect(openOutcome(beforeURL: previous, observedURL: previous).effect == .notObserved)
}

private func openOutcome(
    beforeURL: URL?,
    targetWasFrontmost: Bool = false,
    observedBundle: String = "com.apple.Safari",
    observedURL: URL?
) -> OpenNavigationOutcome {
    ControlExternalEffect.openNavigation(
        targetBundleIdentifier: "com.apple.Safari",
        targetURL: URL(string: "https://example.com/docs?version=1#read")!,
        targetWasFrontmost: targetWasFrontmost,
        beforeURL: beforeURL,
        observedBundleIdentifier: observedBundle,
        observedURL: observedURL
    )
}

@Test func controlSessionStepResultComesFromTypedEffect() {
    #expect(ControlSessionStepResult(ControlEffect.observed) == .effectObserved)
    #expect(ControlSessionStepResult(ControlEffect.notObserved) == .noEffectObserved)
    #expect(ControlSessionStepResult(ControlEffect.unknown) == .effectUnknown)
}

@Test func controlAuditEntryDecodesLegacyEntriesAsUnknownEffect() throws {
    let entry = ControlAuditEntry(
        action: .activate(bundleIdentifier: "com.apple.Safari"),
        beforeFingerprint: "before", afterFingerprint: nil,
        effect: .notObserved, result: "observed target active"
    )
    let encoded = try JSONEncoder().encode(entry)
    #expect(try JSONDecoder().decode(ControlAuditEntry.self, from: encoded).effect == .notObserved)

    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy["effect"] = nil
    let decoded = try JSONDecoder().decode(
        ControlAuditEntry.self, from: JSONSerialization.data(withJSONObject: legacy)
    )
    #expect(decoded.effect == .unknown)
    #expect(decoded.result == "observed target active")
}

@Test func permissionInteractionsKeepDecidedDictationInTargetAndRefreshSettingsGrants() {
    for kind in [PermissionKind.microphone, .speechRecognition] {
        #expect(PermissionCenter.needsSystemPrompt(kind, state: .undetermined))
        #expect(!PermissionCenter.needsSystemPrompt(kind, state: .granted))
        #expect(!PermissionCenter.needsSystemPrompt(kind, state: .denied))
        #expect(PermissionCenter.interaction(for: kind, state: .granted) == .none)
        #expect(PermissionCenter.interaction(for: kind, state: .denied) == .systemSettings)
    }
    for kind in [PermissionKind.accessibility, .inputMonitoring] {
        #expect(!PermissionCenter.needsSystemPrompt(kind, state: .denied))
        #expect(PermissionCenter.interaction(for: kind, state: .denied) == .systemSettings)
    }
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
    #expect(throws: SaysoError.self) {
        try ControlPlanner.plan(command: "open example.com", snapshot: snapshot, installedApplications: [])
    }
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
    #expect(step.candidateTitle == "Send")
    #expect(ControlPolicy.requiresConfirmation(step))
}

@Test func controlPlannerSeparatesBoundedCommandStepsWithoutSplittingTypedText() throws {
    #expect(try ControlPlanner.commands(from: "scroll down then scroll up") == ["scroll down", "scroll up"])
    #expect(try ControlPlanner.commands(from: "scroll down Then scroll up") == ["scroll down", "scroll up"])
    #expect(try ControlPlanner.commands(from: "type now and then later") == ["type now and then later"])
    #expect(try ControlPlanner.commands(from: "scroll down then type now and then later") == ["scroll down", "type now and then later"])
    #expect(throws: SaysoError.self) { try ControlPlanner.commands(from: "scroll down then ") }
    let overBudget = Array(repeating: "scroll down", count: ControlSessionLimits().maxActions + 1).joined(separator: " then ")
    #expect(throws: SaysoError.self) { try ControlPlanner.commands(from: overBudget) }
}

@Test func controlPlannerAllowsOnlyReviewedNavigationKeys() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false
    )
    let enter = try ControlPlanner.plan(command: "press enter", snapshot: snapshot)
    #expect(enter.action == .key(.return, expectedFingerprint: snapshot.fingerprint))
    #expect(enter.reason == "Press return")
    #expect(ControlPolicy.requiresConfirmation(enter))
    #expect(try ControlPlanner.plan(command: "press left arrow", snapshot: snapshot).action == .key(.left, expectedFingerprint: snapshot.fingerprint))
    #expect(try ControlPlanner.plan(command: "press esc", snapshot: snapshot).action == .key(.escape, expectedFingerprint: snapshot.fingerprint))
    #expect(try ControlPlanner.plan(command: "press tab", snapshot: snapshot).action == .key(.tab, expectedFingerprint: snapshot.fingerprint))
    let goBack = try ControlPlanner.plan(command: "go back", snapshot: snapshot)
    #expect(goBack.action == .key(.goBack, expectedFingerprint: snapshot.fingerprint))
    #expect(goBack.reason == "Go back")
    #expect(ControlPolicy.requiresConfirmation(goBack))
    let nextTab = try ControlPlanner.plan(command: "next tab", snapshot: snapshot)
    #expect(nextTab.action == .key(.nextTab, expectedFingerprint: snapshot.fingerprint))
    #expect(nextTab.reason == "Next tab")
    #expect(ControlPolicy.requiresConfirmation(nextTab))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "press command q", snapshot: snapshot) }
    #expect(ControlOutcome.effect(for: enter.action, before: snapshot, after: snapshot) == .unknown)
}

@Test func destructivePressPolicyUsesCapturedTitleNotOpaqueLocator() throws {
    let snapshot = DesktopSnapshot(
        processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft",
        focusedRole: "AXTextField", focusedValue: "", isProtected: false,
        elements: [.init(id: "opaque-base64-locator", role: "AXButton", title: "Save")]
    )
    let safeStep = try ControlPlanner.plan(command: "click Save", snapshot: snapshot)
    let unlabelledStep = ControlPlanStep(
        action: .press(elementID: "opaque-base64-locator", expectedFingerprint: snapshot.fingerprint),
        confidence: 0.85,
        reason: "Opaque press"
    )

    #expect(!ControlPolicy.requiresConfirmation(safeStep))
    #expect(ControlPolicy.requiresConfirmation(unlabelledStep))
    #expect(unlabelledStep.action.isDestructive)
    #expect(ControlPolicy.isDestructiveControlTitle("DeleteAccount"))
    #expect(ControlPolicy.isDestructiveControlTitle("Resend"))
    #expect(ControlPolicy.isDestructiveControlTitle("Deleting account"))
    #expect(ControlPolicy.isDestructiveControlTitle("Payment"))
    #expect(ControlPolicy.isDestructiveControlTitle("Unsend"))
    #expect(ControlPolicy.isDestructiveControlTitle("Deletes"))
    #expect(ControlPolicy.isDestructiveControlTitle("Closing window"))
    #expect(ControlPolicy.isDestructiveControlTitle("Submitted"))
    #expect(ControlPolicy.isDestructiveControlTitle("Cancelled"))
    #expect(ControlPolicy.isDestructiveControlTitle("Sent"))
    #expect(!ControlPolicy.isDestructiveControlTitle("Sender"))
}

@Test func controlPlannerRequiresExactBundleIdentifier() throws {
    let snapshot = DesktopSnapshot(processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft", focusedRole: "AXTextField", focusedValue: "", isProtected: false)
    #expect(try ControlPlanner.plan(command: "activate com.apple.Safari", snapshot: snapshot).action == .activate(bundleIdentifier: "com.apple.Safari"))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "quit Safari", snapshot: snapshot) }
}
