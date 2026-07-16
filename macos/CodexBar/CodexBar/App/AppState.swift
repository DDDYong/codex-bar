import SwiftUI

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
    @Published var displayMode: MenuBarDisplayMode = .iconOnly { didSet { persistSettings() } }
    @Published private(set) var snapshots: [UsageSnapshotRecord] = []
    @Published private(set) var sessionEntries: [SessionIndexEntry] = []
    @Published private(set) var isIndexingSessions = false
    @Published private(set) var sessionOperationError: String?
    @Published private(set) var sessionOperationEntryID: String?
    @Published private(set) var pluginSkillEntries: [PluginSkillEntry] = []
    @Published private(set) var isIndexingPluginsSkills = false
    @Published private(set) var tokenActivityStats: TokenActivityStats = .empty
    @Published private(set) var isIndexingTokenActivity = false

    private let usageSource: CodexUsageSource
    private let sessionSource: SessionActivitySource
    private let snapshotStore: SnapshotStore
    private let sessionIndexSource: SessionIndexSource
    private let sessionLifecycleSource: SessionLifecycleManaging
    private let pluginSkillSource: PluginSkillSource
    private let tokenActivitySource: TokenActivitySource
    private let settingsStore: SettingsStore
    private var refreshTask: Task<Void, Never>?
    private var quotaPollingTask: Task<Void, Never>?
    private var sessionPollingTask: Task<Void, Never>?

    init(
        usageSource: CodexUsageSource = CodexUsageSource(),
        sessionSource: SessionActivitySource = SessionActivitySource(),
        snapshotStore: SnapshotStore = SnapshotStore(),
        settingsStore: SettingsStore = SettingsStore(),
        sessionIndexSource: SessionIndexSource = SessionIndexSource(),
        sessionLifecycleSource: SessionLifecycleManaging = SessionLifecycleSource(),
        pluginSkillSource: PluginSkillSource = PluginSkillSource(),
        tokenActivitySource: TokenActivitySource = TokenActivitySource()
    ) {
        self.usageSource = usageSource
        self.sessionSource = sessionSource
        self.snapshotStore = snapshotStore
        self.settingsStore = settingsStore
        self.sessionIndexSource = sessionIndexSource
        self.sessionLifecycleSource = sessionLifecycleSource
        self.pluginSkillSource = pluginSkillSource
        self.tokenActivitySource = tokenActivitySource
        self.snapshots = snapshotStore.load()
        let settings = settingsStore.load()
        self.displayMode = settings.displayMode
        self.theme = settings.theme
    }

    var menuBarTitle: String {
        MenuBarPresentation.title(for: displayMode, snapshot: currentUsage ?? lastSuccessfulUsage)
    }

    var availableDataSourceCount: Int {
        (currentUsage ?? lastSuccessfulUsage == nil ? 0 : 2)
            + (sessionActivity == .unknown ? 0 : 1)
            + (snapshots.isEmpty ? 0 : 1)
            + (tokenActivityStats.daily.isEmpty ? 0 : 1)
    }

    func start() {
        guard quotaPollingTask == nil else { return }
        refresh()
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshSessionActivity()
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
            do {
                let dashboardData = try await self.usageSource.fetchDashboardData()
                let snapshot = dashboardData.snapshot
                self.currentUsage = snapshot
                self.lastSuccessfulUsage = snapshot
                self.account = dashboardData.account
                self.usageError = nil
                let settings = self.settingsStore.load()
                try? self.snapshotStore.append(UsageSnapshotRecord(snapshot: snapshot), retentionDays: settings.snapshotRetentionDays)
                self.snapshots = self.snapshotStore.load()
            } catch {
                self.usageError = error.localizedDescription
            }
        }
    }

    private func refreshSessionActivity() {
        sessionActivity = sessionSource.liveActivity()
    }

    func clearSnapshots() {
        try? snapshotStore.clear()
        snapshots = []
    }

    func saveCurrentSnapshot() {
        guard let snapshot = currentUsage ?? lastSuccessfulUsage else { return }
        let settings = settingsStore.load()
        try? snapshotStore.append(
            UsageSnapshotRecord(snapshot: snapshot),
            retentionDays: settings.snapshotRetentionDays
        )
        snapshots = snapshotStore.load()
    }

    func exportedSnapshots() -> Data? {
        try? snapshotStore.export()
    }

    func updateSettings(_ settings: AppSettings) {
        displayMode = settings.displayMode
        theme = settings.theme
        settingsStore.save(settings)
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

    func refreshTokenActivity() {
        guard !isIndexingTokenActivity else { return }
        isIndexingTokenActivity = true
        let source = tokenActivitySource
        Task { [weak self] in
            let stats = await Task.detached { source.scan() }.value
            guard let self else { return }
            self.tokenActivityStats = stats
            self.isIndexingTokenActivity = false
        }
    }

    private func persistSettings() {
        var settings = settingsStore.load()
        settings.displayMode = displayMode
        settings.theme = theme
        settingsStore.save(settings)
    }

    deinit {
        refreshTask?.cancel()
        quotaPollingTask?.cancel()
        sessionPollingTask?.cancel()
    }
}
