import Foundation

/// Lets the user click one pixel anywhere on screen.
public protocol ColorSamplingPort: Sendable {
    /// The clicked pixel in sRGB, or nil when the user cancels.
    func pick() async -> ColorPickerColor?
}
