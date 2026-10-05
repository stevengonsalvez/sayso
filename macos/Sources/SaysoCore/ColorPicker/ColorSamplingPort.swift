import AppKit

/// Lets the user click one pixel anywhere on screen.
public protocol ColorSamplingPort: Sendable {
    /// The clicked pixel in sRGB, or nil when the user cancels.
    func pick() async -> ColorPickerColor?
}

/// The system colour sampler (`NSColorSampler`), shown on the main thread. It reads only the pixel the user clicks and
/// needs no Screen Recording permission. It waits for a human click or Escape, so tests never call `pick()`.
public struct SystemColorSamplingPort: ColorSamplingPort {
    public init() {}

    public func pick() async -> ColorPickerColor? { await Self.sample() }

    @MainActor
    private static func sample() async -> ColorPickerColor? {
        await withCheckedContinuation { continuation in
            let sampler = NSColorSampler()
            sampler.show { picked in
                // The sampler is kept alive until it answers.
                withExtendedLifetime(sampler) { continuation.resume(returning: picked.flatMap(color(from:))) }
            }
        }
    }

    /// The colour in sRGB, clamped when it lies outside it (a wide-gamut display); nil when it has no sRGB form.
    static func color(from color: NSColor) -> ColorPickerColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return ColorPickerColor(
            srgbRed: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)
        )
    }
}
