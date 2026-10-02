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
            #expect(!result.tapRunsPrimaryAction)
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
    #expect(idle.tapRunsPrimaryAction)
    #expect(idle.dismissActionID == nil)

    #expect(status(partial: "hello", primary: retry).text == "hello")
    #expect(status(notice: "Saved", primary: retry).text == "Saved")
    #expect(!status(live: true, primary: retry).tapRunsPrimaryAction)
}

@Test func controlModeShowsControlStatusAndOtherwiseDictationDefaults() {
    #expect(status(control: true, controlStatus: "Planned: open", primary: retry).text == "Planned: open")
    #expect(status().text == "Ready to dictate into the focused app")
    #expect(status(live: true).text == "Listening for dictation")
    #expect(!status(control: true, controlStatus: "Planned: open", primary: retry).tapRunsPrimaryAction)
}
