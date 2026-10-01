import Foundation
import Testing
@testable import SaysoCore

private let t0 = Date(timeIntervalSince1970: 1_000)
private func at(_ ms: Double) -> Date { t0.addingTimeInterval(ms / 1000) }

@Test func hoverPeeksAfterSixtyMillisecondsAndLeavingClosesAgain() {
    var machine = NotchSurfaceMachine(tabs: ["clip", "timer"])
    #expect(machine.surface == .closed)

    machine.handle(.hoverEntered, at: at(0))
    machine.tick(at: at(59))
    #expect(machine.surface == .closed)
    machine.tick(at: at(60))
    #expect(machine.surface == .peek)

    machine.handle(.hoverExited, at: at(500))
    #expect(machine.surface == .closed)
}

@Test func quickHoverThroughTheNotchNeverPeeks() {
    var machine = NotchSurfaceMachine(tabs: ["clip"])
    machine.handle(.hoverEntered, at: at(0))
    machine.handle(.hoverExited, at: at(30))
    machine.tick(at: at(200))
    #expect(machine.surface == .closed)
}

@Test func clickPinsOpenAndOnlyAnOutsideClickCollapses() {
    var machine = NotchSurfaceMachine(tabs: ["clip"])
    machine.handle(.hoverEntered, at: at(0))
    machine.tick(at: at(80))
    machine.handle(.click(.background), at: at(100))
    #expect(machine.surface == .expanded)

    machine.handle(.hoverExited, at: at(300))
    #expect(machine.surface == .expanded)

    machine.handle(.click(.control), at: at(400))
    #expect(machine.surface == .expanded)
    machine.handle(.click(.outside), at: at(500))
    #expect(machine.surface == .closed)
}

@Test func swipeMovesBetweenTabsAndStopsAtTheEnds() {
    var machine = NotchSurfaceMachine(tabs: ["clip", "timer", "media"])
    machine.handle(.click(.background), at: at(0))
    #expect(machine.selectedTab == "clip")

    machine.handle(.swipe(.next), at: at(10))
    machine.handle(.swipe(.next), at: at(20))
    machine.handle(.swipe(.next), at: at(30))
    #expect(machine.selectedTab == "media")
    machine.handle(.swipe(.previous), at: at(40))
    #expect(machine.selectedTab == "timer")
    machine.handle(.swipe(.previous), at: at(50))
    machine.handle(.swipe(.previous), at: at(60))
    #expect(machine.selectedTab == "clip")
}

@Test func commandNumberJumpsToATabAndIgnoresOutOfRangeNumbers() {
    var machine = NotchSurfaceMachine(tabs: ["clip", "timer"])
    machine.handle(.jump(2), at: at(0))
    #expect(machine.selectedTab == "timer")
    #expect(machine.surface == .expanded)
    machine.handle(.jump(9), at: at(1))
    #expect(machine.selectedTab == "timer")
}

@Test func swipesDoNothingWhileCollapsed() {
    var machine = NotchSurfaceMachine(tabs: ["clip", "timer"])
    machine.handle(.swipe(.next), at: at(0))
    #expect(machine.selectedTab == "clip")
    #expect(machine.surface == .closed)
}

@Test func hiddenPillOpensOnTopEdgeHoverAndHidesAgainOnLeave() {
    var machine = NotchSurfaceMachine(tabs: ["clip"], startsHidden: true)
    #expect(machine.surface == .hidden)
    machine.handle(.topEdgeHover, at: at(0))
    #expect(machine.surface == .closed)
    machine.handle(.hoverExited, at: at(900))
    #expect(machine.surface == .hidden)
}

@Test func removingTheSelectedTabFallsBackToTheFirstAvailable() {
    var machine = NotchSurfaceMachine(tabs: ["clip", "timer"])
    machine.handle(.jump(2), at: at(0))
    machine.setTabs(["clip"])
    #expect(machine.selectedTab == "clip")
    machine.setTabs([])
    #expect(machine.selectedTab == nil)
    #expect(machine.surface == .closed)
}
