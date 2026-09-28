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
    private let state = NotchPresentationState()
    private weak var model: SaysoAppModel?

    private let expandedHeight: CGFloat = 226
    private let collapsedHeight: CGFloat = 42
    private let notchShoulder: CGFloat = 42
    // 360pt chosen to fit ModePicker and 2-line text; icon row needs 266pt minimum.
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
        let expandedWidth: CGFloat = isFloating ? 254 : max(compactWidth, minimumExpandedWidth)
        if abs(state.expandedWidth - expandedWidth) > 0.5 {
            state.expandedWidth = expandedWidth
        }
        let size = isFloating
            ? (state.isCollapsed ? NSSize(width: 170, height: 38) : NSSize(width: 254, height: 198))
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
        panel.setFrame(panelFrame, display: true, animate: true)
    }
}

private struct NotchHUD: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var state: NotchPresentationState
    let toggle: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
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
                togglePresentation: togglePresentation,
                quit: quit
            )
        }
    }
}

/// Floating HUD inspired by jev-use VoiceWidget: symmetric 22pt rounded rectangle,
/// dark glass material, audio waveform bars, 2-line transcript, and top-trailing hover controls.
private struct FloatingHUD: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var state: NotchPresentationState
    @State private var isHovering = false
    @State private var isGlowPulsing = false
    let toggle: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let togglePresentation: () -> Void
    let quit: () -> Void

    private var message: String {
        if !model.transcriber.partialText.isEmpty {
            return model.transcriber.partialText
        }
        if model.transcriber.phase == .listening {
            return "Listening..."
        }
        if let notice = model.notice {
            return notice
        }
        if model.settings.mode == .control {
            return model.controlStatus
        }
        return "Tap mic to speak"
    }

    var body: some View {
        if state.isCollapsed {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                        .foregroundStyle(SaysoPalette.amber)
                    Text(model.transcriber.phase == .listening ? "Listening" : "Sayso")
                        .font(.caption.weight(.bold))
                    if model.transcriber.phase == .listening {
                        Circle().fill(SaysoPalette.crimson).frame(width: 7, height: 7)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(width: 170, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 19).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 19).fill(Color.black.opacity(0.65)))
                        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 6) {
                // Waveform / Level indicator
                WaveformLevelIndicator(
                    isListening: model.transcriber.phase == .listening,
                    mode: model.settings.mode
                )
                .frame(width: 220, height: 50)
                .accessibilityHidden(true)

                // 2-line transcript / status message
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 44)
                    .help(message)

                // Primary glowing action button
                let isLive = model.transcriber.canStop || model.transcriber.phase == .listening
                Button {
                    model.startOrStopDictation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(isLive ? "Stop listening" : "Start dictation")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(isLive ? SaysoPalette.crimson : SaysoPalette.brandCobalt)
                .shadow(color: isLive ? SaysoPalette.crimson.opacity(isGlowPulsing ? 0.95 : 0.4) : .clear, radius: isGlowPulsing ? 10 : 4)
                .overlay {
                    if isLive {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(SaysoPalette.crimson.opacity(isGlowPulsing ? 0.9 : 0.5), lineWidth: 1.5)
                            .shadow(color: SaysoPalette.crimson, radius: isGlowPulsing ? 8 : 4)
                    }
                }
                .disabled(!model.transcriber.canStop && !model.transcriber.canStart)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                        isGlowPulsing = true
                    }
                }

                // Subtitle / shortcut hint
                Text("Option-Space to speak")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 254, height: 198)
            .background {
                RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.65)))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .help("Settings")

                    Button { togglePresentation() } label: {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .help("Dock to notch")

                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .help("Dismiss")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.75))
                .padding(8)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
            .onHover { isHovering = $0 }
            .preferredColorScheme(.dark)
        }
    }
}

