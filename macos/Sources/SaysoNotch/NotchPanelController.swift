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

    private let expandedHeight: CGFloat = 210
    private let collapsedHeight: CGFloat = 42
    private let notchShoulder: CGFloat = 42

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
        let compactWidth = notchBounds.map { $0.upperBound - $0.lowerBound + notchShoulder * 2 } ?? 220
        if abs(state.compactWidth - compactWidth) > 0.5 {
            state.compactWidth = compactWidth
        }
        let size = state.isCollapsed
            ? NSSize(width: state.compactWidth, height: collapsedHeight)
            : NSSize(width: state.compactWidth, height: expandedHeight)
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

                Text(model.transcriber.partialText.isEmpty ? "Live words appear here." : model.transcriber.partialText)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)

                Button {
                    model.startOrStopDictation()
                } label: {
                    Label(
                        model.transcriber.phase == .listening ? "Stop listening" : "Start dictation",
                        systemImage: model.transcriber.phase == .listening ? "stop.fill" : "mic.fill"
                    )
                    .font(.callout.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.transcriber.phase == .listening ? SaysoPalette.crimson : SaysoPalette.cobalt)
            }
            .padding(.horizontal, 16)
            .padding(.top, 38)
            .padding(.bottom, 14)
            .frame(width: state.compactWidth, height: 210)
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
