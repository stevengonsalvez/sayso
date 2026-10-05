import SwiftUI
import SaysoCore

/// Interactive notch: hover, click, drag-swipe and Cmd-1..9 drive `SaysoNotchSimulatorModel`;
/// a side panel injects scenarios and shows the live arbitration order.
/// Visual grammar matches the scenario cards: hardware-black pill, obsidian glass when expanded,
/// one semantic accent (derived from the primary activity), Reduce Motion honoured.
public struct SaysoNotchSimulatorView: View {
    @StateObject private var model: SaysoNotchSimulatorModel
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: SaysoNotchSimulatorModel = SaysoNotchSimulatorModel()) {
        _model = StateObject(wrappedValue: model)
    }

    /// The simulated clock only needs real time while a hover or an expiry is pending.
    private var needsClock: Bool { isHovering || model.nextExpiryIn != nil }

    public var body: some View {
        HStack(spacing: 0) {
            sidePanel.frame(width: 230)
            Divider()
            stage
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.06))
        .preferredColorScheme(.dark)
        .overlay(shortcuts)
        .task(id: needsClock) { await runClock() }
    }

    private func runClock() async {
        guard needsClock else { return }
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let now = ContinuousClock.now
            let delta = now - last
            last = now
            model.advance(Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1e18)
        }
    }

    // MARK: Tokens

    private var accent: Color {
        switch model.primary?.kind {
        case .confirmation: Color(red: 1.0, green: 0.72, blue: 0.20)
        case .failure: Color(red: 1.0, green: 0.35, blue: 0.35)
        case .completion: Color(red: 0.30, green: 0.80, blue: 0.50)
        case .activeTask, .ambient, .background, nil: Color(red: 0.30, green: 0.56, blue: 1.0)
        }
    }
    private let secondary = Color.white.opacity(0.60)

    private func symbol(_ kind: SaysoActivityKind) -> String {
        switch kind {
        case .confirmation: "exclamationmark.shield.fill"
        case .failure: "xmark.octagon.fill"
        case .completion: "checkmark.circle.fill"
        case .activeTask: "timer"
        case .ambient: "doc.on.clipboard"
        case .background: "clock"
        }
    }

    private func label(_ kind: SaysoActivityKind) -> String {
        switch kind {
        case .confirmation: "Confirmation"
        case .failure: "Failure"
        case .completion: "Completion"
        case .activeTask: "Active task"
        case .ambient: "Ambient"
        case .background: "Background"
        }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .top) {
            Color(red: 0.08, green: 0.09, blue: 0.11)
                .contentShape(Rectangle())
                .onTapGesture { model.click(.outside) }
            notch
            VStack {
                Spacer()
                Text("Hover the notch, click to expand, drag sideways to swipe, Cmd-1 to Cmd-\(model.tabs.count) to jump.")
                    .font(.caption).foregroundStyle(secondary).padding(.bottom, 14)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78), value: model.surface)
    }

    @ViewBuilder
    private var notch: some View {
        switch model.surface {
        case .hidden:
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 160, height: 6)
                .padding(.top, 2)
                .onHover { if $0 { model.topEdgeHover() } }
                .accessibilityLabel("Top edge, hover to reveal the notch")
        case .closed: surfaceShell(width: 200, height: 34, radius: 14, glass: false) { closedContent }
        case .peek: surfaceShell(width: 340, height: 76, radius: 22, glass: false) { peekContent }
        case .expanded: surfaceShell(width: 460, height: 230, radius: 28, glass: true) { expandedContent }
        }
    }

    private func surfaceShell<C: View>(
        width: CGFloat, height: CGFloat, radius: CGFloat, glass: Bool, @ViewBuilder content: () -> C
    ) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0
        )
        return content()
            .frame(width: width, height: height)
            .background {
                if glass {
                    shape.fill(LinearGradient(
                        colors: [
                            Color(red: SaysoGalleryCardPresentation.surfaceTop.r, green: SaysoGalleryCardPresentation.surfaceTop.g,
                                  blue: SaysoGalleryCardPresentation.surfaceTop.b),
                            Color(red: SaysoGalleryCardPresentation.surfaceBottom.r, green: SaysoGalleryCardPresentation.surfaceBottom.g,
                                  blue: SaysoGalleryCardPresentation.surfaceBottom.b),
                        ], startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(Color.black)
                }
            }
            .overlay { shape.strokeBorder(Color.white.opacity(glass ? 0.12 : 0.06), lineWidth: 1) }
            .shadow(color: .black.opacity(glass ? 0.55 : 0.35), radius: glass ? 24 : 10, y: glass ? 14 : 4)
            .contentShape(shape)
            .onHover { inside in
                isHovering = inside
                model.hover(inside ? .entered : .exited)
            }
            .onTapGesture { model.click(.background) }
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width <= -40 { model.swipe(.next) }
                else if value.translation.width >= 40 { model.swipe(.previous) }
            })
            .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notch, \(String(describing: model.surface))")
    }

    // MARK: Surfaces

    private var closedContent: some View {
        HStack(spacing: 8) {
            if let primary = model.primary {
                Image(systemName: symbol(primary.kind)).foregroundStyle(accent)
                Text(primary.title).lineLimit(1).foregroundStyle(.white)
            } else {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 36, height: 4)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 14)
    }

    private var peekContent: some View {
        HStack(spacing: 12) {
            Image(systemName: model.primary.map { symbol($0.kind) } ?? "waveform")
                .font(.title3).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.primary?.title ?? "Nothing active").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(model.primary.map { label($0.kind) } ?? "Idle").font(.caption).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            Button { model.click(.control) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("Play or pause")
        }
        .padding(.horizontal, 18)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(model.tabs.enumerated()), id: \.element) { index, id in
                    let selected = id == model.selectedTab
                    Button { model.jump(index + 1) } label: {
                        Text(model.title(ofTab: id))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(selected ? Color.white : secondary)
                            .background(Capsule().fill(selected ? accent.opacity(0.28) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(model.title(ofTab: id)), tab \(index + 1)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { model.pinnedID == nil ? model.pinPrimary() : model.unpin() } label: {
                    Image(systemName: model.pinnedID == nil ? "pin" : "pin.fill")
                        .foregroundStyle(model.pinnedID == nil ? secondary : accent)
                }
                .buttonStyle(.plain)
                .disabled(model.primary == nil && model.pinnedID == nil)
                .accessibilityLabel(model.pinnedID == nil ? "Pin primary activity" : "Unpin")
            }
            if let primary = model.primary { banner(primary) }
            tabBody
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
    }

    private func banner(_ activity: SaysoActivity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(activity.kind)).font(.title3).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(label(activity.kind)).font(.caption).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            ForEach(activity.actions, id: \.id) { action in
                Button(action.title) {
                    model.click(.control)
                    model.performPrimaryAction(action.id)
                }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private var tabBody: some View {
        let own = model.activityStack.filter { $0.moduleID == model.selectedTab }
        if own.isEmpty {
            Text("No activity in \(model.selectedTab.map(model.title(ofTab:)) ?? "this module")")
                .font(.caption).foregroundStyle(secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(own, id: \.stackID) { activity in
                    Label(activity.title, systemImage: symbol(activity.kind))
                        .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
        }
    }

    // MARK: Keyboard

    /// Invisible buttons own the Cmd-1..9 shortcuts; they never take hits or accessibility focus.
    private var shortcuts: some View {
        ZStack {
            ForEach(1...min(9, max(1, model.tabs.count)), id: \.self) { number in
                Button("Jump to tab \(number)") { model.jump(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Side panel

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Inject") {
                    ForEach(SaysoSimScenario.allCases, id: \.self) { scenario in
                        Button(scenario.title) { model.inject(scenario) }
                    }
                }
                section("Controls") {
                    Button(model.pinnedID == nil ? "Pin primary" : "Unpin") {
                        model.pinnedID == nil ? model.pinPrimary() : model.unpin()
                    }
                    .disabled(model.primary == nil && model.pinnedID == nil)
                    HStack {
                        Button("+1s") { model.advance(1) }
                        Button("+3s") { model.advance(3) }
                    }
                    Text("Clock \(model.now.timeIntervalSinceReferenceDate, specifier: "%.2f")s")
                        .font(.caption.monospaced()).foregroundStyle(secondary)
                }
                section("Arbitration") {
                    if model.arbitration.isEmpty {
                        Text("Nothing active").font(.caption).foregroundStyle(secondary)
                    }
                    ForEach(Array(model.arbitration.enumerated()), id: \.element.id) { index, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.caption).lineLimit(1)
                                Text(label(row.kind) + (row.isPinned ? " · pinned" : ""))
                                    .font(.caption2).foregroundStyle(secondary)
                            }
                            Spacer(minLength: 0)
                            if row.isPrimary { Text("PRIMARY").font(.caption2.weight(.bold)).foregroundStyle(accent) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(16)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(secondary)
            content()
        }
    }
}
