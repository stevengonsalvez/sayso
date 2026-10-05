import Foundation
import Testing
@testable import SaysoCore

private let review = SaysoActivity(
    moduleID: "control", stackID: "confirmation", kind: .confirmation, title: "Review required: Delete file",
    actions: [SaysoAction(id: "approve", title: "Approve"), SaysoAction(id: "deny", title: "Deny")],
    interruption: .critical
)
private let retry = SaysoActivity(
    moduleID: "models", stackID: "install-m", kind: .failure, title: "Could not install Model",
    actions: [SaysoAction(id: "retry", title: "Retry")]
)

private func status(
    partial: String = "", live: Bool = false, control: Bool = false, notice: String? = nil,
    controlStatus: String = "Ready", primary: SaysoActivity? = nil
) -> NotchStatus {
    NotchStatusPolicy.resolve(
        partialText: partial, isLive: live, isControl: control, notice: notice,
        controlStatus: controlStatus, primary: primary
    )
}

@Test func aCriticalReviewShowsInEveryModeWithExplicitButtonsAndNoTapToApprove() {
    for control in [true, false] {
        for live in [true, false] {
            let result = status(partial: "open calc", live: live, control: control, notice: "Saved", controlStatus: "Planned", primary: review)
            #expect(result.text == "Review required: Delete file")
            #expect(result.criticalActions.map(\.id) == ["approve", "deny"])
            #expect(result.tapAction == nil)
        }
    }
}

@Test func theMenuDismissOfACriticalReviewMeansDenyNeverASilentClear() {
    #expect(status(primary: review).dismissActionID == "deny")
    let confirmationWithoutDeny = SaysoActivity(
        moduleID: "x", stackID: "s", kind: .confirmation, title: "Sure?",
        actions: [SaysoAction(id: "approve", title: "Approve")], interruption: .critical
    )
    #expect(status(primary: confirmationWithoutDeny).dismissActionID == nil)
}

@Test func nonCriticalActivityKeepsTheOldPrecedenceAndTapRunsItsFirstAction() {
    let idle = status(primary: retry)
    #expect(idle.text == "Could not install Model")
    #expect(idle.criticalActions.isEmpty)
    #expect(idle.tapAction == NotchTapAction(moduleID: "models", stackID: "install-m", actionID: "retry", title: "Retry"))
    #expect(idle.dismissActionID == nil)

    #expect(status(partial: "hello", primary: retry).text == "hello")
    #expect(status(notice: "Saved", primary: retry).text == "Saved")
    #expect(status(live: true, primary: retry).tapAction == nil)
}

@Test func controlModeShowsControlStatusAndOtherwiseDictationDefaults() {
    #expect(status(control: true, controlStatus: "Planned: open", primary: retry).text == "Planned: open")
    #expect(status().text == "Ready to dictate into the focused app")
    #expect(status(live: true).text == "Listening for dictation")
    #expect(status(control: true, controlStatus: "Planned: open", primary: retry).tapAction == nil)
}

@Test func tappingTheStatusNeverRunsAClarificationChoiceACancelOrAConfirmation() {
    let clarification = SaysoActivity(
        moduleID: "control", stackID: "clarification", kind: .confirmation, title: "Which one: Steve, Steven?",
        actions: [SaysoAction(id: "choice-0", title: "Steve"), SaysoAction(id: "choice-1", title: "Steven")]
    )
    let run = SaysoActivity(
        moduleID: "control", stackID: "run", kind: .activeTask, title: "Control: Open Calculator",
        actions: [SaysoAction(id: "cancel", title: "Cancel")]
    )
    let suggestion = SaysoActivity(
        moduleID: "vocabulary", stackID: "candidate-1", kind: .activeTask, title: "Remember?",
        actions: [SaysoAction(id: "accept", title: "Remember"), SaysoAction(id: "dismiss", title: "Dismiss")]
    )
    #expect(status(primary: clarification).tapAction == nil)
    #expect(status(primary: run).tapAction == nil)
    #expect(status(primary: suggestion).tapAction == nil)
}

@Test func aControlReviewWithStepBoundActionIdsStillOffersDenyAsTheMenuDismiss() {
    let step = UUID()
    let review = SaysoActivity(
        moduleID: "control", stackID: "confirmation", kind: .confirmation, title: "Review required: Delete file",
        actions: [SaysoAction(id: "approve-\(step)", title: "Approve"), SaysoAction(id: "deny-\(step)", title: "Deny")],
        interruption: .critical
    )
    let result = status(primary: review)
    #expect(result.dismissActionID == "deny-\(step)")
    #expect(result.tapAction == nil)
}

/// Controls that belong to an activity may sit beside the status text only while that text is the activity.
@Test func theStatusNamesTheActivityItPaintsSoItsControlsNeverSitBesideOtherText() {
    let track = SaysoActivity(
        moduleID: "now-playing", stackID: "now-playing", kind: .media, title: "Song · Artist · Music",
        actions: [SaysoAction(id: "next", title: "Next")]
    )
    #expect(status(primary: track).activity == track)
    #expect(status(primary: review).activity == review)
    #expect(status(notice: "Saved", primary: track).activity == nil, "a notice replaces the line")
    #expect(status(control: true, controlStatus: "Planned", primary: track).activity == nil, "Control status replaces the line")
    #expect(status(partial: "hello", primary: track).activity == nil, "a dictation preview replaces the line")
}
