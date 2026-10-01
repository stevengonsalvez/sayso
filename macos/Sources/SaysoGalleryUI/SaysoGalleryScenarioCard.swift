import SwiftUI
import SaysoCore

/// Renders one synthetic scenario at a fixed size for its surface.
/// Visual grammar: hardware-black closed pill, obsidian glass expanded surface, large radii,
/// SF Symbols, one semantic accent, white primary text.
public struct SaysoGalleryScenarioCard: View {
    public let scenario: SaysoGalleryScenario
    public var onGrant: (() -> Void)?
    public var onRetry: (() -> Void)?

    private let presentation: SaysoGalleryCardPresentation
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var pulseEnabled: Bool { presentation.pulseEnabled(systemReduceMotion: systemReduceMotion) }
    private var highContrast: Bool { presentation.usesHighContrast(systemIncreaseContrast: colorSchemeContrast == .increased) }

    public init(
        scenario: SaysoGalleryScenario,
        onGrant: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.scenario = scenario
        self.onGrant = onGrant
        self.onRetry = onRetry
        self.presentation = SaysoGalleryCardPresentation(scenario: scenario)
    }

    public static func size(for surface: SaysoModuleSurface) -> CGSize {
        switch surface {
        case .compact: CGSize(width: 200, height: 38)
        case .peek: CGSize(width: 320, height: 84)
        case .expanded: CGSize(width: 420, height: 200)
        case .detail: CGSize(width: 420, height: 280)
        case .detached: CGSize(width: 360, height: 240)
        case .settings: CGSize(width: 400, height: 260)
        }
    }

    // MARK: Tokens

    private var accent: Color {
        switch presentation.tone {
        case .normal: Color(red: 0.30, green: 0.56, blue: 1.0)
        case .muted: Color(white: 0.5)
        case .warning: Color(red: 1.0, green: 0.72, blue: 0.20)
        case .error: Color(red: 1.0, green: 0.35, blue: 0.35)
        }
    }

    private var contentOpacity: Double { presentation.isMuted ? 0.45 : 1 }
    private var primary: Color { .white.opacity(contentOpacity) }
    private var secondary: Color { .white.opacity(presentation.secondaryTextOpacity(highContrast: highContrast)) }
    private var borderColor: Color { .white.opacity(highContrast ? 0.85 : 0.12) }
    private var borderWidth: CGFloat { highContrast ? 2 : 1 }

    private var cornerRadius: CGFloat {
        switch scenario.surface {
        case .compact: Self.size(for: .compact).height / 2
        case .peek: 26
        default: 32
        }
    }

