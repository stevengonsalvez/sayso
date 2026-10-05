import Foundation

/// UI test launch hook: `--ui-test-color <hex>` makes every pick return that colour without showing the system
/// sampler, which would wait for a human click. Honoured only together with `--ui-test-fresh-settings`, so a real
/// launch always uses the real sampler.
public enum ColorPickerUITestHook {
    /// The fake sampler for a UI test launch, or nil to use the real one. An unreadable or missing colour gives a
    /// sampler that always cancels, never the real one.
    public static func sampler(arguments: [String]) -> ColorSamplingPort? {
        guard arguments.contains("--ui-test-fresh-settings"), let flag = arguments.firstIndex(of: "--ui-test-color")
        else { return nil }
        let value = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        return FixedColorSamplingPort(color: ColorPickerColor.parse(value.hasPrefix("#") ? value : "#" + value))
    }
}

private struct FixedColorSamplingPort: ColorSamplingPort {
    let color: ColorPickerColor?

    func pick() async -> ColorPickerColor? { color }
}
