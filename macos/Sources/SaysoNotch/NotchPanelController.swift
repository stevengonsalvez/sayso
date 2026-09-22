import AppKit
import SaysoCore
import SwiftUI

@MainActor
private final class NotchPresentationState: ObservableObject {
    @Published var isCollapsed = true
    @Published var compactWidth: CGFloat = 220
}

@MainActor
final class NotchPanelController {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private let state = NotchPresentationState()
    private weak var model: SaysoAppModel?

    private let expandedSize = NSSize(width: 560, height: 176)
    private let collapsedHeight: CGFloat = 42
    private let leftNotchExtension: CGFloat = 118

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

    private func toggle() {
        hideTask?.cancel()
        state.isCollapsed.toggle()
        reposition()
    }

    private func dismiss() {
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
        let compactWidth = notchBounds.map { $0.upperBound - $0.lowerBound + leftNotchExtension } ?? 220
        if abs(state.compactWidth - compactWidth) > 0.5 {
            state.compactWidth = compactWidth
        }
        let size = state.isCollapsed
            ? NSSize(width: state.compactWidth, height: collapsedHeight)
            : expandedSize
        let panelFrame: NSRect
        if model?.settings.overlayPresentation == .floating {
            let visibleFrame = screen.visibleFrame
            panelFrame = NSRect(
                x: visibleFrame.maxX - size.width - 24,
                y: visibleFrame.maxY - size.height - 24,
                width: size.width,
                height: size.height
            )
        } else {
            let x = notchBounds.map { $0.upperBound - size.width } ?? frame.midX - size.width / 2
            panelFrame = NSRect(
                x: x,
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
    let quit: () -> Void

    var body: some View {
        if state.isCollapsed {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                        .foregroundStyle(SaysoPalette.amber)
                    Text(model.transcriber.phase == .listening ? "Listening" : "Sayso")
                    if model.transcriber.phase == .listening { Circle().fill(SaysoPalette.crimson).frame(width: 7, height: 7) }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: state.compactWidth, height: 42)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                .overlay { NotchShine(cornerRadius: 18) }
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(SaysoPalette.cobalt)
                        Image(systemName: model.settings.mode == .dictation ? "waveform" : "cursorarrow.click")
                            .font(.caption.weight(.bold))
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sayso")
                            .font(.system(size: 15, weight: .bold))
                        Text(model.settings.mode == .dictation ? "Dictation" : "Desktop control")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(SaysoPalette.muted)
                    }

                    Spacer(minLength: 8)
                    NotchIconButton("macwindow", label: "Open Sayso", action: openApp)
                    NotchIconButton("gearshape", label: "Open settings", action: openSettings)
                    NotchIconButton("chevron.up", label: "Collapse notch", action: toggle)
                    NotchIconButton("xmark", label: "Hide notch", action: dismiss)
                    NotchIconButton("power", label: "Quit Sayso", tint: SaysoPalette.crimson, action: quit)
                }

                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.transcriber.phase == .listening ? SaysoPalette.crimson : SaysoPalette.cobalt)
                            .frame(width: 8, height: 8)
                        Text(model.transcriber.phase == .listening ? "Live transcription" : "Ready when you are")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SaysoPalette.surfaceRaised, in: Capsule())

                    ModePicker(model: model)
                        .frame(width: 180)
                    Spacer()
                }

                HStack(alignment: .bottom, spacing: 16) {
                    Text(model.transcriber.partialText.isEmpty ? "Live words appear here." : model.transcriber.partialText)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(model.transcriber.phase == .listening ? "Stop" : "Start") {
                        model.startOrStopDictation()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.transcriber.phase == .listening ? SaysoPalette.crimson : SaysoPalette.cobalt)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(width: 560, height: 176)
            .background(SaysoPalette.obsidian, in: UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
            .overlay {
                NotchShine(cornerRadius: 20)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .gesture(
                TapGesture().onEnded(toggle),
                including: model.settings.overlayPresentation == .notch ? .gesture : .none
            )
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
