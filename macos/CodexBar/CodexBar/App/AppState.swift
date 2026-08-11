import ServiceManagement
import SwiftUI

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class DisabledLaunchAtLoginManager: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

enum LaunchAtLoginManagerFactory {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchAtLoginManaging {
        if environment["XCTestConfigurationFilePath"] != nil {
            return DisabledLaunchAtLoginManager()
        }
        return SystemLaunchAtLoginManager()
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable, Codable {
        case system
        case light
        case dark

        var id: Self { self }

        var title: String {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    @Published var selectedRoute: DashboardRoute = .dashboard
    @Published var theme: Theme = .system { didSet { persistSettings() } }
    @Published private(set) var currentUsage: CodexUsageSnapshot?
    @Published private(set) var lastSuccessfulUsage: CodexUsageSnapshot?
    @Published private(set) var account: CodexAccount?
    @Published private(set) var usageError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var sessionActivity: SessionActivity = .unknown
    @Published private(set) var providerActivities: ProviderActivitySnapshot = .unknown
    @Published var displayMode: MenuBarDisplayMode = .iconOnly { didSet { persistSettings() } }
    @Published private(set) var snapshots: [UsageSnapshotRecord] = []
    @Published private(set) var sessionEntries: [SessionIndexEntry] = []
    @Published private(set) var isIndexingSessions = false
    @Published private(set) var sessionOperationError: String?
    @Published private(set) var sessionOperationEntryID: String?
    @Published private(set) var pluginSkillEntries: [PluginSkillEntry] = []
    @Published private(set) var isIndexingPluginsSkills = false
    @Published private(set) var skillOperationError: String?
    @Published private(set) var skillOperationEntryID: String?
    @Published private(set) var skillOperationFailureEntryID: String?
    @Published private(set) var profileSnapshot: ProfileSnapshot?
    @Published var profileSnapshotError: String?
    @Published private(set) var isRefreshingProfileSnapshot = false
    @Published private(set) var tokenHeatmapPeriod: TokenHeatmapPeriod
    @Published private(set) var providerSnapshots: [ProviderID: ProviderFinancialSnapshot] = [:]
    @Published private(set) var providerErrors: [ProviderID: String] = [:]
    @Published private(set) var refreshingProviderIDs: Set<ProviderID> = []
    @Published private(set) var providerConnectionStates: [ProviderID: ProviderConnectionState] = [:]
    @Published private(set) var enabledProviderIDs: Set<ProviderID>
    @Published private(set) var experimentalProvidersEnabled = false
    @Published private(set) var deepSeekPlatformUsageEnabled = false
    @Published private(set) var proxyUsageByProvider: [ProviderID: ProxyDailyUsage] = [:]
    @Published private(set) var detectedProxyProviderIDs: Set<ProviderID> = []
    @Published private(set) var proxyUsageError: String?
    @Published private(set) var proxySchemaVersion: Int?
    @Published private(set) var officialUsageSnapshot: CodexUsageSnapshot?
    @Published private(set) var officialUsageError: String?
    @Published private(set) var menuBarProviderIndex = 0
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .notRegistered
    @Published private(set) var launchAtLoginError: String?
    let isProxyUsageConfigured: Bool

    private let usageSource: CodexUsageSource
    private let sessionSource: SessionActivityReading
    private let snapshotStore: SnapshotStore
    private let sessionIndexSource: SessionIndexSource
    private let sessionLifecycleSource: SessionLifecycleManaging
    private let pluginSkillSource: PluginSkillSource
    private let skillLifecycleSource: SkillLifecycleManaging
    private let profileSnapshotStore: ProfileSnapshotStore
    private let profileCardRecognizer: ProfileCardRecognizing
    private let profileActivitySource: CodexActivityReading
    private let settingsStore: SettingsStore
    private let providerMetricsSources: [ProviderID: any ProviderMetricsSource]
    private let providerCredentialStore: ProviderCredentialStoring
    private let legacyDeepSeekConfigured: Bool
    private let proxyUsageSource: (any ProxyUsageReading)?
    private let launchAtLoginManager: LaunchAtLoginManaging
    private var refreshTask: Task<Void, Never>?
    private var quotaPollingTask: Task<Void, Never>?
    private var sessionPollingTask: Task<Void, Never>?
    private var profileActivityPollingTask: Task<Void, Never>?
    private var profileActivityRefreshTask: Task<Void, Never>?
    private var menuBarRotationTask: Task<Void, Never>?
    private var providerRefreshGenerations: [ProviderID: UInt64] = [:]
    private var providerRefreshCounts: [ProviderID: Int] = [:]
    private var credentialOperationGenerations: [CredentialOperationKey: UInt64] = [:]
    private var credentialTransactions: [CredentialOperationKey: CredentialTransaction] = [:]

    private struct CredentialOperationKey: Hashable {
        let providerID: ProviderID
        let kind: ProviderCredentialKind
    }

    private enum CredentialRollbackValue {
        case missing
        case credential(String)
    }

    private struct CredentialTransaction {
        let generation: UInt64
        let baseline: CredentialRollbackValue
        let candidate: String
    }

    init(
        usageSource: CodexUsageSource = CodexUsageSource(),
        sessionSource: SessionActivityReading = SessionActivitySource(),
        snapshotStore: SnapshotStore = SnapshotStore(),
        settingsStore: SettingsStore = SettingsStore(),
        sessionIndexSource: SessionIndexSource = SessionIndexSource(),
        sessionLifecycleSource: SessionLifecycleManaging = SessionLifecycleSource(),
        pluginSkillSource: PluginSkillSource = PluginSkillSource(),
        skillLifecycleSource: SkillLifecycleManaging = SkillLifecycleSource(),
        profileSnapshotStore: ProfileSnapshotStore = ProfileSnapshotStore(),
        profileCardRecognizer: ProfileCardRecognizing = ProfileCardRecognizer(),
        profileActivitySource: CodexActivityReading = CodexActivitySource(),
        deepSeekBalanceSource: DeepSeekBalanceSource? = nil,
        deepSeekConfigured: Bool = false,
        providerMetricsSources: [any ProviderMetricsSource] = [],
        providerCredentialStore: ProviderCredentialStoring = DisabledProviderCredentialStore(),
        enabledProviderIDs: Set<ProviderID>? = nil,
        proxyUsageSource: (any ProxyUsageReading)? = nil,
        deepSeekProviderID: String? = nil,
        launchAtLoginManager: LaunchAtLoginManaging = DisabledLaunchAtLoginManager()
    ) {
        self.usageSource = usageSource
        self.sessionSource = sessionSource
        self.snapshotStore = snapshotStore
        self.settingsStore = settingsStore
        self.sessionIndexSource = sessionIndexSource
        self.sessionLifecycleSource = sessionLifecycleSource
        self.pluginSkillSource = pluginSkillSource
        self.skillLifecycleSource = skillLifecycleSource
        self.profileSnapshotStore = profileSnapshotStore
        self.profileCardRecognizer = profileCardRecognizer
        self.profileActivitySource = profileActivitySource
        var sources = Dictionary(uniqueKeysWithValues: providerMetricsSources.map { ($0.providerID, $0) })
        if sources[.deepseek] == nil, let deepSeekBalanceSource {
            sources[.deepseek] = DeepSeekMetricsSource(
                balanceSource: deepSeekBalanceSource,
                configured: { true }
            )
        }
        self.providerMetricsSources = sources
        self.providerCredentialStore = providerCredentialStore
        self.legacyDeepSeekConfigured = deepSeekConfigured || deepSeekBalanceSource != nil
        self.proxyUsageSource = proxyUsageSource
        _ = deepSeekProviderID
        self.launchAtLoginManager = launchAtLoginManager
        self.isProxyUsageConfigured = proxyUsageSource != nil
        self.snapshots = snapshotStore.load()
        self.profileSnapshot = profileSnapshotStore.load()
        let settings = settingsStore.load()
        self.experimentalProvidersEnabled = settings.experimentalProvidersEnabled
        self.deepSeekPlatformUsageEnabled = settings.deepSeekPlatformUsageEnabled
        let configuredProviderIDs = Set(sources.values.filter(\.isConfigured).map(\.providerID))
            .union(self.legacyDeepSeekConfigured ? [.deepseek] : [])
        self.enabledProviderIDs = enabledProviderIDs
            ?? settings.enabledProviderIDs
            ?? configuredProviderIDs
        self.displayMode = settings.displayMode
        self.theme = settings.theme
        self.tokenHeatmapPeriod = settings.tokenHeatmapPeriod
        let launchStatus = launchAtLoginManager.status
        self.launchAtLoginStatus = launchStatus
        self.launchAtLoginEnabled = launchStatus == .enabled
        if settings.launchAtLoginRequested == nil {
            var migratedSettings = settings
            migratedSettings.launchAtLoginRequested = launchStatus == .enabled || launchStatus == .requiresApproval
            settingsStore.save(migratedSettings)
        }
    }

    var providerBalance: ProviderBalance? {
        providerSnapshots[.deepseek]?.legacyProviderBalance
    }

    var proxyDailyUsage: ProxyDailyUsage? {
        proxyUsageByProvider[.deepseek]
    }

    var providerBalanceError: String? {
        providerErrors[.deepseek]
    }

    var isRefreshingBalance: Bool {
        refreshingProviderIDs.contains(.deepseek)
    }

    var isDeepSeekConfigured: Bool {
        enabledProviderIDs.contains(.deepseek) && isProviderConfigured(.deepseek)
    }

    var configuredProviderIDs: [ProviderID] {
        ProviderID.allCases.filter { effectiveEnabledProviderIDs.contains($0) && isProviderConfigured($0) }
    }

    var effectiveEnabledProviderIDs: Set<ProviderID> {
        Set(enabledProviderIDs.filter { !($0.isExperimental && !experimentalProvidersEnabled) })
    }

    var orderedProviderSnapshots: [ProviderFinancialSnapshot] {
        ProviderID.allCases.compactMap { providerSnapshots[$0] }
    }

    func isProviderConfigured(_ providerID: ProviderID) -> Bool {
        if providerID.isExperimental, !experimentalProvidersEnabled { return false }
        if providerID == .deepseek, legacyDeepSeekConfigured { return true }
        return providerMetricsSources[providerID]?.isConfigured == true
            || detectedProxyProviderIDs.contains(providerID)
    }

    func hasCredential(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool {
        if providerCredentialStore.contains(providerID: providerID, kind: kind) { return true }
        return providerID == .deepseek && kind == .apiKey && isProviderConfigured(.deepseek)
    }

    func hasStoredCredential(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool {
        providerCredentialStore.contains(providerID: providerID, kind: kind)
    }

    func isCredentialOperationActive(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool {
        credentialTransactions[CredentialOperationKey(providerID: providerID, kind: kind)] != nil
    }

    var menuBarLayoutItems: [MenuBarProviderItem] {
        MenuBarPresentation.providerItems(
            for: displayMode,
            snapshot: currentUsage ?? lastSuccessfulUsage ?? officialUsageSnapshot,
            providerSnapshots: providerSnapshots,
            enabledProviderIDs: effectiveEnabledProviderIDs,
            refreshingProviderIDs: refreshingProviderIDs,
            activities: providerActivities
        )
    }

    var menuBarProviderItems: [MenuBarProviderItem] {
        MenuBarPresentation.visibleProviderItems(from: menuBarLayoutItems)
    }

    var menuBarProviderItem: MenuBarProviderItem {
        let items = menuBarProviderItems
        return items[menuBarProviderIndex % items.count]
    }

    /// All data source rows shown in DataSourcesView, in display order.
    /// The UI reads this single list so sidebar badge, header, and settings
    /// all agree on available/total counts.
    var dataSourceStatuses: [(name: String, available: Bool)] {
        let official = currentUsage ?? lastSuccessfulUsage ?? officialUsageSnapshot
        let hasOfficial = official != nil
        let hasReset = Self.resetDataIsAvailable(in: official, now: Date())
        var sources: [(String, Bool)] = []
        sources.append(("Usage（ChatGPT 订阅）", hasOfficial))
        sources.append(("Reset", hasReset))
        for providerID in ProviderID.allCases where effectiveEnabledProviderIDs.contains(providerID) {
            sources.append((providerID.dataSourceName, providerSnapshots[providerID] != nil))
        }
        if isProxyUsageConfigured {
            sources.append(("cc-switch 代理遥测", !proxyUsageByProvider.isEmpty))
        }
        sources.append(("会话活动", sessionActivity != .unknown))
        sources.append(("额度快照", !snapshots.isEmpty))
        sources.append(("全设备 Token", profileSnapshot != nil))
        return sources
    }

    var resetCreditsError: String? {
        let official = currentUsage ?? lastSuccessfulUsage ?? officialUsageSnapshot
        guard Self.resetDataIsAvailable(in: official, now: Date()) else {
            return usageError ?? "当前未取得新鲜且未到期的 Reset 数据。"
        }
        return nil
    }

    var resetCreditsUpdatedAt: Date? {
        let official = currentUsage ?? lastSuccessfulUsage ?? officialUsageSnapshot
        guard let official,
              ResetCreditsCachePolicy.isAvailable(
                  official.resetCredits,
                  capturedAt: official.updatedAt,
                  now: Date()
              ) else { return nil }
        return official.updatedAt
    }

    static func resetDataIsAvailable(in snapshot: CodexUsageSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        return ResetCreditsCachePolicy.isAvailable(
            snapshot.resetCredits,
            capturedAt: snapshot.updatedAt,
            now: now
        )
    }

    var availableDataSourceCount: Int {
        dataSourceStatuses.filter { $0.available }.count
    }

    var totalDataSourceCount: Int {
        dataSourceStatuses.count
    }

    func start() {
        guard quotaPollingTask == nil else { return }
        reconcileLaunchAtLogin()
        refresh()
        refreshProfileSnapshot()
        refreshSessionActivity()
        quotaPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
        sessionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshSessionActivity()
            }
        }
        profileActivityPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshProfileSnapshot()
            }
        }
        menuBarRotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.advanceMenuBarProvider()
            }
        }
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshing = false
                self.refreshTask = nil
            }

