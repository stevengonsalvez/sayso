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
                    let activePreview = !model.livePreviewText.isEmpty ? model.livePreviewText : model.transcriber.partialText
                    if !activePreview.isEmpty {
                        Text(activePreview)
                            .font(.caption2.italic())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.white)
                    } else {
                        Text(model.activeShortcutHint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    if model.transcriber.phase == .listening {
                        HStack(spacing: 4) {
                            Circle().fill(SaysoPalette.crimson).frame(width: 6, height: 6)
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach([0.55, 0.85, 0.62, 1.0, 0.6].indices, id: \.self) { idx in
                                    Capsule()
                                        .fill(SaysoPalette.crimson)
                                        .frame(width: 2.5, height: max(2.5, CGFloat(min(max(model.transcriber.audioLevel, 0), 1)) * [0.55, 0.85, 0.62, 1.0, 0.6][idx] * 12))
                                }
                            }
                            .frame(height: 12, alignment: .bottom)
                        }
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

    private var statusModel: NotchStatus {
        // Once a Control utterance ends, its stale transcript must not hide planning, questions, or results.
        // Main's live preview wins over the raw partial, as before the module status policy.
        let activeText = !model.livePreviewText.isEmpty ? model.livePreviewText : model.transcriber.partialText
        return NotchStatusPolicy.resolve(
            partialText: activeText,
            isLive: isLive,
            isControl: model.settings.mode == .control,
            notice: model.notice,
            controlStatus: model.controlStatus,
            primary: model.primaryModuleActivity,
            isListening: model.transcriber.phase == .listening
        )
    }

    private var isProcessing: Bool {
        model.transcriber.phase == .processing
    }

    private var activeText: String {
        !model.livePreviewText.isEmpty ? model.livePreviewText : model.transcriber.partialText
    }

    private var status: String { statusModel.text }

    private var actionTitle: String {
        if model.settings.mode == .control {
            if model.transcriber.canStop { return "Stop Control" }
            return model.transcriber.canStart ? "Start Control" : "Finishing Control"
        }
        if model.transcriber.canStop { return "Stop Dictation" }
        return model.transcriber.canStart ? "Start Dictation" : "Finishing Dictation"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ModePicker(model: model)
                Spacer(minLength: 4)
                Button(action: collapse) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SaysoPalette.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Minimize / Collapse workspace (Esc)")
                .accessibilityLabel("Minimize Sayso workspace")

                Menu {
                    Button("Open Sayso", action: openApp)
                    Button("Onboarding Tour", action: openOnboarding)
                    Button("Settings", action: openSettings)
                    Divider()
                    Button(model.settings.overlayPresentation == .notch ? "Detach from Notch" : "Dock to Notch", action: togglePresentation)
                    if let primary = model.primaryModuleActivity {
                        Button("Open in Studio") {
                            model.openStudio(forModule: primary.moduleID)
                            openApp()
                        }
                    }
                    if let primary = model.primaryModuleActivity,
                       primary.interruption != .critical || statusModel.dismissActionID != nil {
                        Button(primary.interruption == .critical ? "Deny" : "Dismiss notification") {
                            if let id = statusModel.dismissActionID { model.performModuleAction(id) } else { model.dismissPrimaryModuleActivity() }
                        }
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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isLive {
                        Circle()
                            .fill(SaysoPalette.crimson)
                            .frame(width: 7, height: 7)
                        Text(model.settings.mode == .dictation ? "Listening..." : "Listening for command...")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SaysoPalette.crimson)
                    } else if isProcessing {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Finishing...")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SaysoPalette.amber)
                    } else if let notice = model.notice {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SaysoPalette.amber)
                        Text(notice)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SaysoPalette.amber)
                            .lineLimit(1)
                    } else {
                        Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                            .font(.system(size: 11))
                            .foregroundStyle(SaysoPalette.muted)
                        Text(model.settings.mode == .control ? model.controlStatus : "Ready to dictate")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SaysoPalette.muted)
                    }
                    Spacer()
                }

                Button(action: collapse) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))

                        if !activeText.isEmpty {
                            Text(activeText)
                                .font(.system(size: 13, weight: isLive ? .regular : .medium))
                                .italic(isLive)
                                .foregroundStyle(isLive ? .white : Color(white: 0.95))
                                .lineLimit(2)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        } else if isLive {
                            Text("Speak now...")
                                .font(.system(size: 13).italic())
                                .foregroundStyle(SaysoPalette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        } else {
                            Text("Ready to dictate into the focused app")
                                .font(.system(size: 13))
                                .foregroundStyle(SaysoPalette.muted.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.settings.mode == .dictation ? "Dictation transcript, collapse workspace" : "Control transcript, collapse workspace")
                .accessibilityValue(activeText.isEmpty ? "Ready to dictate" : activeText)
            }

            // Module activity (download progress, retry, Control review) keeps its own explicit line under main's live view.
            if !isLive, model.primaryModuleActivity != nil {
                Button(action: { if let tap = statusModel.tapAction { model.performModuleAction(tap) } else { collapse() } }) {
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusModel.criticalActions.isEmpty ? SaysoPalette.amber : SaysoPalette.crimson)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .buttonStyle(.plain)
                .accessibilityValue(status)
                .help(statusModel.tapAction.map { "\(status). Click to \($0.title)." } ?? "\(status). Click to collapse.")
            }

            if !statusModel.criticalActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(statusModel.criticalActions, id: \.id) { action in
                        Button(action.title) { model.performModuleAction(action.id) }
                            .buttonStyle(.borderedProminent)
                            .tint(action.id == "approve" ? SaysoPalette.cobalt : SaysoPalette.crimson)
                            .accessibilityLabel("\(action.title): \(status)")
                    }
                }
            }

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

            if isLive {
                Button {
                    if model.settings.mode == .dictation {
                        model.startOrStopDictation()
                    } else {
                        model.startOrStopControl()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(SaysoPalette.crimson).frame(width: 8, height: 8)
                        Text(actionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        HStack(alignment: .bottom, spacing: 2.5) {
                            ForEach([0.55, 0.85, 0.62, 1.0, 0.6].indices, id: \.self) { idx in
                                Capsule()
                                    .fill(SaysoPalette.crimson)
                                    .frame(width: 3, height: max(3, CGFloat(min(max(model.transcriber.audioLevel, 0), 1)) * [0.55, 0.85, 0.62, 1.0, 0.6][idx] * 18))
                                    .animation(.easeOut(duration: 0.1), value: model.transcriber.audioLevel)
                            }
                        }
                        .frame(height: 18, alignment: .bottom)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(SaysoPalette.crimson.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SaysoPalette.crimson.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if model.settings.mode == .dictation {
                        model.startOrStopDictation()
                    } else {
                        model.startOrStopControl()
                    }
                } label: {
                    Label(
                        actionTitle,
                        systemImage: model.settings.mode == .dictation ? "mic.fill" : "cursorarrow.rays"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.settings.mode == .dictation ? SaysoPalette.cobalt : SaysoPalette.amberDark)
                .disabled(!model.transcriber.canStop && !model.transcriber.canStart)
            }

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
                    let activePreview = !model.livePreviewText.isEmpty ? model.livePreviewText : model.transcriber.partialText
                    if !activePreview.isEmpty {
                        Text(activePreview)
                            .font(.caption2.italic())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 140)
                    } else {
                        Text(model.activeShortcutHint)
                            .font(.caption2.monospaced())
                    }
                    if model.transcriber.phase == .listening {
                        HStack(spacing: 4) {
                            Circle().fill(SaysoPalette.crimson).frame(width: 6, height: 6)
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach([0.55, 0.85, 0.62, 1.0, 0.6].indices, id: \.self) { idx in
                                    Capsule()
                                        .fill(SaysoPalette.crimson)
                                        .frame(width: 2.5, height: max(2.5, CGFloat(min(max(model.transcriber.audioLevel, 0), 1)) * [0.55, 0.85, 0.62, 1.0, 0.6][idx] * 12))
                                }
                            }
                            .frame(height: 12, alignment: .bottom)
                        }
                    }
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
