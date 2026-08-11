import Foundation

enum TokenHeatmapPeriod: String, CaseIterable, Codable, Identifiable {
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear

    var id: Self { self }

    var title: String {
        switch self {
        case .oneMonth: "近一个月"
        case .threeMonths: "近三个月"
        case .sixMonths: "近半年"
        case .oneYear: "近一年"
        }
    }

    var dayCount: Int {
        switch self {
        case .oneMonth: 31
        case .threeMonths: 92
        case .sixMonths: 183
        case .oneYear: 365
        }
    }
}

struct AppSettings: Codable, Equatable {
    var displayMode: MenuBarDisplayMode
    var theme: AppState.Theme
    var snapshotRetentionDays: Int
    var sessionIndexEnabled: Bool
    var pluginSkillIndexEnabled: Bool
    var tokenHeatmapPeriod: TokenHeatmapPeriod
    var launchAtLoginRequested: Bool?
    var enabledProviderIDs: Set<ProviderID>?
    var experimentalProvidersEnabled: Bool
    var deepSeekPlatformUsageEnabled: Bool

    static let `default` = AppSettings(
        displayMode: .iconOnly,
        theme: .system,
        snapshotRetentionDays: 90,
        sessionIndexEnabled: true,
        pluginSkillIndexEnabled: true,
        tokenHeatmapPeriod: .oneYear,
        launchAtLoginRequested: nil,
        enabledProviderIDs: nil,
        experimentalProvidersEnabled: false,
        deepSeekPlatformUsageEnabled: false
    )

    private enum CodingKeys: String, CodingKey {
        case displayMode, theme, snapshotRetentionDays, sessionIndexEnabled, pluginSkillIndexEnabled, tokenHeatmapPeriod, launchAtLoginRequested, enabledProviderIDs, experimentalProvidersEnabled, deepSeekPlatformUsageEnabled
    }

    init(
        displayMode: MenuBarDisplayMode,
        theme: AppState.Theme,
        snapshotRetentionDays: Int,
        sessionIndexEnabled: Bool,
        pluginSkillIndexEnabled: Bool,
        tokenHeatmapPeriod: TokenHeatmapPeriod = .oneYear,
        launchAtLoginRequested: Bool? = nil,
        enabledProviderIDs: Set<ProviderID>? = nil,
        experimentalProvidersEnabled: Bool = false,
        deepSeekPlatformUsageEnabled: Bool = false
    ) {
        self.displayMode = displayMode
        self.theme = theme
        self.snapshotRetentionDays = snapshotRetentionDays
        self.sessionIndexEnabled = sessionIndexEnabled
        self.pluginSkillIndexEnabled = pluginSkillIndexEnabled
        self.tokenHeatmapPeriod = tokenHeatmapPeriod
        self.launchAtLoginRequested = launchAtLoginRequested
        self.enabledProviderIDs = enabledProviderIDs
        self.experimentalProvidersEnabled = experimentalProvidersEnabled
        self.deepSeekPlatformUsageEnabled = deepSeekPlatformUsageEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = try container.decode(MenuBarDisplayMode.self, forKey: .displayMode)
        theme = try container.decode(AppState.Theme.self, forKey: .theme)
        snapshotRetentionDays = try container.decode(Int.self, forKey: .snapshotRetentionDays)
        sessionIndexEnabled = try container.decode(Bool.self, forKey: .sessionIndexEnabled)
        pluginSkillIndexEnabled = try container.decode(Bool.self, forKey: .pluginSkillIndexEnabled)
        tokenHeatmapPeriod = try container.decodeIfPresent(TokenHeatmapPeriod.self, forKey: .tokenHeatmapPeriod) ?? .oneYear
        launchAtLoginRequested = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginRequested)
        enabledProviderIDs = try container.decodeIfPresent(Set<ProviderID>.self, forKey: .enabledProviderIDs)
        experimentalProvidersEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalProvidersEnabled) ?? false
        deepSeekPlatformUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .deepSeekPlatformUsageEnabled) ?? false
    }
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
