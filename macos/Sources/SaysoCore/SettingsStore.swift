import Foundation

public protocol SettingsStoring: Sendable {
    func load() -> SaysoSettings
    func save(_ settings: SaysoSettings)
}

public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "ai.sayso.notch.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SaysoSettings {
        guard let data = defaults.data(forKey: key) else { return SaysoSettings() }
        return (try? JSONDecoder().decode(SaysoSettings.self, from: data)) ?? SaysoSettings()
    }

    public func save(_ settings: SaysoSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
