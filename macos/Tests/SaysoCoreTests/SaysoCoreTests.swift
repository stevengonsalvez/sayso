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

@Test func permissionRequestsOpenTheirExactPrivacyPanes() {
    #expect(PermissionKind.microphone.settingsURL.absoluteString.contains("Privacy_Microphone"))
    #expect(PermissionKind.speechRecognition.settingsURL.absoluteString.contains("Privacy_SpeechRecognition"))
    #expect(PermissionKind.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"))
    #expect(PermissionKind.inputMonitoring.settingsURL.absoluteString.contains("Privacy_ListenEvent"))
}

@Test func lexiconCorrectionsApplyBeforeOutput() {
    #expect(LexiconCorrections.apply("Ship say so", replacements: ["say so": "Sayso"]) == "Ship Sayso")
}

@Test func voiceEditsRequireExactCommandShape() {
    #expect(VoiceEdits.apply("Sayso replace world with Stevie", to: "Hello world") == "Hello Stevie")
    #expect(VoiceEdits.apply("Sayso delete world", to: "Hello world") == "Hello ")
    #expect(VoiceEdits.apply("replace world", to: "Hello world") == nil)
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

@Test func controlPlannerRequiresExactBundleIdentifier() throws {
    let snapshot = DesktopSnapshot(processIdentifier: 42, applicationName: "Editor", windowTitle: "Draft", focusedRole: "AXTextField", focusedValue: "", isProtected: false)
    #expect(try ControlPlanner.plan(command: "activate com.apple.Safari", snapshot: snapshot).action == .activate(bundleIdentifier: "com.apple.Safari"))
    #expect(throws: SaysoError.self) { try ControlPlanner.plan(command: "quit Safari", snapshot: snapshot) }
}
