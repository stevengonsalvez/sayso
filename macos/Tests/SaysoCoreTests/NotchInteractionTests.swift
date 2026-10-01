import Testing
@testable import SaysoCore

@Test func expandedNotchCollapsesOnlyFromPassiveOrOutsideRegions() {
    #expect(NotchCollapsePolicy.shouldCollapse(on: .background))
    #expect(NotchCollapsePolicy.shouldCollapse(on: .status))
    #expect(NotchCollapsePolicy.shouldCollapse(on: .footer))
    #expect(NotchCollapsePolicy.shouldCollapse(on: .outside))
    #expect(!NotchCollapsePolicy.shouldCollapse(on: .control))
}
