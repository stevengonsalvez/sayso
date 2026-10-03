import SwiftUI
import SaysoCore

/// Gallery window root: the scenario browser and the interactive notch simulator as sibling tabs.
public struct SaysoGalleryRootView: View {
    public enum Tab: Hashable, CaseIterable, Sendable {
        case browser, simulator

        public var title: String {
            switch self {
            case .browser: "Browser"
            case .simulator: "Simulator"
            }
        }
    }

    public let scenarios: [SaysoGalleryScenario]
    @State private var tab: Tab

    public init(scenarios: [SaysoGalleryScenario], initialTab: Tab = .browser) {
        self.scenarios = scenarios
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            SaysoGalleryView(scenarios: scenarios)
                .tabItem { Label(Tab.browser.title, systemImage: "square.grid.2x2") }
                .tag(Tab.browser)
            SaysoNotchSimulatorView()
                .tabItem { Label(Tab.simulator.title, systemImage: "rectangle.topthird.inset.filled") }
                .tag(Tab.simulator)
        }
    }
}