            let cycleStartedAt = Date()
            let providerRefresh = Task { @MainActor in
                await self.refreshProviderMetrics()
            }
            let refreshedOfficialUsage = await self.refreshOfficialUsage()
            var refreshedProviders = await providerRefresh.value
            refreshedProviders.merge(self.refreshProxyUsage()) { _, newest in newest }
            if let refreshedOfficialUsage {
                self.persistCurrentUsageSnapshot(
                    officialSnapshot: refreshedOfficialUsage,
                    providerSnapshots: Array(refreshedProviders.values),
                    cycleStartedAt: cycleStartedAt
                )
            }
        }
    }

    private func refreshOfficialUsage() async -> CodexUsageSnapshot? {
        do {
            let dashboardData = try await usageSource.fetchDashboardData()
            let snapshot = snapshotByRetainingKnownResetCredits(dashboardData.snapshot)
            currentUsage = snapshot
            lastSuccessfulUsage = snapshot
            account = dashboardData.account
            usageError = nil
            officialUsageSnapshot = snapshot
            officialUsageError = nil
            return snapshot
        } catch {
            usageError = error.localizedDescription
            officialUsageError = error.localizedDescription
            return nil
        }
    }

    private func snapshotByRetainingKnownResetCredits(_ snapshot: CodexUsageSnapshot) -> CodexUsageSnapshot {
        let fetched = snapshot.resetCredits
        let merged = ResetCreditsCachePolicy.merged(
            fetched: fetched,
            previous: lastSuccessfulUsage,
            storedRecords: snapshots,
            now: snapshot.updatedAt
        )

        guard merged != fetched else {
            return snapshot
        }

        return CodexUsageSnapshot(
            plan: snapshot.plan,
            shortWindow: snapshot.shortWindow,
            weeklyWindow: snapshot.weeklyWindow,
            resetCredits: merged,
            updatedAt: snapshot.updatedAt,
            providerType: snapshot.providerType
        )
    }

    @discardableResult
    func refreshProviderMetrics(providerID: ProviderID? = nil) async -> [ProviderID: ProviderFinancialSnapshot] {
        let refreshesEnabledProvidersOnly = providerID == nil
        let providerIDs = providerID.map { [$0] }
            ?? ProviderID.allCases.filter { effectiveEnabledProviderIDs.contains($0) }

        let tasks = providerIDs.compactMap { currentProviderID -> Task<(ProviderID, ProviderFinancialSnapshot)?, Never>? in
            if refreshesEnabledProvidersOnly, !enabledProviderIDs.contains(currentProviderID) { return nil }
            let generation = beginProviderRefresh(currentProviderID)
            guard let source = providerMetricsSources[currentProviderID] else {
                if !currentProviderID.isExperimental {
                    providerErrors[currentProviderID] = "\(currentProviderID.displayName) 指标数据源未配置。"
                }
                endProviderRefresh(currentProviderID)
                return nil
            }
            guard source.isConfigured else {
                providerErrors[currentProviderID] = ProviderMetricsError
                    .credentialMissing(currentProviderID.displayName)
                    .localizedDescription
                endProviderRefresh(currentProviderID)
                return nil
            }

            return Task { @MainActor [weak self] in
                guard let self else { return nil }
                defer { self.endProviderRefresh(currentProviderID) }
                do {
                    let snapshot = try await source.fetchSnapshot()
                    guard self.providerRefreshGenerations[currentProviderID] == generation else { return nil }
                    self.providerSnapshots[currentProviderID] = snapshot
                    self.providerErrors[currentProviderID] = nil
                    return (currentProviderID, snapshot)
                } catch {
                    guard self.providerRefreshGenerations[currentProviderID] == generation else { return nil }
                    self.providerErrors[currentProviderID] = error.localizedDescription
                    return nil
                }
            }
        }

        var refreshed: [ProviderID: ProviderFinancialSnapshot] = [:]
        for task in tasks {
            if let (providerID, snapshot) = await task.value {
                refreshed[providerID] = snapshot
            }
        }
        return refreshed
    }

    private func beginProviderRefresh(_ providerID: ProviderID) -> UInt64 {
        let generation = (providerRefreshGenerations[providerID] ?? 0) &+ 1
        providerRefreshGenerations[providerID] = generation
        providerRefreshCounts[providerID, default: 0] += 1
        refreshingProviderIDs.insert(providerID)
        return generation
    }

    private func endProviderRefresh(_ providerID: ProviderID) {
        let remaining = max(0, (providerRefreshCounts[providerID] ?? 1) - 1)
        providerRefreshCounts[providerID] = remaining
        if remaining == 0 {
            providerRefreshCounts[providerID] = nil
            refreshingProviderIDs.remove(providerID)
        }
    }

    private func invalidateProviderRefresh(_ providerID: ProviderID) {
        providerRefreshGenerations[providerID] = (providerRefreshGenerations[providerID] ?? 0) &+ 1
    }

    @discardableResult
    func refreshProxyUsage() -> [ProviderID: ProviderFinancialSnapshot] {
        guard let proxyUsageSource else { return [:] }
        var refreshed: [ProviderID: ProviderFinancialSnapshot] = [:]
        do {
            let report = try proxyUsageSource.todayReport(appType: "codex", now: Date())
            proxyUsageByProvider = report.usageByProvider
            detectedProxyProviderIDs = report.detectedProviderIDs
            proxySchemaVersion = report.schemaVersion
            proxyUsageError = nil
            for (providerID, usage) in report.usageByProvider where effectiveEnabledProviderIDs.contains(providerID) {
                if providerSnapshots[providerID] == nil || providerSnapshots[providerID]?.source == .localProxy {
                    let snapshot = Self.proxySnapshot(providerID: providerID, usage: usage)
                    providerSnapshots[providerID] = snapshot
                    providerErrors[providerID] = nil
                    refreshed[providerID] = snapshot
                }
            }
        } catch {
            proxyUsageError = error.localizedDescription
        }
        return refreshed
    }

    func setProviderEnabled(_ providerID: ProviderID, enabled: Bool) {
        if providerID.isExperimental, !experimentalProvidersEnabled, enabled { return }
        if enabled {
            enabledProviderIDs.insert(providerID)
        } else {
            invalidateProviderRefresh(providerID)
            let credentialCleanupError = rollbackCredentialTransactions(providerID: providerID)
            enabledProviderIDs.remove(providerID)
            providerSnapshots[providerID] = nil
            providerErrors[providerID] = nil
            providerConnectionStates[providerID] = credentialCleanupError.map(ProviderConnectionState.failed) ?? .idle
        }
        var settings = settingsStore.load()
        settings.enabledProviderIDs = enabledProviderIDs
        settingsStore.save(settings)

        if enabled {
            refreshProxyUsage()
            Task { await refreshProviderMetrics(providerID: providerID) }
        }
    }

    func setExperimentalProvidersEnabled(_ enabled: Bool) {
        experimentalProvidersEnabled = enabled
        var settings = settingsStore.load()
        settings.experimentalProvidersEnabled = enabled
        settingsStore.save(settings)

        if enabled {
            refreshProxyUsage()
            Task {
                for providerID in ProviderID.allCases where providerID.isExperimental && enabledProviderIDs.contains(providerID) {
                    await refreshProviderMetrics(providerID: providerID)
                }
            }
        } else {
            for providerID in ProviderID.allCases where providerID.isExperimental {
                invalidateProviderRefresh(providerID)
                let credentialCleanupError = rollbackCredentialTransactions(providerID: providerID)
                providerSnapshots[providerID] = nil
                providerErrors[providerID] = nil
                providerConnectionStates[providerID] = credentialCleanupError.map(ProviderConnectionState.failed) ?? .idle
            }
        }
    }

    func setDeepSeekPlatformUsageEnabled(_ enabled: Bool) {
        deepSeekPlatformUsageEnabled = enabled
        var settings = settingsStore.load()
        settings.deepSeekPlatformUsageEnabled = enabled
        settingsStore.save(settings)
        Task { await refreshProviderMetrics(providerID: .deepseek) }
    }

    func saveAndTestProviderCredential(
        _ credential: String,
        providerID: ProviderID,
        kind: ProviderCredentialKind
    ) async {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            providerConnectionStates[providerID] = .failed(ProviderCredentialStoreError.invalidCredential.localizedDescription)
            return
        }

        providerConnectionStates[providerID] = .testing

        let operationKey = CredentialOperationKey(providerID: providerID, kind: kind)
        let baseline: CredentialRollbackValue
        if let transaction = credentialTransactions[operationKey] {
            baseline = transaction.baseline
        } else {
            if providerCredentialStore.contains(providerID: providerID, kind: kind) {
                do {
                    baseline = .credential(try providerCredentialStore.read(providerID: providerID, kind: kind))
                } catch {
                    providerConnectionStates[providerID] = .failed("无法读取旧凭据，已取消覆盖；原凭据未更改。")
                    return
                }
            } else {
                baseline = .missing
            }
        }
        let operationGeneration = (credentialOperationGenerations[operationKey] ?? 0) &+ 1
        credentialOperationGenerations[operationKey] = operationGeneration
        credentialTransactions[operationKey] = CredentialTransaction(
            generation: operationGeneration,
            baseline: baseline,
            candidate: value
        )

        do {
            try providerCredentialStore.save(value, providerID: providerID, kind: kind)
        } catch {
            guard isCurrentCredentialOperation(operationKey, generation: operationGeneration) else { return }
            let saveError = error.localizedDescription
            do {
                try restoreCredentialBaseline(for: operationKey)
                providerConnectionStates[providerID] = .failed("凭据保存失败，已恢复原凭据。\(saveError)")
            } catch {
                providerConnectionStates[providerID] = .failed("凭据保存失败，且未能恢复原凭据，请检查钥匙串。\(saveError)")
            }
            finishCredentialOperation(operationKey, generation: operationGeneration)
            return
        }

        do {
            guard let validator = providerMetricsSources[providerID] as? any ProviderCredentialValidating else {
                throw ProviderMetricsError.unavailable(providerID.displayName)
            }
            try await validator.validateCredential(kind: kind)
        } catch {
            guard isCurrentCredentialOperation(operationKey, generation: operationGeneration) else { return }
            let refreshError = error.localizedDescription
            do {
                let restoredExistingCredential = try restoreCredentialBaseline(for: operationKey)
                if restoredExistingCredential {
                    providerConnectionStates[providerID] = .failed("连接失败，已恢复原凭据。\(refreshError)")
                } else {
                    providerConnectionStates[providerID] = .failed("连接失败，未保留新凭据。\(refreshError)")
                }
            } catch {
                providerConnectionStates[providerID] = .failed("连接失败，且未能恢复原凭据，请检查钥匙串。\(refreshError)")
            }
            finishCredentialOperation(operationKey, generation: operationGeneration)
            return
        }

        guard isCurrentCredentialOperation(operationKey, generation: operationGeneration) else { return }
        await refreshProviderMetrics(providerID: providerID)
        guard isCurrentCredentialOperation(operationKey, generation: operationGeneration) else { return }

        if !enabledProviderIDs.contains(providerID) {
            enabledProviderIDs.insert(providerID)
            var settings = settingsStore.load()
            settings.enabledProviderIDs = enabledProviderIDs
            settingsStore.save(settings)
        }
        providerConnectionStates[providerID] = .succeeded(providerConnectionSuccessMessage(for: providerID))
        finishCredentialOperation(operationKey, generation: operationGeneration)
    }

    func testProviderConnection(_ providerID: ProviderID) async {
        providerConnectionStates[providerID] = .testing
        await refreshProviderMetrics(providerID: providerID)
        if let error = providerErrors[providerID] {
            providerConnectionStates[providerID] = .failed(error)
        } else {
            providerConnectionStates[providerID] = .succeeded(providerConnectionSuccessMessage(for: providerID))
        }
    }

    private func providerConnectionSuccessMessage(for providerID: ProviderID) -> String {
        guard let snapshot = providerSnapshots[providerID], !snapshot.issues.isEmpty else {
            return "连接成功，已读取官方指标。"
        }
        return "连接成功，可用指标已更新；部分降级：\(snapshot.issues.joined(separator: "、"))"
    }

    func deleteProviderCredential(providerID: ProviderID, kind: ProviderCredentialKind) {
        let operationKey = CredentialOperationKey(providerID: providerID, kind: kind)
        invalidateCredentialTransactionForDeletion(operationKey)
        invalidateProviderRefresh(providerID)
        do {
            try providerCredentialStore.delete(providerID: providerID, kind: kind)
            providerConnectionStates[providerID] = .idle
            if !isProviderConfigured(providerID) {
                providerSnapshots[providerID] = nil
                providerErrors[providerID] = ProviderMetricsError
                    .credentialMissing(providerID.displayName)
                    .localizedDescription
            }
        } catch {
            providerConnectionStates[providerID] = .failed(error.localizedDescription)
        }
    }

    private func isCurrentCredentialOperation(
        _ key: CredentialOperationKey,
        generation: UInt64
    ) -> Bool {
        credentialOperationGenerations[key] == generation
            && credentialTransactions[key]?.generation == generation
    }

    private func finishCredentialOperation(_ key: CredentialOperationKey, generation: UInt64) {
        guard isCurrentCredentialOperation(key, generation: generation) else { return }
        credentialTransactions[key] = nil
    }

    @discardableResult
    private func restoreCredentialBaseline(for key: CredentialOperationKey) throws -> Bool {
        guard let transaction = credentialTransactions[key] else {
            throw ProviderCredentialStoreError.notFound
        }
        return try restoreCredentialBaseline(transaction.baseline, for: key)
    }

    @discardableResult
    private func restoreCredentialBaseline(
        _ baseline: CredentialRollbackValue,
        for key: CredentialOperationKey
    ) throws -> Bool {
        switch baseline {
        case .credential(let credential):
            try providerCredentialStore.save(credential, providerID: key.providerID, kind: key.kind)
            return true
        case .missing:
            try providerCredentialStore.delete(providerID: key.providerID, kind: key.kind)
            return false
        }
    }

    private func invalidateCredentialTransactionForDeletion(_ key: CredentialOperationKey) {
        credentialOperationGenerations[key] = (credentialOperationGenerations[key] ?? 0) &+ 1
        credentialTransactions[key] = nil
    }

    private func rollbackCredentialTransactions(providerID: ProviderID) -> String? {
        var cleanupErrors: [String] = []
        for kind in providerID.credentialKinds {
            let key = CredentialOperationKey(providerID: providerID, kind: kind)
            credentialOperationGenerations[key] = (credentialOperationGenerations[key] ?? 0) &+ 1
            guard let transaction = credentialTransactions.removeValue(forKey: key) else { continue }
            do {
                try restoreCredentialBaseline(transaction.baseline, for: key)
            } catch {
                do {
                    try providerCredentialStore.delete(providerID: providerID, kind: kind)
                    cleanupErrors.append("\(kind.title) 未能恢复旧值，未验证凭据已删除。")
                } catch {
                    cleanupErrors.append("\(kind.title) 未能恢复或删除未验证凭据，请检查钥匙串。")
                }
            }
        }
        return cleanupErrors.isEmpty ? nil : cleanupErrors.joined(separator: " ")
    }

    func advanceMenuBarProvider() {
        let itemCount = menuBarProviderItems.count
        menuBarProviderIndex = itemCount > 1 ? (menuBarProviderIndex + 1) % itemCount : 0
    }

    func refreshSessionActivity() {
        let latestActivities = sessionSource.liveActivities()
        guard latestActivities != providerActivities else { return }
        let previousProvider = menuBarProviderItem.providerType
        providerActivities = latestActivities
        sessionActivity = latestActivities.aggregate
        let visibleItems = menuBarProviderItems
        if let preservedIndex = visibleItems.firstIndex(where: { $0.providerType == previousProvider }) {
            menuBarProviderIndex = preservedIndex
        } else {
            menuBarProviderIndex = 0
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        var settings = settingsStore.load()
        settings.launchAtLoginRequested = enabled
        settingsStore.save(settings)

        do {
            if enabled {
                if launchAtLoginManager.status != .enabled {
                    try launchAtLoginManager.register()
                }
            } else if launchAtLoginManager.status != .notRegistered {
                try launchAtLoginManager.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus(error: error)
        }
    }

    func reconcileLaunchAtLogin() {
        let settings = settingsStore.load()
        let status = launchAtLoginManager.status

        if settings.launchAtLoginRequested == true {
            switch status {
            case .enabled:
                refreshLaunchAtLoginStatus()
            case .requiresApproval:
                refreshLaunchAtLoginStatus(message: "需在系统设置 > 通用 > 登录项中允许 CodexBar")
            case .notRegistered, .notFound:
                do {
                    try launchAtLoginManager.register()
                    refreshLaunchAtLoginStatus()
                } catch {
                    refreshLaunchAtLoginStatus(error: error)
                }
            }
        } else if status == .enabled {
            var migratedSettings = settings
            migratedSettings.launchAtLoginRequested = true
            settingsStore.save(migratedSettings)
            refreshLaunchAtLoginStatus()
        } else {
            refreshLaunchAtLoginStatus()
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginManager.openSystemSettings()
    }

    private func refreshLaunchAtLoginStatus(error: Error? = nil, message: String? = nil) {
        launchAtLoginStatus = launchAtLoginManager.status
        launchAtLoginEnabled = launchAtLoginStatus == .enabled
        if let message {
            launchAtLoginError = message
        } else if let error {
            launchAtLoginError = "无法更新登录启动设置：\(error.localizedDescription)"
        } else if launchAtLoginStatus == .requiresApproval {
            launchAtLoginError = "需在系统设置 > 通用 > 登录项中允许 CodexBar"
        } else if launchAtLoginStatus == .notFound {
            launchAtLoginError = "系统未找到 CodexBar 登录项，请从 /Applications 重新启动应用"
        } else {
            launchAtLoginError = nil
        }
    }

    func clearSnapshots() {
        try? snapshotStore.clear()
        snapshots = []
    }

    func saveProfileSnapshot(_ draft: ProfileSnapshotDraft) -> Bool {
        guard draft.isReadyToSave,
              let totalTokens = draft.totalTokens,
              let peakDayTokens = draft.peakDayTokens,
              let currentStreakDays = draft.currentStreakDays,
              let longestStreakDays = draft.longestStreakDays else {
            profileSnapshotError = "请确认四项资料均已识别"
            return false
        }

        let snapshot = ProfileSnapshot(
            totalTokens: totalTokens,
            peakDayTokens: peakDayTokens,
            longestTaskDurationSeconds: draft.longestTaskDurationSeconds,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            importedAt: Date(),
            sourceLabel: "Codex Profile 分享卡片"
        )

        do {
            try profileSnapshotStore.save(snapshot)
            profileSnapshot = snapshot
            profileSnapshotError = nil
            return true
        } catch {
            profileSnapshotError = error.localizedDescription
            return false
        }
    }

    func recognizeProfileSnapshot(imageData: Data) async -> ProfileSnapshotDraft? {
        do {
            let draft = try profileCardRecognizer.recognize(imageData: imageData)
            profileSnapshotError = nil
            return draft
        } catch {
            profileSnapshotError = error.localizedDescription
            return nil
        }
    }

    func clearProfileSnapshot() {
        do {
            try profileSnapshotStore.clear()
            profileSnapshot = nil
            profileSnapshotError = nil
        } catch {
            profileSnapshotError = error.localizedDescription
        }
    }

    func refreshProfileSnapshot() {
        guard profileActivityRefreshTask == nil else { return }
        isRefreshingProfileSnapshot = true
        let source = profileActivitySource
        profileActivityRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshingProfileSnapshot = false
                self.profileActivityRefreshTask = nil
            }
            do {
                let summary = try await source.fetchSummary()
                let snapshot = ProfileSnapshot(
                    totalTokens: summary.lifetimeTokens,
                    peakDayTokens: summary.peakDailyTokens,
                    longestTaskDurationSeconds: summary.longestRunningTurnSeconds,
                    currentStreakDays: summary.currentStreakDays,
                    longestStreakDays: summary.longestStreakDays,
                    importedAt: Date(),
                    sourceLabel: "Codex app-server 全设备同步",
                    dailyUsageBuckets: summary.dailyUsageBuckets
                )
                try self.profileSnapshotStore.save(snapshot)
                self.profileSnapshot = snapshot
                self.profileSnapshotError = nil
            } catch {
                self.profileSnapshotError = error.localizedDescription
            }
        }
    }

    func saveCurrentSnapshot() {
        let now = Date()
        let capturedAt = snapshots.last.map {
            max(now, $0.capturedAt.addingTimeInterval(0.001))
        } ?? now
        persistCurrentUsageSnapshot(
            officialSnapshot: currentUsage ?? lastSuccessfulUsage ?? officialUsageSnapshot,
            providerSnapshots: orderedProviderSnapshots,
            cycleStartedAt: now,
            capturedAt: capturedAt,
            deduplicate: false
        )
    }

    private func persistCurrentUsageSnapshot(
        officialSnapshot: CodexUsageSnapshot?,
        providerSnapshots: [ProviderFinancialSnapshot],
        cycleStartedAt: Date,
        capturedAt: Date? = nil,
        deduplicate: Bool = true
    ) {
        guard let snapshot = officialSnapshot else { return }
        let settings = settingsStore.load()
        try? snapshotStore.append(
            UsageSnapshotRecord(
                snapshot: snapshot,
                providerSnapshots: providerSnapshots,
                cycleStartedAt: cycleStartedAt,
                capturedAt: capturedAt
            ),
            retentionDays: settings.snapshotRetentionDays,
            deduplicate: deduplicate
        )
        snapshots = snapshotStore.load()
    }

    func exportedSnapshots() -> Data? {
        try? snapshotStore.export()
    }

    func updateSettings(_ settings: AppSettings) {
        displayMode = settings.displayMode
        theme = settings.theme
        tokenHeatmapPeriod = settings.tokenHeatmapPeriod
        var mergedSettings = settings
        mergedSettings.launchAtLoginRequested = settingsStore.load().launchAtLoginRequested
        mergedSettings.enabledProviderIDs = enabledProviderIDs
        mergedSettings.experimentalProvidersEnabled = experimentalProvidersEnabled
        mergedSettings.deepSeekPlatformUsageEnabled = deepSeekPlatformUsageEnabled
        settingsStore.save(mergedSettings)
        if !settings.sessionIndexEnabled { sessionEntries = [] }
        if !settings.pluginSkillIndexEnabled { pluginSkillEntries = [] }
    }

    func settings() -> AppSettings {
        settingsStore.load()
    }

    func refreshSessionIndex() {
        guard settingsStore.load().sessionIndexEnabled else {
            sessionEntries = []
            return
        }
        guard !isIndexingSessions else { return }
        isIndexingSessions = true
        let source = sessionIndexSource
        Task { [weak self] in
            let entries = await Task.detached { source.scan() }.value
            guard let self else { return }
            self.sessionEntries = entries
            self.isIndexingSessions = false
        }
    }

    var isOperatingOnSession: Bool {
        sessionOperationEntryID != nil
    }

    func archiveSession(_ entry: SessionIndexEntry) async {
        await performSessionOperation(entry) { try self.sessionLifecycleSource.archive($0) }
    }

    func unarchiveSession(_ entry: SessionIndexEntry) async {
        await performSessionOperation(entry) { try self.sessionLifecycleSource.unarchive($0) }
    }

    func deleteSession(_ entry: SessionIndexEntry) async {
        await performSessionOperation(entry) { try self.sessionLifecycleSource.delete($0) }
    }

    private func performSessionOperation(
        _ entry: SessionIndexEntry,
        operation: (SessionIndexEntry) throws -> Void
    ) async {
        guard sessionOperationEntryID == nil else { return }
        sessionOperationEntryID = entry.id
        sessionOperationError = nil
        do {
            try operation(entry)
            refreshSessionIndex()
        } catch {
            sessionOperationError = error.localizedDescription
        }
        sessionOperationEntryID = nil
    }

    var isOperatingOnSkill: Bool {
        skillOperationEntryID != nil
    }

    func uninstallSkill(_ entry: PluginSkillEntry) async {
        guard skillOperationEntryID == nil else { return }
        skillOperationEntryID = entry.id
        skillOperationError = nil
        skillOperationFailureEntryID = nil
        do {
            try skillLifecycleSource.uninstall(entry)
            refreshPluginSkillIndex()
        } catch {
            skillOperationError = error.localizedDescription
            skillOperationFailureEntryID = entry.id
        }
        skillOperationEntryID = nil
    }

    func refreshPluginSkillIndex() {
        guard settingsStore.load().pluginSkillIndexEnabled else {
            pluginSkillEntries = []
            return
        }
        guard !isIndexingPluginsSkills else { return }
        isIndexingPluginsSkills = true
        let source = pluginSkillSource
        Task { [weak self] in
            let entries = await Task.detached { source.scan() }.value
            guard let self else { return }
            self.pluginSkillEntries = entries
            self.isIndexingPluginsSkills = false
        }
    }

    private func persistSettings() {
        var settings = settingsStore.load()
        settings.displayMode = displayMode
        settings.theme = theme
        settingsStore.save(settings)
    }

    private static func proxySnapshot(providerID: ProviderID, usage: ProxyDailyUsage) -> ProviderFinancialSnapshot {
        ProviderFinancialSnapshot(
            providerID: providerID,
            capabilities: providerID.capabilities,
            balance: nil,
            spending: [SpendingSnapshot(
                amount: usage.totalCostUSD,
                currency: "USD",
                period: .today,
                isProviderReported: false
            )],
            tokens: TokenUsageSnapshot(
                input: usage.inputTokens,
                output: usage.outputTokens,
                cached: usage.cacheReadTokens + usage.cacheCreationTokens,
                reasoning: nil,
                period: .today,
                coverage: .proxiedRequests
            ),
            budget: nil,
            source: .localProxy,
            confidence: .estimated,
            coverage: .proxiedRequests,
            updatedAt: usage.updatedAt
        )
    }

    deinit {
        refreshTask?.cancel()
        quotaPollingTask?.cancel()
        sessionPollingTask?.cancel()
        profileActivityPollingTask?.cancel()
        profileActivityRefreshTask?.cancel()
        menuBarRotationTask?.cancel()
    }
}
