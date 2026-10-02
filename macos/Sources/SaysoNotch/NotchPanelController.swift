import AppKit
import SaysoCore
import SwiftUI

@MainActor
private final class NotchPresentationState: ObservableObject {
    @Published var isCollapsed = true
    @Published var compactWidth: CGFloat = 220
    @Published var expandedWidth: CGFloat = 360
}

@MainActor
final class NotchPanelController {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private let state = NotchPresentationState()
    private weak var model: SaysoAppModel?

    private let expandedHeight: CGFloat = 236
    private let collapsedHeight: CGFloat = 42
    private let notchShoulder: CGFloat = 42
    // 360pt fits the mode picker, status, primary action, and overflow control.
    private let minimumExpandedWidth: CGFloat = 360

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 220, height: 42)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        installClickMonitors()
    }

    func install(model: SaysoAppModel) {
        self.model = model
        reposition()
        panel.contentView = NSHostingView(rootView: NotchHUD(
            model: model,
            state: state,
            toggle: { [weak self] in self?.toggle() },
            dismiss: { [weak self] in self?.dismiss() },
            openApp: { model.showMainWindow() },
            openSettings: { model.openSettings() },
            openOnboarding: { model.openOnboardingWizard() },
            togglePresentation: {
                model.setOverlayPresentation(
                    model.settings.overlayPresentation == .notch ? .floating : .notch
                )
            },
            quit: { model.quit() }
        ))
        panel.orderFrontRegardless()
    }

    func show() {
        hideTask?.cancel()
        state.isCollapsed = false
        reposition()
        panel.orderFrontRegardless()
    }

    func hideAfterDelay() {
        hideTask?.cancel()
        hideTask = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            panel?.orderFrontRegardless()
            self.state.isCollapsed = true
            self.reposition()
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isCollapsed: Bool { state.isCollapsed }

    func toggle() {
        hideTask?.cancel()
        if !panel.isVisible {
            state.isCollapsed = false
            reposition()
            panel.orderFrontRegardless()
            return
        }
        state.isCollapsed.toggle()
        reposition()
    }

    /// Collapses only when the shared policy allows the region that was interacted with.
    private func collapse(from region: NotchInteractionRegion) {
        guard NotchCollapsePolicy.shouldCollapse(on: region) else { return }
        collapse()
    }

    private func collapse() {
        guard panel.isVisible, !state.isCollapsed else { return }
        state.isCollapsed = true
        reposition()
    }

    private func installClickMonitors() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.collapse(from: .outside) }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.collapse(from: .outside) }
        }
    }

    func hide() {
        dismiss()
    }

    func dismiss() {
        hideTask?.cancel()
        state.isCollapsed = true
        panel.orderOut(nil)
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let notchBounds: ClosedRange<CGFloat>?
        if let leftSafeArea = screen.auxiliaryTopLeftArea,
           let rightSafeArea = screen.auxiliaryTopRightArea,
           !leftSafeArea.isEmpty,
           !rightSafeArea.isEmpty {
            notchBounds = leftSafeArea.maxX...rightSafeArea.minX
        } else {
            notchBounds = nil
        }
        let isFloating = model?.settings.overlayPresentation == .floating
        let compactWidth: CGFloat = isFloating
            ? 170
            : notchBounds.map { $0.upperBound - $0.lowerBound + notchShoulder * 2 } ?? 220
        if abs(state.compactWidth - compactWidth) > 0.5 {
            state.compactWidth = compactWidth
        }
        let expandedWidth: CGFloat = isFloating ? 300 : max(compactWidth, minimumExpandedWidth)
        if abs(state.expandedWidth - expandedWidth) > 0.5 {
            state.expandedWidth = expandedWidth
        }
        let size = isFloating
            ? (state.isCollapsed ? NSSize(width: 200, height: 38) : NSSize(width: 300, height: 226))
            : (state.isCollapsed
                ? NSSize(width: state.compactWidth, height: collapsedHeight)
                : NSSize(width: state.expandedWidth, height: expandedHeight))
        let panelFrame: NSRect
        if isFloating {
            let visibleFrame = screen.visibleFrame
            if panel.frame.origin != .zero && panel.frame.origin.x >= visibleFrame.minX - 50 {
                let currentOrigin = panel.frame.origin
                let deltaY = size.height - panel.frame.height
                panelFrame = NSRect(
                    x: min(max(currentOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
                    y: max(currentOrigin.y - deltaY, visibleFrame.minY),
                    width: size.width,
                    height: size.height
                )
            } else {
                panelFrame = NSRect(
                    x: visibleFrame.maxX - size.width - 24,
                    y: visibleFrame.maxY - size.height - 24,
                    width: size.width,
                    height: size.height
                )
            }
        } else {
            let notchCenter = notchBounds.map { ($0.lowerBound + $0.upperBound) / 2 } ?? frame.midX
            panelFrame = NSRect(
                x: notchCenter - size.width / 2,
                y: frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }
        panel.setFrame(
            panelFrame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

private struct NotchHUD: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var state: NotchPresentationState
    let toggle: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let openOnboarding: () -> Void
    let togglePresentation: () -> Void
    let quit: () -> Void

    var body: some View {
        if model.settings.overlayPresentation == .floating {
            FloatingHUD(
                model: model,
                state: state,
                toggle: toggle,
                dismiss: dismiss,
                openApp: openApp,
                openSettings: openSettings,
                openOnboarding: openOnboarding,
                togglePresentation: togglePresentation,
                quit: quit
            )
        } else {
            DockedNotchHUD(
                model: model,
                state: state,
                toggle: toggle,
                dismiss: dismiss,
                openApp: openApp,
                openSettings: openSettings,
                openOnboarding: openOnboarding,
                togglePresentation: togglePresentation,
                quit: quit
            )
        }
    }
}

private extension SaysoAppModel {
    var activeShortcutAction: SaysoShortcutAction {
        settings.mode == .dictation ? .dictation : .control
    }

    var activeShortcutHint: String {
        ShortcutHint.compact(
            for: activeShortcutAction,
            hotKey: settings.mode == .dictation ? dictationHotKey : controlHotKey
        )
    }

    var activeShortcutAccessibilityHint: String {
        ShortcutHint.accessibility(
            for: activeShortcutAction,
            hotKey: settings.mode == .dictation ? dictationHotKey : controlHotKey
        )
    }
}

/// Floating presentation of the same contextual voice workspace as the docked notch.
private struct FloatingHUD: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var state: NotchPresentationState
    let toggle: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let openOnboarding: () -> Void
    let togglePresentation: () -> Void
    let quit: () -> Void

    var body: some View {
        if state.isCollapsed {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                        .foregroundStyle(model.settings.mode == .dictation ? SaysoPalette.cobalt : SaysoPalette.amber)
                    Text(model.settings.mode == .dictation ? "Dictation" : "Control")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(model.activeShortcutHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(SaysoPalette.muted)
                    if model.transcriber.phase == .listening {
                        Circle().fill(SaysoPalette.crimson).frame(width: 7, height: 7)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(width: 200, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(SaysoPalette.brandNavySurface)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SaysoPalette.outline, lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Sayso \(model.settings.mode == .dictation ? "Dictation" : "Control") workspace")
            .accessibilityHint(model.activeShortcutAccessibilityHint)
        } else {
            ZStack {
                Button(action: toggle) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(SaysoPalette.brandNavySurface)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SaysoPalette.outline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Sayso workspace")

                VoiceWorkspaceContent(
                    model: model,
                    collapse: toggle,
                    dismiss: dismiss,
                    openApp: openApp,
                    openSettings: openSettings,
                    openOnboarding: openOnboarding,
                    togglePresentation: togglePresentation,
                    quit: quit
                )
                .padding(14)
            }
            .frame(width: 300, height: 226)
            .preferredColorScheme(.dark)
        }
    }
}

private struct VoiceWorkspaceContent: View {
    @ObservedObject var model: SaysoAppModel
    let collapse: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let openOnboarding: () -> Void
    let togglePresentation: () -> Void
    let quit: () -> Void

    private var isLive: Bool {
        model.transcriber.canStop || model.transcriber.phase == .listening
    }

    private var status: String {
        // Once a Control utterance ends, its stale transcript must not hide planning, questions, or results.
        let isControl = model.settings.mode == .control
        if !model.transcriber.partialText.isEmpty, isLive || !isControl { return model.transcriber.partialText }
        if let notice = model.notice { return notice }
        if !isLive, !isControl, let activity = model.moduleActivityStatus { return activity }
        if isControl { return model.controlStatus }
        if model.transcriber.phase == .listening { return "Listening for dictation" }
        return "Ready to dictate into the focused app"
    }

    private var actionTitle: String {
        if model.settings.mode == .control {
            if model.transcriber.canStop { return "Stop Control" }
            return model.transcriber.canStart ? "Start Control" : "Finishing Control"
        }
        if model.transcriber.canStop { return "Stop Dictation" }
        return model.transcriber.canStart ? "Start Dictation" : "Finishing Dictation"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ModePicker(model: model)
                Spacer(minLength: 4)
                Menu {
                    Button("Open Sayso", action: openApp)
                    Button("Onboarding Tour", action: openOnboarding)
                    Button("Settings", action: openSettings)
                    Divider()
                    Button(model.settings.overlayPresentation == .notch ? "Detach from Notch" : "Dock to Notch", action: togglePresentation)
                    if model.moduleActivityStatus != nil {
                        Button("Dismiss notification", action: model.dismissPrimaryModuleActivity)
                    }
                    Button("Collapse", action: collapse)
                    Button("Hide", action: dismiss)
                    Divider()
                    Button("Quit Sayso", role: .destructive, action: quit)
                } label: {
                    Label("More Sayso controls", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .help("More Sayso controls")
            }

            Button(action: { if !isLive, model.modulePrimaryActionTitle != nil, model.moduleActivityStatus == status { model.performPrimaryModuleAction() } else { collapse() } }) {
                Text(status)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.settings.mode == .dictation ? "Dictation status, collapse workspace" : "Control status, collapse workspace")
            .accessibilityValue(status)
            .help(!isLive && model.modulePrimaryActionTitle != nil && model.moduleActivityStatus == status ? "\(status). Click to \(model.modulePrimaryActionTitle ?? "act")." : "\(status). Click to collapse.")

            if model.settings.mode == .control, !isLive, model.transcriber.canStart {
                Button(model.isCheckingControlTryNowReadiness ? "Checking readiness..." : "Try now: Open Calculator") {
                    model.startControlTryNow()
                }
                .buttonStyle(.bordered)
                .tint(SaysoPalette.amber)
                .controlSize(.small)
                .disabled(model.isCheckingControlTryNowReadiness)
                .accessibilityHint("Starts listening for the spoken command Open Calculator")
                Text(model.controlTryNowReadiness)
                    .font(.caption)
                    .foregroundStyle(SaysoPalette.muted)
                    .multilineTextAlignment(.center)
            }

            Button {
                if model.settings.mode == .dictation {
                    model.startOrStopDictation()
                } else {
                    model.startOrStopControl()
                }
            } label: {
                Label(
                    actionTitle,
                    systemImage: isLive ? "stop.fill" : model.settings.mode == .dictation ? "mic.fill" : "cursorarrow.rays"
                )
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(isLive ? SaysoPalette.crimson : model.settings.mode == .dictation ? SaysoPalette.cobalt : SaysoPalette.amberDark)
            .disabled(!model.transcriber.canStop && !model.transcriber.canStart)

            Button(action: collapse) {
                Text("\(model.activeShortcutHint) · \(model.settings.mode == .dictation ? "Dictation" : "Control")")
                    .font(.caption.monospaced())
                    .foregroundStyle(SaysoPalette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.activeShortcutAccessibilityHint) for \(model.settings.mode == .dictation ? "Dictation" : "Control"), collapse workspace")
        }
    }
}

/// Docked Notch HUD designed specifically for conforming to the MacBook display notch
private struct DockedNotchHUD: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var state: NotchPresentationState
    let toggle: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let openOnboarding: () -> Void
    let togglePresentation: () -> Void
    let quit: () -> Void

    var body: some View {
        if state.isCollapsed {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                        .foregroundStyle(model.settings.mode == .dictation ? SaysoPalette.cobalt : SaysoPalette.amber)
                    Text(model.settings.mode == .dictation ? "Dictation" : "Control")
                    Spacer(minLength: 4)
                    Text(model.activeShortcutHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(SaysoPalette.muted)
                    if model.transcriber.phase == .listening { Circle().fill(SaysoPalette.crimson).frame(width: 7, height: 7) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: state.compactWidth, height: 42)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                .overlay { NotchShine(cornerRadius: 18) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Sayso \(model.settings.mode == .dictation ? "Dictation" : "Control") workspace")
            .accessibilityHint(model.activeShortcutAccessibilityHint)
        } else {
            ZStack {
                Button(action: toggle) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                        .fill(SaysoPalette.obsidian)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Sayso workspace")

                VoiceWorkspaceContent(
                    model: model,
                    collapse: toggle,
                    dismiss: dismiss,
                    openApp: openApp,
                    openSettings: openSettings,
                    openOnboarding: openOnboarding,
                    togglePresentation: togglePresentation,
                    quit: quit
                )
                .padding(.horizontal, 16)
                .padding(.top, 38)
                .padding(.bottom, 14)
            }
            .frame(width: state.expandedWidth, height: 236)
            .contentShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
            .overlay {
                NotchShine(cornerRadius: 20)
            }
            .foregroundStyle(.white)
        }
    }
}

private struct NotchShine: View {
    let cornerRadius: CGFloat

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
            .stroke(SaysoPalette.outline, lineWidth: 1)
    }
}
