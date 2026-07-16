import Foundation

struct AppSettings: Codable, Equatable {
    var displayMode: MenuBarDisplayMode
    var theme: AppState.Theme
    var snapshotRetentionDays: Int
    var sessionIndexEnabled: Bool
    var pluginSkillIndexEnabled: Bool

    static let `default` = AppSettings(
        displayMode: .iconOnly,
        theme: .system,
        snapshotRetentionDays: 90,
        sessionIndexEnabled: true,
        pluginSkillIndexEnabled: true
    )
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "app-settings-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