/// Dynamic audio bar visualization reacting to voice activity
private struct WaveformLevelIndicator: View {
    let isListening: Bool
    let mode: SaysoMode

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<12) { i in
                    let h: CGFloat = isListening
                        ? 10 + 32 * CGFloat(abs(sin(t * 5 + Double(i) * 0.5)))
                        : 6 + 6 * CGFloat(abs(sin(t * 1.5 + Double(i) * 0.4)))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: isListening
                                    ? [SaysoPalette.crimson, SaysoPalette.brandAmber]
                                    : [SaysoPalette.brandCobalt, SaysoPalette.brandCobalt.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 4, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Docked Notch HUD designed specifically for conforming to the MacBook display notch
private struct DockedNotchHUD: View {
    @ObservedObject var model: SaysoAppModel
    @ObservedObject var state: NotchPresentationState
    @State private var isGlowPulsing = false
    let toggle: () -> Void
    let dismiss: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let togglePresentation: () -> Void
    let quit: () -> Void

    var body: some View {
        if state.isCollapsed {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                        .foregroundStyle(SaysoPalette.amber)
                    if model.transcriber.phase == .listening { Circle().fill(SaysoPalette.crimson).frame(width: 7, height: 7) }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: state.compactWidth, height: 42)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                .overlay { NotchShine(cornerRadius: 18) }
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(SaysoPalette.cobalt)
                        Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                            .font(.caption.weight(.bold))
                    }
                    .frame(width: 28, height: 28)

                    Spacer(minLength: 8)
                    NotchIconButton(
                        model.settings.overlayPresentation == .notch ? "rectangle.on.rectangle" : "menubar.rectangle",
                        label: model.settings.overlayPresentation == .notch ? "Detach widget" : "Attach to notch",
                        action: togglePresentation
                    )
                    NotchIconButton("macwindow", label: "Open Sayso", action: openApp)
                    NotchIconButton("gearshape", label: "Open settings", action: openSettings)
                    NotchIconButton("chevron.up", label: "Collapse notch", action: toggle)
                    NotchIconButton("xmark", label: "Hide notch", action: dismiss)
                    NotchIconButton("power", label: "Quit Sayso", tint: SaysoPalette.crimson, action: quit)
                }

                HStack {
                    Spacer()
                    ModePicker(model: model)
                    Spacer()
                }

                Text(model.transcriber.partialText.isEmpty ? (model.notice ?? "Live words appear here.") : model.transcriber.partialText)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 50)
                    .fixedSize(horizontal: false, vertical: true)

                let isLive = model.transcriber.canStop || model.transcriber.phase == .listening
                Button {
                    model.startOrStopDictation()
                } label: {
                    Label(
                        model.transcriber.canStop ? "Stop listening" : model.transcriber.canStart ? "Start dictation" : "Finishing dictation",
                        systemImage: model.transcriber.canStop ? "stop.fill" : model.transcriber.canStart ? "mic.fill" : "ellipsis"
                    )
                    .font(.callout.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(isLive ? SaysoPalette.crimson : SaysoPalette.cobalt)
                .shadow(color: isLive ? SaysoPalette.crimson.opacity(isGlowPulsing ? 0.95 : 0.4) : .clear, radius: isGlowPulsing ? 12 : 5)
                .overlay {
                    if isLive {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(SaysoPalette.crimson.opacity(isGlowPulsing ? 0.9 : 0.5), lineWidth: 1.5)
                            .shadow(color: SaysoPalette.crimson, radius: isGlowPulsing ? 8 : 4)
                    }
                }
                .disabled(!model.transcriber.canStop && !model.transcriber.canStart)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                        isGlowPulsing = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 38)
            .padding(.bottom, 14)
            .frame(width: state.expandedWidth, height: 226)
            .contentShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
            .gesture(TapGesture().onEnded(toggle), including: .gesture)
            .background {
                UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                    .fill(SaysoPalette.obsidian)
            }
            .overlay {
                NotchShine(cornerRadius: 20)
            }
            .foregroundStyle(.white)
        }
    }
}

private struct NotchShine: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShining = false

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
                .stroke(SaysoPalette.outline, lineWidth: 1)
            UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
                .stroke(SaysoPalette.cobalt.opacity(isShining ? 0.76 : 0), lineWidth: 1)
                .shadow(color: SaysoPalette.cobalt.opacity(isShining ? 0.58 : 0), radius: isShining ? 4 : 0)
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else {
                isShining = false
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 0.45)) { isShining = true }
                do {
                    try await Task.sleep(for: .milliseconds(900))
                } catch {
                    return
                }
                withAnimation(.easeOut(duration: 0.55)) { isShining = false }
            }
        }
    }
}

private struct NotchIconButton: View {
    let systemName: String
    let label: String
    let tint: Color
    let action: () -> Void

    init(_ systemName: String, label: String, tint: Color = .white, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(SaysoPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