    private var surfaceFill: AnyShapeStyle {
        if scenario.surface == .compact { return AnyShapeStyle(Color.black) }
        return AnyShapeStyle(LinearGradient(
            colors: [Self.color(SaysoGalleryCardPresentation.surfaceTop),
                     Self.color(SaysoGalleryCardPresentation.surfaceBottom)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    private static func color(_ rgb: (r: Double, g: Double, b: Double)) -> Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    // MARK: Body

    public var body: some View {
        let size = Self.size(for: scenario.surface)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(surfaceFill)
            shape.strokeBorder(borderColor, lineWidth: borderWidth)
            content.padding(scenario.surface == .compact ? 12 : 18)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .transaction { if !pulseEnabled { $0.animation = nil } }
        .onAppear { if pulseEnabled { pulse = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(scenario.title), \(presentation.statusLabel)")
    }

    @ViewBuilder private var content: some View {
        switch scenario.surface {
        case .compact: compact
        case .peek: peek
        case .expanded, .detail: panel(rows: scenario.surface == .detail ? 4 : 2)
        case .detached: detached
        case .settings: settings
        }
    }

    // MARK: Pieces

    private var symbol: String {
        switch scenario.moduleID {
        case "clip": "doc.on.clipboard"
        case "timer": "timer"
        case "media": "play.circle"
        default: "square.grid.2x2"
        }
    }

    private var statusSymbol: String {
        switch scenario.health {
        case .permissionRequired: "lock.fill"
        case .failed, .quarantined: "exclamationmark.triangle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .disabled: "moon.zzz.fill"
        case .ready: "checkmark.circle.fill"
        }
    }

    private var iconTile: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(presentation.isMuted ? secondary : accent)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Image(systemName: statusSymbol).font(.system(size: 10, weight: .bold))
                .opacity(scenario.health == .ready && pulse ? 0.6 : 1)
                .animation(
                    pulseEnabled ? .easeInOut(duration: 1).repeatForever() : nil,
                    value: pulse
                )
            Text(presentation.statusLabel).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(presentation.isMuted ? secondary : accent)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill((presentation.isMuted ? Color.white : accent).opacity(0.14)))
    }

    private var compact: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(primary)
            Text(scenario.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(primary)
            Spacer(minLength: 4)
            Image(systemName: statusSymbol).font(.system(size: 11, weight: .bold))
                .foregroundStyle(presentation.isMuted ? secondary : accent)
        }
    }

    private var peek: some View {
        HStack(spacing: 12) {
            iconTile
            VStack(alignment: .leading, spacing: 3) {
                Text(scenario.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(primary)
                Text(peekCaption).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if presentation.showsGrantPrompt {
                actionPill(.grant, "Grant", symbol: "lock.open.fill")
            } else if presentation.showsRetry {
                actionPill(.retry, "Retry", symbol: "arrow.clockwise")
            } else {
                statusChip
            }
        }
    }

    private var peekCaption: String {
        if presentation.showsGrantPrompt { return "Access required" }
        if presentation.showsRetry { return "Something went wrong" }
        return sample.first ?? presentation.statusLabel
    }

    private func panel(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                iconTile
                Text(scenario.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(primary)
                Spacer()
                statusChip
            }
            if presentation.showsGrantPrompt {
                message("Sayso needs permission to show \(scenario.title.lowercased()) here.",
                        button: (.grant, "Grant access", "lock.open.fill"))
            } else if presentation.showsRetry {
                message("\(scenario.title) stopped responding.",
                        button: (.retry, "Retry", "arrow.clockwise"), isError: true)
            } else {
                if scenario.health == .degraded {
                    Label("Showing cached data", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                }
                VStack(spacing: 8) {
                    ForEach(Array(sample.prefix(rows).enumerated()), id: \.offset) { _, line in
                        HStack {
                            Text(line).font(.system(size: 13)).foregroundStyle(primary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var detached: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.25)).frame(width: 9, height: 9) }
                Spacer()
                Text(scenario.title).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                Spacer()
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(secondary)
            }
            panel(rows: 2)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                iconTile
                Text("\(scenario.title) Settings").font(.system(size: 17, weight: .semibold)).foregroundStyle(primary)
                Spacer()
            }
            if presentation.showsGrantPrompt {
                message("Grant access to configure \(scenario.title.lowercased()).",
                        button: (.grant, "Grant access", "lock.open.fill"))
            } else if presentation.showsRetry {
                message("Settings could not be loaded.", button: (.retry, "Retry", "arrow.clockwise"), isError: true)
            } else {
                ForEach(["Enabled", "Show in pill", "Haptics"], id: \.self) { label in
                    HStack {
                        Text(label).font(.system(size: 13)).foregroundStyle(primary)
                        Spacer()
                        faux(on: label != "Haptics" && !presentation.isMuted)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func faux(on: Bool) -> some View {
        Capsule().fill(on ? accent : Color.white.opacity(0.18)).frame(width: 34, height: 20)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 16, height: 16).padding(2)
            }
    }

    private func message(_ text: String, button: (SaysoGalleryCardPresentation.Action, String, String), isError: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                .font(.system(size: 18)).foregroundStyle(accent)
            Text(text).font(.system(size: 12)).foregroundStyle(primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actionPill(button.0, button.1, symbol: button.2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.12)))
    }

    /// Real button so VoiceOver and keyboard can target it; absent when no handler is wired.
    @ViewBuilder
    private func actionPill(_ kind: SaysoGalleryCardPresentation.Action, _ title: String, symbol: String) -> some View {
        let handler = kind == .grant ? onGrant : onRetry
        let offered = kind == .grant
            ? presentation.offersGrantAction(hasHandler: handler != nil)
            : presentation.offersRetryAction(hasHandler: handler != nil)
        if offered, let handler {
            Button(action: handler) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var sample: [String] {
        switch scenario.moduleID {
        case "clip": ["Meeting notes draft", "https://sayso.app/docs", "Invoice #4021", "Shipping address"]
        case "timer": ["Focus  24:58", "Break  05:00", "Deep work  50:00", "Stretch  02:00"]
        case "media": ["Candy Paint, Post Malone", "Up next: Imagine Dragons", "Volume 60%", "AirPods Pro"]
        default: ["Item one", "Item two", "Item three", "Item four"]
        }
    }
}
