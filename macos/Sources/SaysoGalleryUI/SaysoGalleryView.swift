import SwiftUI
import SaysoCore

/// Browser for synthetic scenarios: sidebar filters (module, surface, health, accessibility)
/// and a grid of fixed-size cards grouped by surface.
public struct SaysoGalleryView: View {
    public let scenarios: [SaysoGalleryScenario]
    @State private var filter = SaysoGalleryFilter()
    @State private var lastAction: String?

    public init(scenarios: [SaysoGalleryScenario]) {
        self.scenarios = scenarios
    }

    private var visible: [SaysoGalleryScenario] { filter.apply(to: scenarios) }
    private var moduleOptions: [(id: String, title: String)] {
        var seen = Set<String>()
        return scenarios.compactMap { seen.insert($0.moduleID).inserted ? ($0.moduleID, $0.title) : nil }
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            results
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.06))
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Filters").font(.headline)
                    Spacer()
                    Button("Reset") { filter = SaysoGalleryFilter() }.disabled(!filter.isActive)
                }
                group("Module", options: moduleOptions.map { ($0.id, $0.title) }, selection: $filter.moduleIDs)
                group("Surface", options: SaysoModuleSurface.allCases.map { ($0, $0.rawValue.capitalized) },
                      selection: $filter.surfaces)
                group("Health", options: [SaysoModuleHealth.ready, .disabled, .permissionRequired,
                                          .degraded, .failed, .quarantined].map { ($0, SaysoGalleryView.label($0)) },
                      selection: $filter.healths)
                group("Accessibility", options: SaysoAccessibilityMode.allCases.map { ($0, SaysoGalleryView.label($0)) },
                      selection: $filter.accessibility)
            }
            .padding(16)
        }
    }

    private func group<T: Hashable>(
        _ title: String, options: [(T, String)], selection: Binding<Set<T>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(options, id: \.0) { option, label in
                Toggle(label, isOn: Binding(
                    get: { selection.wrappedValue.contains(option) },
                    set: { on in
                        if on { selection.wrappedValue.insert(option) } else { selection.wrappedValue.remove(option) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(visible.count) of \(scenarios.count) scenarios")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(lastAction ?? "No action yet")
                    .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    .accessibilityLabel("Last action: \(lastAction ?? "none")")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if visible.isEmpty {
                Text("No scenarios match these filters.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                        ForEach(SaysoModuleSurface.allCases, id: \.self) { surface in
                            let items = visible.filter { $0.surface == surface }
                            if !items.isEmpty { section(surface, items) }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func section(_ surface: SaysoModuleSurface, _ items: [SaysoGalleryScenario]) -> some View {
        let width = SaysoGalleryScenarioCard.size(for: surface).width
        return VStack(alignment: .leading, spacing: 12) {
            Text(surface.rawValue.capitalized).font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 16, alignment: .topLeading)],
                      alignment: .leading, spacing: 20) {
                ForEach(items, id: \.id) { scenario in
                    VStack(alignment: .leading, spacing: 6) {
                        SaysoGalleryScenarioCard(
                            scenario: scenario,
                            onGrant: { lastAction = SaysoGalleryCardPresentation.actionSummary(.grant, scenarioID: scenario.id) },
                            onRetry: { lastAction = SaysoGalleryCardPresentation.actionSummary(.retry, scenarioID: scenario.id) }
                        )
                        Text(scenario.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).frame(width: width, alignment: .leading)
                    }
                }
            }
        }
    }

    static func label(_ health: SaysoModuleHealth) -> String {
        switch health {
        case .ready: "Ready"
        case .disabled: "Disabled"
        case .permissionRequired: "Permission required"
        case .degraded: "Degraded"
        case .failed: "Failed"
        case .quarantined: "Quarantined"
        }
    }

    static func label(_ mode: SaysoAccessibilityMode) -> String {
        switch mode {
        case .standard: "Standard"
        case .reduceMotion: "Reduce Motion"
        case .increaseContrast: "Increase Contrast"
        }
    }
}
