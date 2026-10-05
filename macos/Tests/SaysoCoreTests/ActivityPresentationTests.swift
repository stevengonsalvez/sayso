import Foundation
import Testing
@testable import SaysoCore

private func activity(
    _ kind: SaysoActivityKind, title: String = "Title", progress: Double? = nil, actions: [SaysoAction] = []
) -> SaysoActivity {
    SaysoActivity(moduleID: "m", stackID: "s", kind: kind, title: title, actions: actions, progress: progress)
}

@Test func kindMapsToASemanticToneAndSymbol() {
    #expect(SaysoActivityPresentation(activity(.failure)).tone == .critical)
    #expect(SaysoActivityPresentation(activity(.confirmation)).tone == .attention)
    #expect(SaysoActivityPresentation(activity(.completion)).tone == .success)
    #expect(SaysoActivityPresentation(activity(.activeTask)).tone == .active)
    #expect(SaysoActivityPresentation(activity(.ambient)).tone == .quiet)
    #expect(SaysoActivityPresentation(activity(.background)).tone == .quiet)
    let symbols = Set(SaysoActivityKind.allCases.map { SaysoActivityPresentation(activity($0)).symbolName })
    #expect(symbols.count == SaysoActivityKind.allCases.count, "every kind has its own symbol")
}

@Test func progressShowsAsAWholePercentSubtitleAndAccessibilityValue() {
    let p = SaysoActivityPresentation(activity(.activeTask, title: "Downloading English model", progress: 0.456))
    #expect(p.subtitle == "46%")
    #expect(p.accessibilityLabel == "Downloading English model, 46 percent")
    #expect(SaysoActivityPresentation(activity(.activeTask, progress: 1)).subtitle == "100%")
    #expect(SaysoActivityPresentation(activity(.activeTask)).subtitle == nil)
    #expect(SaysoActivityPresentation(activity(.activeTask, title: "Plain")).accessibilityLabel == "Plain")
}

@Test func actionsKeepTheirOrderAndTheFirstIsPrimary() {
    let p = SaysoActivityPresentation(activity(
        .activeTask, actions: [SaysoAction(id: "accept", title: "Remember"), SaysoAction(id: "dismiss", title: "Dismiss")]
    ))
    #expect(p.actions.map(\.id) == ["accept", "dismiss"])
    #expect(p.primaryActionID == "accept")
    #expect(SaysoActivityPresentation(activity(.ambient)).primaryActionID == nil)
}
