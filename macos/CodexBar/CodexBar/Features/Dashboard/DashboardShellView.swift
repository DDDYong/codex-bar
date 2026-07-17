import AppKit
import Charts
import ServiceManagement
import SwiftUI

struct DashboardShellView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(selection: $appState.selectedRoute, theme: $appState.theme)
                .frame(width: 220)
            VStack(spacing: 0) {
                DashboardHeader(route: appState.selectedRoute)
                Group {
                    if appState.selectedRoute == .dashboard { DashboardHomeView() }
                    else if appState.selectedRoute == .usage { UsageContentView(route: appState.selectedRoute) }
                    else if appState.selectedRoute == .activity { ActivityTrendView() }
                    else if appState.selectedRoute == .dataSources { DataSourcesView() }
                    else if appState.selectedRoute == .settings { SettingsView() }
                    else if appState.selectedRoute == .sessions { SessionsView() }
                    else if appState.selectedRoute == .pluginsSkills { PluginsSkillsView() }
                    else { EmptyStatePage(route: appState.selectedRoute) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PrototypeFooter()
            }
            .background(PrototypePalette.main)
        }
        .frame(minWidth: AppConfiguration.minimumWindowSize.width, minHeight: AppConfiguration.minimumWindowSize.height)
        .background(PrototypePalette.shell)
    }
}

private enum PrototypePalette {
    static let shell = adaptive(dark: .init(red: 0.035, green: 0.061, blue: 0.094, alpha: 1), light: .init(red: 0.91, green: 0.93, blue: 0.96, alpha: 1))
    static let sidebar = adaptive(dark: .init(red: 0.055, green: 0.087, blue: 0.13, alpha: 1), light: .init(red: 0.96, green: 0.97, blue: 0.99, alpha: 1))
    static let main = adaptive(dark: .init(red: 0.043, green: 0.071, blue: 0.11, alpha: 1), light: .init(red: 0.98, green: 0.99, blue: 1, alpha: 1))
    static let panel = adaptive(dark: .init(red: 0.073, green: 0.112, blue: 0.165, alpha: 1), light: .init(red: 1, green: 1, blue: 1, alpha: 1))
    static let line = adaptive(dark: .init(red: 0.125, green: 0.18, blue: 0.25, alpha: 1), light: .init(red: 0.78, green: 0.82, blue: 0.88, alpha: 1))
    static let blue = Color(red: 0.16, green: 0.47, blue: 0.95)

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private enum UIStamp {
    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func string(_ timestamp: String) -> String {
        guard let date = fractionalISO.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        return string(date)
    }

    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func expiryString(_ timestamp: String) -> String {
        guard let date = date(from: timestamp) else { return timestamp }
        return expiryFormatter.string(from: date)
    }

    static func date(from timestamp: String) -> Date? {
        fractionalISO.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}

private struct PrototypeFooter: View {
    var body: some View {
        HStack {
            Text("🛡 数据保存在本地，仅用于显示统计与分析")
            Spacer()
            Text("当前时区：Asia/Shanghai（UTC+8）")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .frame(height: 34)
        .overlay(alignment: .top) { Divider().overlay(PrototypePalette.line) }
    }
}

private struct PluginsSkillsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var kind: PluginSkillEntry.Kind?
    @State private var detailEntry: PluginSkillEntry?

    private var entries: [PluginSkillEntry] {
        appState.pluginSkillEntries.filter {
            (kind == nil || $0.kind == kind) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("插件与 Skills").font(.title3.weight(.bold))
                Spacer()
                Button("重新索引") { appState.refreshPluginSkillIndex() }
                    .disabled(appState.isIndexingPluginsSkills)
            }
            HStack {
                TextField("搜索名称或路径", text: $query).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $kind) {
                    Text("全部").tag(PluginSkillEntry.Kind?.none)
                    ForEach(PluginSkillEntry.Kind.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .frame(width: 130)
            }
            if appState.isIndexingPluginsSkills {
                ProgressView("正在只读索引插件与 Skills 元数据…")
            } else if !appState.settings().pluginSkillIndexEnabled {
                UsageEmptyState(title: "插件与 Skills 索引已关闭", message: "可在“设置”中开启元数据读取。", icon: "lock")
            } else if entries.isEmpty {
                UsageEmptyState(title: "暂无可验证项目", message: "只识别带 Codex 标记的插件 manifest 与 SKILL.md 元数据。", icon: "puzzlepiece")
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(entry.name).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text(PluginSkillGuide.forEntry(entry).category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(5)
                                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    Text(entry.kind.title).font(.caption2).foregroundStyle(.blue).padding(5).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                }
                                Text(entry.detail ?? "已验证的本地元数据。") .font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(height: 42, alignment: .topLeading)
                                Text(entry.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                            .onTapGesture { detailEntry = entry }
                            .help("点按查看详情")
                        }
                    }
                }
            }
        }
        .padding(22)
        .task { appState.refreshPluginSkillIndex() }
        .sheet(item: $detailEntry) { entry in
            PluginSkillDetailSheet(entry: entry)
        }
    }
}

private struct PluginSkillDetailSheet: View {
    let entry: PluginSkillEntry
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var showsUninstallConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(entry.name).font(.title3.weight(.semibold)); Spacer(); Text(entry.kind.title).foregroundStyle(.blue) }
            VStack(alignment: .leading, spacing: 6) {
                Text(PluginSkillGuide.forEntry(entry).category).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Text(PluginSkillGuide.forEntry(entry).chineseSummary).font(.body)
                Text(PluginSkillGuide.forEntry(entry).howToUse).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if entry.kind == .skill,
               appState.skillOperationFailureEntryID == entry.id,
               let error = appState.skillOperationError {
                Text("Skill 卸载失败：\(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
                Spacer()
                if entry.kind == .skill {
                    Button(role: .destructive) { showsUninstallConfirmation = true } label: {
                        if appState.skillOperationEntryID == entry.id {
                            ProgressView()
                        } else {
                            Text("卸载 Skill")
                        }
                    }
                    .disabled(appState.isOperatingOnSkill)
                    .confirmationDialog("卸载 \(entry.name)？", isPresented: $showsUninstallConfirmation, titleVisibility: .visible) {
                        Button("卸载", role: .destructive) {
                            Task {
                                await appState.uninstallSkill(entry)
                                if appState.skillOperationError == nil { dismiss() }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将永久删除 \(URL(fileURLWithPath: entry.path).deletingLastPathComponent().path)。")
                    }
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 360)
    }
}

private struct PluginSkillGuide {
    let category: String
    let chineseSummary: String
    let howToUse: String

    static func forEntry(_ entry: PluginSkillEntry) -> Self {
        let name = entry.name.lowercased()
        if name.contains("introspection") || name.contains("debug") {
            return .init(category: "调试诊断", chineseSummary: "用于排查 Codex 或代理执行失败、结果异常与中断流程。", howToUse: "出现难以复现的问题时，按它要求收集证据、定位原因并制定恢复步骤。")
        }
        if name.contains("reach") || name.contains("research") || name.contains("search") {
            return .init(category: "调研检索", chineseSummary: "用于需要查证资料、比较来源或形成调研结论的任务。", howToUse: "先说明调研目标和范围，再让 Codex 按来源收集、交叉验证并给出结论。")
        }
        if name.contains("sort") || name.contains("organize") {
            return .init(category: "工程整理", chineseSummary: "用于梳理仓库能力、规则和执行资源，形成可落地的组织方案。", howToUse: "在需要做项目收口、能力盘点或优先级排序时调用。")
        }
        if name.contains("api") {
            return .init(category: "接口设计", chineseSummary: "用于设计或评审 REST API 的资源、状态码、分页与错误返回。", howToUse: "说明业务对象与调用方需求，再输出接口契约和示例。")
        }
        if name.contains("article") || name.contains("writing") {
            return .init(category: "内容写作", chineseSummary: "用于编写文章、指南、教程和结构化文案。", howToUse: "提供目标读者、语气与主题，即可生成或改写内容。")
        }
        if name.contains("architecture") || name.contains("diagram") || name.contains("figma") {
            return .init(category: "设计制图", chineseSummary: "用于产品设计、架构表达或可视化图示相关工作。", howToUse: "提供需要表达的对象和层级关系，再生成对应的设计或图示方案。")
        }
        switch entry.kind {
        case .plugin:
            return .init(category: "应用扩展", chineseSummary: "为 Codex 增加外部应用或本机能力的插件。", howToUse: "在相关任务中启用后，按插件提供的能力完成操作。")
        case .mcp:
            return .init(category: "MCP 服务", chineseSummary: "向 Codex 提供受配置控制的工具或数据服务。", howToUse: "确认服务处于启用状态后，在对应任务中直接调用其能力。")
        case .skill:
            return .init(category: "通用技能", chineseSummary: "为 Codex 补充特定任务的工作方法与执行规范。", howToUse: "当任务与该技能名称或说明匹配时，Codex 会按其流程执行。")
        }
    }
}

private struct SessionsView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case active
        case archived

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "全部"
            case .active: "活跃"
            case .archived: "已归档"
            }
        }
    }

    private enum Sort: String, CaseIterable, Identifiable {
        case newest
        case name
        case size

        var id: Self { self }
        var title: String {
            switch self {
            case .newest: "最近活动"
            case .name: "名称"
            case .size: "会话大小"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .newest
    @State private var deletionEntry: SessionIndexEntry?

    private var entries: [SessionIndexEntry] {
        let filtered = appState.sessionEntries.filter {
            (filter == .all || $0.storage == (filter == .active ? .active : .archived))
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.filePath.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted {
            switch sort {
            case .newest: $0.modifiedAt > $1.modifiedAt
            case .name: $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            case .size: $0.fileSize > $1.fileSize
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("Codex 会话").font(.title3.weight(.bold)); }
                    if appState.isIndexingSessions {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("重新索引") { appState.refreshSessionIndex() }
                        .disabled(appState.isIndexingSessions)
                }
                HStack(spacing: 10) {
                    TextField("搜索已验证的标题或文件路径", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("状态", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 110)
                    Picker("排序", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 130)
                }
                if let error = appState.sessionOperationError {
                    Text("会话操作失败：\(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            if !appState.settings().sessionIndexEnabled {
                UsageEmptyState(title: "会话索引已关闭", message: "可在“设置”中开启会话元数据读取。", icon: "lock")
            } else if entries.isEmpty {
                UsageEmptyState(title: "暂无可验证会话", message: "索引只接受结构可识别的 JSONL 元数据，损坏文件会被跳过。", icon: "tray")
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(entries) { entry in
                            let isOperating = appState.sessionOperationEntryID == entry.id
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(entry.title).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text(entry.storage == .active ? "活跃" : "已归档")
                                        .font(.caption2)
                                        .foregroundStyle(entry.storage == .active ? .green : .orange)
                                        .padding(5)
                                        .background((entry.storage == .active ? Color.green : Color.orange).opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                                }
                                Text(entry.projectPath ?? entry.filePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                HStack { Text(UIStamp.string(entry.modifiedAt)); Spacer(); Text(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file)) }.font(.caption).foregroundStyle(.secondary)
                                ZStack {
                                    HStack {
                                        if let projectPath = entry.projectPath {
                                            Button("打开目录") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath) }
                                                .buttonStyle(.bordered)
                                                .disabled(isOperating)
                                        } else {
                                            Button("打开目录") {}
                                                .buttonStyle(.bordered)
                                                .disabled(true)
                                        }
                                        Spacer()
                                        Button("彻底删除", role: .destructive) { deletionEntry = entry }
                                            .buttonStyle(.bordered)
                                            .disabled(isOperating)
                                    }
                                    Button {
                                        Task {
                                            if entry.storage == .active { await appState.archiveSession(entry) }
                                            else { await appState.unarchiveSession(entry) }
                                        }
                                    } label: {
                                        if isOperating {
                                            HStack(spacing: 5) {
                                                ProgressView()
                                                Text("处理中…")
                                            }
                                        } else {
                                            Text(entry.storage == .active ? "归档" : "取消归档")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isOperating)
                                    .frame(minWidth: 82)
                                }
                                .controlSize(.small)
                            }
                            .padding(14).background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
        .task { appState.refreshSessionIndex() }
        .alert("彻底删除会话？", isPresented: Binding(
            get: { deletionEntry != nil },
            set: { if !$0 { deletionEntry = nil } }
        )) {
            Button("取消", role: .cancel) { deletionEntry = nil }
            Button("彻底删除", role: .destructive) {
                guard let entry = deletionEntry else { return }
                deletionEntry = nil
                Task { await appState.deleteSession(entry) }
            }
        } message: {
            Text("此操作不可恢复。")
        }
    }
}

private struct DataSourcesView: View {
    @EnvironmentObject private var appState: AppState

    private var usage: CodexUsageSnapshot? {
        appState.currentUsage ?? appState.lastSuccessfulUsage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("数据源").font(.title3.weight(.bold)); }; Spacer(); Text("\(appState.availableDataSourceCount) / 5 可用").font(.subheadline.weight(.semibold)).foregroundStyle(.green) }
                VStack(spacing: 12) {
                    SourceStatusRow(name: "Usage", status: usage == nil ? "未就绪" : "可用", updatedAt: usage?.updatedAt, risk: "请求时短暂读取 Codex 认证文件；不会保存或显示凭据。", error: appState.usageError)
                    SourceStatusRow(name: "Reset", status: usage == nil ? "未就绪" : "可用", updatedAt: usage?.updatedAt, risk: "随 Usage 刷新解析，仅读取已使用的接口响应。", error: appState.usageError)
                    SourceStatusRow(name: "会话活动", status: appState.sessionActivity == .unknown ? "暂无活动" : "可用", updatedAt: appState.sessionActivity == .unknown ? nil : Date(), risk: "仅聚合近期事件类型，不保存或展示会话正文。", error: nil)
                    SourceStatusRow(name: "额度快照", status: appState.snapshots.isEmpty ? "暂无记录" : "可用", updatedAt: appState.snapshots.last?.capturedAt, risk: "仅保存剩余额度百分比、时间和 Reset 次数。", error: nil)
                    SourceStatusRow(name: "全设备 Token 活动", status: appState.profileSnapshot == nil ? "未就绪" : "可用", updatedAt: appState.profileSnapshot?.importedAt, risk: "通过本机 Codex app-server 读取汇总，不读取或保存认证凭据、会话正文或图片。", error: appState.profileSnapshotError)
                }
            }
            .padding(22)
        }
    }
}

private struct SourceStatusRow: View {
    let name: String
    let status: String
    let updatedAt: Date?
    let risk: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(status).foregroundStyle(status == "可用" ? .green : .secondary)
            }
            if let updatedAt { Text("更新时间：\(updatedAt, style: .relative)").foregroundStyle(.secondary) }
            Text("范围：\(risk)").font(.caption).foregroundStyle(.secondary)
            if let error { Text("最近错误：\(error)").font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var settings = AppSettings.default
    @State private var launchAtLogin = false
    @State private var startupError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置").font(.title3.weight(.bold))
                SettingsSection(title: "外观") {
                    SettingsRow(title: "菜单栏显示") {
                        SettingsDropdown(
                            selection: binding(\.displayMode),
                            options: MenuBarDisplayMode.allCases.map { .init(title: $0.title, value: $0) }
                        )
                    }
                    SettingsRow(title: "主题") {
                        SettingsDropdown(
                            selection: binding(\.theme),
                            options: AppState.Theme.allCases.map { .init(title: $0.title, value: $0) }
                        )
                    }
                }
                SettingsSection(title: "本地数据") {
                    SettingsRow(title: "快照保留期") {
                        SettingsDropdown(
                            selection: binding(\.snapshotRetentionDays),
                            options: [
                                .init(title: "30 天", value: 30),
                                .init(title: "90 天", value: 90),
                                .init(title: "180 天", value: 180)
                            ]
                        )
                    }
                    SettingsRow(title: "Token 热力图周期") {
                        SettingsDropdown(
                            selection: binding(\.tokenHeatmapPeriod),
                            options: TokenHeatmapPeriod.allCases.map { .init(title: $0.title, value: $0) }
                        )
                    }
                    SettingsRow(title: "会话元数据") { Toggle("", isOn: binding(\.sessionIndexEnabled)).labelsHidden() }
                    SettingsRow(title: "插件与 Skills 元数据") { Toggle("", isOn: binding(\.pluginSkillIndexEnabled)).labelsHidden() }
                }
                SettingsSection(title: "隐私与安全") {
                    SettingsRow(title: "会话正文") { SettingsValue("不读取") }
                    SettingsRow(title: "认证凭据") { SettingsValue("不保存") }
                    SettingsRow(title: "本地数据") { SettingsValue("仅存于本机") }
                }
                SettingsSection(title: "启动") {
                    SettingsRow(title: "登录时启动 Codex Bar") {
                        Toggle("", isOn: $launchAtLogin).labelsHidden().onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                    }
                    if let startupError { Text(startupError).font(.caption).foregroundStyle(.orange) }
                }
                SettingsSection(title: "应用信息") {
                    SettingsRow(title: "版本") { SettingsValue(appVersion) }
                    SettingsRow(title: "数据源") { SettingsValue("\(appState.availableDataSourceCount) / 5 可用") }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(22)
        }
        .task {
            settings = appState.settings()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                appState.updateSettings(settings)
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startupError = nil
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            startupError = "无法更新登录启动设置：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal, 16).padding(.vertical, 12)
            content
        }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content.frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .top) { Divider().overlay(PrototypePalette.line).padding(.horizontal, 16) }
    }
}

private struct SettingsDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsDropdownOption<Value>]
    @State private var isPresented = false

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? "未设置"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(width: 120, height: 36)
            .background(PrototypePalette.shell.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(PrototypePalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(option.title)
                            Spacer()
                            if option.value == selection {
                                Image(systemName: "checkmark")
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 100, height: 30, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(option.value == selection ? .blue.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(6)
        }
    }
}

private struct SettingsDropdownOption<Value: Hashable>: Identifiable {
    let title: String
    let value: Value

    var id: String { title }
}

private struct SettingsValue: View {
    let value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct ActivityTrendView: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("活动统计").font(.title3.weight(.bold)); }
                    Spacer()
                    Button(appState.isRefreshingProfileSnapshot ? "正在同步…" : "立即同步") {
                        appState.refreshProfileSnapshot()
                    }
                    .disabled(appState.isRefreshingProfileSnapshot)
                    Button("导出快照") { exportSnapshots() }
                        .disabled(appState.snapshots.isEmpty)
                    Button("清空快照", role: .destructive) { confirmClear = true }
                        .disabled(appState.snapshots.isEmpty)
                }
                TokenActivityPanel()
                if appState.snapshots.count < 2 {
                    UsageEmptyState(title: "暂无趋势数据", message: "至少需要两条额度快照后才能计算估算变化。", icon: "chart.line.uptrend.xyaxis")
                        .frame(height: 280)
                        .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("近 30 条额度变化").font(.headline)
                        Chart(Array(appState.snapshots.suffix(30))) { record in
                            LineMark(x: .value("时间", record.capturedAt), y: .value("Week 剩余", record.weeklyRemainingPercent)).foregroundStyle(.blue)
                            PointMark(x: .value("时间", record.capturedAt), y: .value("Week 剩余", record.weeklyRemainingPercent)).foregroundStyle(.blue)
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 220)
                    }
                    .padding(16).background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 0) {
                        Text("快照记录").font(.headline).padding(16)
                        ForEach(appState.snapshots.suffix(30).reversed()) { record in
                            HStack { Text(UIStamp.string(record.capturedAt)); Spacer(); Text(String(format: "Week %.1f%%", record.weeklyRemainingPercent)).font(.subheadline.weight(.semibold)) }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                            Divider().overlay(PrototypePalette.line)
                        }
                    }
                    .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(22)
        }
        .alert("清空全部额度快照？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { appState.clearSnapshots() }
        } message: {
            Text("此操作会删除本应用保存的脱敏额度历史，且无法恢复。")
        }
    }

    private func exportSnapshots() {
        guard let data = appState.exportedSnapshots() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codex-bar-usage-snapshots.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct TokenActivityPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var isImporting = false
    @State private var draft: ProfileSnapshotDraft?
    @State private var isReviewingDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Token 活动").font(.headline)
                Spacer()
            }

            officialSnapshotSection
        }
        .padding(16)
        .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result,
                  let imageData = try? Data(contentsOf: url) else { return }
            recognize(imageData)
        }
        .onDrop(of: [.image], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { recognize(data) }
            }
            return true
        }
        .sheet(isPresented: $isReviewingDraft, onDismiss: discardDraft) {
            if let draft {
                ProfileSnapshotReviewSheet(
                    draft: draft,
                    error: appState.profileSnapshotError,
                    onConfirm: { confirmedDraft in
                        appState.saveProfileSnapshot(confirmedDraft)
                    },
                    onCancel: {
                    discardDraft()
                    }
                )
            }
        }
    }

    private var officialSnapshotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = appState.profileSnapshot {
                HStack(spacing: 0) {
                    metric("累计 Token", TokenFormatter.compact(snapshot.totalTokens))
                    metric("峰值日", TokenFormatter.compact(snapshot.peakDayTokens))
                    metric("最长任务", snapshot.longestTaskDurationSeconds.map(DurationFormatter.chinese) ?? "--")
                    metric("当前连续", "\(snapshot.currentStreakDays) 天")
                    metric("最长连续", "\(snapshot.longestStreakDays) 天")
                }
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                TokenActivityHeatmap(
                    buckets: snapshot.dailyUsageBuckets,
                    period: appState.tokenHeatmapPeriod
                )
            } else {
                Text("正在读取 Codex 全设备 Token 活动；首次同步可能需要几秒钟。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = appState.profileSnapshotError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func recognize(_ imageData: Data) {
        Task {
            guard let recognizedDraft = await appState.recognizeProfileSnapshot(imageData: imageData) else { return }
            draft = recognizedDraft
            isReviewingDraft = true
        }
    }

    private func discardDraft() {
        draft = nil
        isReviewingDraft = false
    }
}

private struct TokenActivityHeatmap: View {
    let buckets: [TokenActivityDay]
    let period: TokenHeatmapPeriod
    @State private var hoveredDay: HeatmapDay?
    @State private var hoveredWeekIndex: Int?
    @State private var displayMode: TokenActivityDisplayMode = .daily

    private let gap: CGFloat = 3
    private let tooltipInset: CGFloat = 6
    private let heatmapAspectRatio: CGFloat = 6.127
    private let maximumHeatmapHeight: CGFloat = 160

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    var body: some View {
        if buckets.isEmpty {
            Text("暂无每日 Token 数据；下次自动同步后会显示热力图。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("每日 Token 热力图").font(.subheadline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 14) {
                        ForEach(TokenActivityDisplayMode.allCases) { mode in
                            Button(mode.title) {
                                displayMode = mode
                                hoveredDay = nil
                                hoveredWeekIndex = nil
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(displayMode == mode ? .semibold : .regular))
                            .foregroundStyle(displayMode == mode ? PrototypePalette.blue : .secondary)
                        }
                    }
                    .accessibilityLabel("Token 活动维度")
                    .padding(.trailing, 8)
                    Text(period.title).font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let columns = weekColumns
                    let cellSize = max(8, min(16, (proxy.size.width - CGFloat(max(columns.count - 1, 0)) * gap) / CGFloat(max(columns.count, 1))))
                    let gridHeight = 7 * cellSize + 6 * gap
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: gap) {
                                ForEach(columns.indices, id: \.self) { weekIndex in
                                    VStack(spacing: gap) {
                                        ForEach(Array(columns[weekIndex].enumerated()), id: \.offset) { _, day in
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(color(for: day))
                                                .frame(width: cellSize, height: cellSize)
                                                .contentShape(Rectangle())
                                                .onHover { isHovering in
                                                    if isHovering, day?.isInSelectedPeriod == true, day?.isFuture == false {
                                                        hoveredDay = day
                                                        hoveredWeekIndex = weekIndex
                                                    } else if hoveredDay?.id == day?.id {
                                                        hoveredDay = nil
                                                        hoveredWeekIndex = nil
                                                    }
                                                }
                                                .help(hoverHelp(for: day))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, tooltipInset)

                        ForEach(monthMarkers(in: columns)) { marker in
                            Text(marker.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .position(
                                    x: min(max(14, CGFloat(marker.weekIndex) * (cellSize + gap) + 14), proxy.size.width - 14),
                                    y: tooltipInset + gridHeight + 12
                                )
                        }

                        if let hoveredDay, let hoveredWeekIndex {
                            HeatmapHoverCard(day: hoveredDay, mode: displayMode)
                                .fixedSize()
                                .position(
                                    x: min(max(120, CGFloat(hoveredWeekIndex) * (cellSize + gap) + cellSize / 2), proxy.size.width - 120),
                                    y: 15
                                )
                        }
                    }
                }
                .aspectRatio(heatmapAspectRatio, contentMode: .fit)
                .frame(maxHeight: maximumHeatmapHeight)
            }
            .padding(.top, 4)
        }
    }

    private var weekColumns: [[HeatmapDay?]] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        guard let currentWeekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today),
              let canvasStart = calendar.date(byAdding: .day, value: -(52 * 7), to: currentWeekStart),
              let selectedStart = calendar.date(byAdding: .day, value: -(period.dayCount - 1), to: today) else { return [] }
        let tokensByDate = Dictionary(buckets.map { ($0.startDate, $0.tokens) }, uniquingKeysWith: max)
        let formatter = Self.dateFormatter
        let days = (0..<371).compactMap { offset -> HeatmapDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: canvasStart) else { return nil }
            let startDate = formatter.string(from: date)
            return HeatmapDay(
                startDate: startDate,
                tokens: tokensByDate[startDate] ?? 0,
                displayTokens: tokensByDate[startDate] ?? 0,
                isInSelectedPeriod: date >= selectedStart && date <= today,
                isFuture: date > today
            )
        }
        let dailyColumns = stride(from: 0, to: days.count, by: 7).map { offset in
            Array(days[offset..<(offset + 7)])
        }
        switch displayMode {
        case .daily:
            return dailyColumns
        case .weekly:
            return dailyColumns.map { week in
                let total = week.compactMap { $0 }
                    .filter { $0.isInSelectedPeriod && !$0.isFuture }
                    .reduce(0) { $0 + $1.tokens }
                return week.map { day in
                    HeatmapDay(startDate: day.startDate, tokens: day.tokens, displayTokens: total, isInSelectedPeriod: day.isInSelectedPeriod, isFuture: day.isFuture)
                }
            }
        case .cumulative:
            var runningTotal = 0
            let cumulativeDays = days.map { day -> HeatmapDay? in
                if day.isInSelectedPeriod && !day.isFuture {
                    runningTotal += day.tokens
                    return HeatmapDay(startDate: day.startDate, tokens: day.tokens, displayTokens: runningTotal, isInSelectedPeriod: true, isFuture: false)
                }
                return day
            }
            return stride(from: 0, to: cumulativeDays.count, by: 7).map { offset in
                Array(cumulativeDays[offset..<(offset + 7)])
            }
        }
    }

    private func color(for day: HeatmapDay?) -> Color {
        guard let day else { return .clear }
        guard !day.isFuture else { return .secondary.opacity(0.06) }
        guard day.isInSelectedPeriod else { return .secondary.opacity(0.08) }
        guard day.displayTokens > 0 else { return .secondary.opacity(0.12) }
        let values = visibleDisplayValues.sorted()
        let rank = values.lastIndex(where: { $0 <= day.displayTokens }).map { Double($0 + 1) / Double(values.count) } ?? 0
        switch rank {
        case ..<0.2: return PrototypePalette.blue.opacity(0.32)
        case ..<0.4: return PrototypePalette.blue.opacity(0.48)
        case ..<0.6: return PrototypePalette.blue.opacity(0.64)
        case ..<0.8: return PrototypePalette.blue.opacity(0.80)
        default: return PrototypePalette.blue.opacity(1)
        }
    }

    private var visibleDisplayValues: [Int] {
        weekColumns.flatMap { $0 }
            .compactMap { $0 }
            .filter { $0.isInSelectedPeriod && !$0.isFuture && $0.displayTokens > 0 }
            .map(\.displayTokens)
    }

    private func monthMarkers(in columns: [[HeatmapDay?]]) -> [MonthMarker] {
        columns.enumerated().compactMap { weekIndex, week in
            guard let day = week.compactMap({ $0 }).first(where: { $0.startDate.hasSuffix("-01") }) else { return nil }
            let parts = day.startDate.split(separator: "-")
            guard parts.count > 1, let month = Int(parts[1]) else { return nil }
            return MonthMarker(weekIndex: weekIndex, label: "\(month)月")
        }
    }

    private func hoverHelp(for day: HeatmapDay?) -> String {
        guard let day else { return "" }
        guard !day.isFuture else { return "本周尚未到达的日期" }
        guard day.isInSelectedPeriod else { return "不在当前展示周期" }
        return heatmapText(for: day)
    }

    private func heatmapText(for day: HeatmapDay) -> String {
        switch displayMode {
        case .daily:
            return "\(day.startDate) 使用了 \(TokenFormatter.compact(day.displayTokens)) 个 Token"
        case .weekly:
            return "截至 \(day.startDate)，本周累计 \(TokenFormatter.compact(day.displayTokens)) 个 Token"
        case .cumulative:
            return "截至 \(day.startDate)，累计 \(TokenFormatter.compact(day.displayTokens)) 个 Token"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum TokenActivityDisplayMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: Self { self }

    var title: String {
        switch self {
        case .daily: "每日"
        case .weekly: "每周"
        case .cumulative: "累计"
        }
    }
}

private struct HeatmapDay: Identifiable {
    let startDate: String
    let tokens: Int
    let displayTokens: Int
    let isInSelectedPeriod: Bool
    let isFuture: Bool

    var id: String { startDate }
}

private struct MonthMarker: Identifiable {
    let weekIndex: Int
    let label: String

    var id: Int { weekIndex }
}

private struct HeatmapHoverCard: View {
    let day: HeatmapDay
    let mode: TokenActivityDisplayMode

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(PrototypePalette.panel.opacity(0.98), in: Capsule())
            .overlay(Capsule().stroke(PrototypePalette.line))
            .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
    }

    private var text: String {
        switch mode {
        case .daily:
            return "\(day.startDate) 使用了 \(TokenFormatter.compact(day.displayTokens)) 个 Token"
        case .weekly:
            return "截至 \(day.startDate)，本周累计 \(TokenFormatter.compact(day.displayTokens)) 个 Token"
        case .cumulative:
            return "截至 \(day.startDate)，累计 \(TokenFormatter.compact(day.displayTokens)) 个 Token"
        }
    }
}

private struct ProfileSnapshotReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var totalTokens: String
    @State private var peakDayTokens: String
    @State private var longestTaskDuration: String
    @State private var currentStreakDays: String
    @State private var longestStreakDays: String
    let error: String?
    let onConfirm: (ProfileSnapshotDraft) -> Bool
    let onCancel: () -> Void

    init(draft: ProfileSnapshotDraft, error: String?, onConfirm: @escaping (ProfileSnapshotDraft) -> Bool, onCancel: @escaping () -> Void) {
        _totalTokens = State(initialValue: draft.totalTokens.map(String.init) ?? "官方快照未提供")
        _peakDayTokens = State(initialValue: draft.peakDayTokens.map(String.init) ?? "官方快照未提供")
        _longestTaskDuration = State(initialValue: draft.longestTaskDurationSeconds.map(DurationFormatter.chinese) ?? "官方快照未提供")
        _currentStreakDays = State(initialValue: draft.currentStreakDays.map(String.init) ?? "官方快照未提供")
        _longestStreakDays = State(initialValue: draft.longestStreakDays.map(String.init) ?? "官方快照未提供")
        self.error = error
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认官方快照").font(.title3.weight(.bold))
            Text("请核对并补全四项官方数据后再保存。图片不会被保存。")
                .font(.caption).foregroundStyle(.secondary)
            field("累计 Token", text: $totalTokens)
            field("峰值日", text: $peakDayTokens)
            field("最长任务时长", text: $longestTaskDuration)
            field("当前连续", text: $currentStreakDays)
            field("最长连续", text: $longestStreakDays)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("确认保存") {
                    if onConfirm(reviewDraft) {
                        dismiss()
                    }
                }
                .disabled(!isComplete)
            }
        }
        .padding(22)
        .frame(width: 390)
    }

    private var isComplete: Bool {
        reviewDraft.isReadyToSave
    }

    private var reviewDraft: ProfileSnapshotDraft {
        ProfileSnapshotDraft(
            totalTokens: ProfileCardRecognizer.parseNumber(totalTokens),
            peakDayTokens: ProfileCardRecognizer.parseNumber(peakDayTokens),
            longestTaskDurationSeconds: ProfileCardRecognizer.parseDuration(longestTaskDuration),
            currentStreakDays: ProfileCardRecognizer.parseNumber(currentStreakDays),
            longestStreakDays: ProfileCardRecognizer.parseNumber(longestStreakDays)
        )
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private enum TokenFormatter {
    static func compact(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.1f 亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f 万", Double(value) / 10_000) }
        return "\(value)"
    }
}

private enum DurationFormatter {
    static func chinese(_ value: Int) -> String {
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(minutes)分"
    }

    static func compact(_ value: TimeInterval) -> String {
        guard value > 0 else { return "--" }
        let components = DateComponentsFormatter()
        components.allowedUnits = [.hour, .minute]
        components.unitsStyle = .abbreviated
        return components.string(from: value) ?? "--"
    }
}
private struct DashboardSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: DashboardRoute
    @Binding var theme: AppState.Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CodexBarIcon(size: 46)
                Text("Codex\nDashboard").font(.title3.weight(.bold)).lineSpacing(-2)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 72)

            VStack(spacing: 6) {
                ForEach(DashboardRoute.allCases) { route in
                    Button { selection = route } label: {
                        HStack(spacing: 12) {
                            Image(systemName: route.icon).frame(width: 18)
                            Text(route.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            if let badge = badge(for: route) { Text(badge).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 4).background(route == .dataSources ? .green.opacity(0.14) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(route == .dataSources ? .green : .secondary) }
                        }
                        .padding(.horizontal, 14).frame(height: 48)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .foregroundStyle(selection == route ? .white : .primary)
                        .background(selection == route ? PrototypePalette.blue : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)

            Spacer()
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    Circle().fill(appState.sessionActivity == .unknown ? Color.secondary : Color.green).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) { Text("最后刷新").font(.caption2).foregroundStyle(.secondary); Text(lastUpdated).font(.caption.weight(.semibold)) }
                    Spacer()
                    Button { appState.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).overlay(RoundedRectangle(cornerRadius: 8).stroke(PrototypePalette.line)) }.buttonStyle(.plain)
                }
                .padding(11).background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 13))
                HStack(spacing: 4) {
                    themeButton(.light, icon: "sun.max.fill")
                    themeButton(.dark, icon: "moon.fill")
                }
                .padding(5).background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 13))
            }
            .padding(14)
        }
        .background(PrototypePalette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(PrototypePalette.line).frame(width: 1) }
    }

    private var lastUpdated: String { (appState.currentUsage ?? appState.lastSuccessfulUsage).map { UIStamp.string($0.updatedAt) } ?? "等待首次刷新" }

    private func badge(for route: DashboardRoute) -> String? {
        switch route { case .sessions: return appState.sessionEntries.isEmpty ? nil : "\(appState.sessionEntries.count)"; case .pluginsSkills: return appState.pluginSkillEntries.isEmpty ? nil : "\(appState.pluginSkillEntries.count)"; case .dataSources: return "\(appState.availableDataSourceCount)/5"; default: return nil }
    }

    private func themeButton(_ option: AppState.Theme, icon: String) -> some View {
        Button { theme = option } label: { Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle()).foregroundStyle(theme == option ? .blue : .secondary).background(theme == option ? .blue.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
    }

    private var sessionStatusText: String {
        switch appState.sessionActivity {
        case .running: "会话运行中"
        case .waiting: "等待输入"
        case .completed: "最近已完成"
        case .failed: "检测到失败"
        case .unknown: "等待活动事件"
        }
    }
}

private struct DashboardHeader: View {
    let route: DashboardRoute
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("你好，端阳 👋")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text(appState.currentUsage?.plan ?? "本机登录")
                    Text("实时同步")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            headerButton(systemImage: "arrow.clockwise", help: "立即刷新额度数据") {
                appState.refresh()
            }
            .disabled(appState.isRefreshing)
            headerButton(systemImage: "gearshape.fill", help: "设置") {
                appState.selectedRoute = .settings
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
        .background(PrototypePalette.main)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PrototypePalette.line).frame(height: 1)
        }
    }

    private func headerButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PrototypePalette.line))
        .help(help)
    }
}

private struct UsageContentView: View {
    let route: DashboardRoute
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let snapshot = appState.currentUsage ?? appState.lastSuccessfulUsage {
                UsagePrototypePage(snapshot: snapshot)
            } else if appState.isRefreshing {
                ProgressView("正在读取额度数据…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = appState.usageError {
                UsageEmptyState(title: "额度数据暂不可用", message: error, icon: "exclamationmark.triangle")
            } else {
                UsageEmptyState(title: "暂无额度数据", message: "等待首次刷新完成。", icon: "gauge")
            }
        }
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Label(title, systemImage: icon).foregroundStyle(.secondary); Text(value).font(.title2.weight(.semibold)) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DashboardHomeView: View {
    @EnvironmentObject private var appState: AppState

    private enum Layout {
        static let spacing: CGFloat = 12
        static let contentPadding: CGFloat = 20
        static let topCardsHeight: CGFloat = 134
        static let analyticsRowHeight: CGFloat = 170
        static let summaryRowMinimumHeight: CGFloat = 160
    }

    private var snapshot: CodexUsageSnapshot? {
        appState.currentUsage ?? appState.lastSuccessfulUsage
    }

    var body: some View {
        Group {
            if let snapshot {
                GeometryReader { geometry in
                    let summaryRowHeight = max(
                        Layout.summaryRowMinimumHeight,
                        geometry.size.height
                            - (Layout.contentPadding * 2)
                            - Layout.topCardsHeight
                            - (Layout.spacing * 2)
                            - Layout.analyticsRowHeight
                    )

                    VStack(alignment: .leading, spacing: Layout.spacing) {
                        HStack(alignment: .top, spacing: Layout.spacing) {
                            QuotaMetricCard(
                                title: "Week 额度",
                                percentage: snapshot.weeklyWindow?.remainingPercent,
                                accent: .blue,
                                detail: resetDescription(snapshot.weeklyWindow?.resetsAt)
                            )
                            ResetMetricCard(credits: snapshot.resetCredits)
                            ResetExpiryPanel(values: snapshot.resetCredits.expiresAt)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: Layout.topCardsHeight)

                        VStack(spacing: Layout.spacing) {
                            HStack(spacing: Layout.spacing) {
                                DashboardTrendPanel(records: Array(appState.snapshots.suffix(30)))
                                    .frame(maxWidth: .infinity)
                                DashboardTokenActivityPanel(snapshot: appState.profileSnapshot)
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(height: Layout.analyticsRowHeight)

                            HStack(spacing: Layout.spacing) {
                                DashboardSummaryPanel(
                                    title: "最近会话",
                                    count: appState.sessionEntries.count,
                                    action: { appState.selectedRoute = .sessions }
                                ) {
                                    ForEach(appState.sessionEntries.prefix(3)) { entry in
                                        DashboardRow(title: entry.title, detail: entry.projectPath ?? entry.filePath, trailing: UIStamp.string(entry.modifiedAt))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                DashboardSummaryPanel(
                                    title: "插件、技能与 MCP",
                                    count: appState.pluginSkillEntries.count,
                                    action: { appState.selectedRoute = .pluginsSkills }
                                ) {
                                    DashboardPluginCounts(entries: appState.pluginSkillEntries)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(height: summaryRowHeight)
                        }
                    }
                    .padding(Layout.contentPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else if appState.isRefreshing {
                ProgressView("正在同步本机 Codex 登录状态与额度…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = appState.usageError {
                UsageEmptyState(title: "无法读取 Codex 数据", message: error, icon: "exclamationmark.triangle")
            } else {
                UsageEmptyState(title: "等待首次同步", message: "将从本机 Codex 登录状态读取实时额度。", icon: "gauge")
            }
        }
        .task {
            appState.refreshSessionIndex()
            appState.refreshPluginSkillIndex()
        }
    }

    private func resetDescription(_ value: String?) -> String {
        guard let value else { return "暂未提供重置时间" }
        return UIStamp.expiryString(value)
    }
}

private struct QuotaMetricCard: View {
    let title: String
    let percentage: Double?
    let accent: Color
    let detail: String

    var body: some View {
        DashboardTopCard(title: title) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().stroke(accent.opacity(0.15), lineWidth: 9)
                    Circle().trim(from: 0, to: CGFloat((percentage ?? 0) / 100)).stroke(accent, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 1) { Text(percentage.map { String(format: "%.0f%%", $0) } ?? "--").font(.title3.weight(.bold)); Text("剩余").font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text("实时额度").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("下次重置: ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                    }
                }
            }
        }
    }
}

private struct ResetMetricCard: View {
    let credits: CodexResetCredits

    var body: some View {
        DashboardTopCard(title: "Reset 次数") {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(.green)
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.black.opacity(0.78))
                }
                .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text(credits.availableCount.map { "\($0) 次" } ?? "--").font(.title2.weight(.bold))
                    Text(credits.expiresAt.first.map { "最近到期: \(UIStamp.expiryString($0))" } ?? "暂无到期时间")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }
}

private struct ResetExpiryPanel: View {
    let values: [String]

    var body: some View {
        DashboardTopCard(title: "Reset 到期时间", trailing: "\(values.count) 条") {
            if values.isEmpty {
                Text("暂无可展示的到期记录").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            HStack {
                                Text("\(index + 1)").font(.caption.weight(.bold)).frame(width: 20, height: 20).background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.green)
                                Text(UIStamp.expiryString(value)).font(.subheadline)
                                Spacer()
                                Text(ResetExpiryTiming.remainingDays(for: value))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private enum ResetExpiryTiming {
    static func secondsRemaining(for timestamp: String) -> TimeInterval? {
        guard let date = UIStamp.date(from: timestamp) else { return nil }
        return date.timeIntervalSinceNow
    }

    static func remainingDays(for timestamp: String) -> String {
        guard let seconds = secondsRemaining(for: timestamp) else { return "--" }
        guard seconds > 0 else { return "已到期" }
        return "\(max(1, Int(ceil(seconds / 86_400)))) 天"
    }

    static func status(for timestamp: String) -> String {
        guard let seconds = secondsRemaining(for: timestamp), seconds > 0 else { return "已到期" }
        return seconds < 7 * 86_400 ? "即将到期" : "可用"
    }

    static func statusColor(for timestamp: String) -> Color {
        switch status(for: timestamp) {
        case "即将到期": .orange
        case "已到期": .red
        default: .blue
        }
    }
}

private struct DashboardTopCard<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(height: 24)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 134, maxHeight: 134, alignment: .topLeading)
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DashboardTrendPanel: View {
    let records: [UsageSnapshotRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("近 30 条额度变化").font(.headline); Spacer(); Text("快照估算").font(.caption).foregroundStyle(.secondary) }
            if records.count < 2 {
                Text("数据不足，不绘制伪造曲线。完成至少两次真实刷新后显示趋势。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
            } else {
                Chart(records) { record in
                    LineMark(x: .value("时间", record.capturedAt), y: .value("Week 剩余", record.weeklyRemainingPercent)).foregroundStyle(.blue)
                    AreaMark(x: .value("时间", record.capturedAt), y: .value("Week 剩余", record.weeklyRemainingPercent)).foregroundStyle(.blue.opacity(0.12))
                }
                .chartYScale(domain: 0...100)
                .frame(height: 116)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DashboardTokenActivityPanel: View {
    let snapshot: ProfileSnapshot?
    @State private var hoveredDay: TokenActivityDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token 活动").font(.headline)
                Spacer()
                Text(syncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let snapshot {
                HStack(spacing: 0) {
                    tokenMetric(TokenFormatter.compact(snapshot.totalTokens), "累计 Token")
                    Divider().frame(height: 34)
                    tokenMetric(TokenFormatter.compact(snapshot.peakDayTokens), "峰值日")
                    Divider().frame(height: 34)
                    tokenMetric(String(snapshot.currentStreakDays) + " 天", "当前连续")
                }
                recentUsageBars(snapshot.dailyUsageBuckets)
            } else {
                Text("正在读取 Codex 全设备 Token 活动；完成同步后将在此显示每日用量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
    }

    private var syncStatus: String {
        guard let snapshot else { return "等待同步" }
        return "同步于 " + snapshot.importedAt.formatted(date: .omitted, time: .shortened)
    }

    private func tokenMetric(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func recentUsageBars(_ buckets: [TokenActivityDay]) -> some View {
        let recentDays = Array(buckets.suffix(7))
        let maximum = max(recentDays.map(\.tokens).max() ?? 0, 1)
        if recentDays.isEmpty {
            Text("暂无每日 Token 明细")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Chart(recentDays) { day in
                    BarMark(
                        x: .value("日期", day.startDate),
                        y: .value("Token", day.tokens),
                        width: .fixed(10)
                    )
                    .foregroundStyle(PrototypePalette.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .annotation(position: .top, alignment: .center) {
                        if hoveredDay?.id == day.id {
                            Text(TokenFormatter.compact(day.tokens))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(PrototypePalette.panel.opacity(0.96), in: Capsule())
                                .overlay(Capsule().stroke(PrototypePalette.line))
                        }
                    }
            }
                .chartYScale(domain: 0...maximum)
                .chartXAxis {
                    AxisMarks(values: recentDays.map(\.startDate)) { value in
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(String.self) {
                                Text(String(date.suffix(5)))
                            }
                        }
                        .font(.caption2)
                    }
                }
                .chartYAxis(.hidden)
                .chartPlotStyle { plotArea in
                    plotArea.background(.clear)
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    let plotFrame = geometry[proxy.plotAreaFrame]
                                    let relativeX = location.x - plotFrame.origin.x
                                    if let startDate = proxy.value(atX: relativeX, as: String.self) {
                                        hoveredDay = recentDays.first { $0.startDate == startDate }
                                    }
                                case .ended:
                                    hoveredDay = nil
                                }
                            }
                    }
                }

            .frame(height: 70)
        }
    }
}

private struct DashboardSummaryPanel<Content: View>: View {
    let title: String
    let count: Int
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Button("查看全部", action: action).font(.caption) }
            if count == 0 { Text("尚无可验证的本地记录。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 10) }
            else { content.frame(maxWidth: .infinity, alignment: .topLeading) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DashboardRow: View {
    let title: String
    let detail: String
    let trailing: String

    var body: some View {
        HStack { Image(systemName: "square.stack.3d.up").foregroundStyle(.blue); VStack(alignment: .leading, spacing: 1) { Text(title).font(.subheadline).lineLimit(1); Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Text(trailing).font(.caption2).foregroundStyle(.secondary) }
            .padding(.vertical, 2)
    }
}

private struct DashboardPluginCounts: View {
    let entries: [PluginSkillEntry]

    var body: some View {
        HStack(spacing: 0) {
            count("插件", .plugin, "puzzlepiece.extension")
            Divider().overlay(PrototypePalette.line)
            count("技能", .skill, "sparkles")
            Divider().overlay(PrototypePalette.line)
            count("MCP", .mcp, "server.rack")
        }
    }

    private func count(_ title: String, _ kind: PluginSkillEntry.Kind, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            Text("\(entries.filter { $0.kind == kind }.count)")
                .font(.title3.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct UsageEmptyState: View { let title: String; let message: String; let icon: String; var body: some View { VStack(spacing: 12) { Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary); Text(title).font(.headline); Text(message).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity) } }

private struct UsagePrototypePage: View {
    @EnvironmentObject private var appState: AppState
    let snapshot: CodexUsageSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("额度与 Reset").font(.title3.weight(.bold)); }
                    Spacer()
                    Button("导出记录") { exportSnapshots() }.buttonStyle(.bordered)
                    Button("保存快照") { appState.saveCurrentSnapshot() }.buttonStyle(.borderedProminent)
                }
                HStack(spacing: 12) {
                    UsageSummaryCard(title: "Week 剩余额度", value: snapshot.weeklyWindow.map { String(format: "%.0f%%", $0.remainingPercent) } ?? "--", note: "实时 Usage")
                    UsageSummaryCard(title: "可用 Reset", value: snapshot.resetCredits.availableCount.map { "\($0) 次" } ?? "--", note: "每次均有独立到期时间")
                    UsageSummaryCard(title: "最后刷新", value: UIStamp.string(snapshot.updatedAt), note: "同一刷新链路")
                }
                HStack(alignment: .top, spacing: 12) {
                    UsageResetExpiryCard(values: snapshot.resetCredits.expiresAt)
                        .frame(maxWidth: .infinity)
                    UsageQuotaCycleCard(window: snapshot.weeklyWindow)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 132)
                VStack(alignment: .leading, spacing: 0) {
                    Text("历史快照").font(.headline).padding(15)
                    Divider().overlay(PrototypePalette.line)
                    if appState.snapshots.isEmpty { Text("尚无本地快照记录。").font(.caption).foregroundStyle(.secondary).padding(15) }
                    else { ForEach(appState.snapshots.suffix(8).reversed()) { record in
                        HStack { Text(UIStamp.string(record.capturedAt)); Spacer(); Text(String(format: "Week %.1f%%", record.weeklyRemainingPercent)); Spacer(); Text(record.resetCredits.map { "\($0) 次" } ?? "--"); Spacer(); Text("UsageSource").foregroundStyle(.secondary) }.font(.caption).padding(.horizontal, 15).padding(.vertical, 10); Divider().overlay(PrototypePalette.line)
                    } }
                }
                .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(22)
        }
    }

    private func exportSnapshots() { guard let data = appState.exportedSnapshots() else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "codex-bar-usage-snapshots.json"; panel.allowedContentTypes = [.json]; guard panel.runModal() == .OK, let url = panel.url else { return }; try? data.write(to: url, options: .atomic) }
}

private struct UsageResetExpiryCard: View {
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reset 到期列表").font(.headline)
                Spacer()
                Text("\(values.count) 条").font(.caption).foregroundStyle(.secondary)
            }
//            HStack {
//                Text("序号").frame(width: 22)
//                Text("到期时间")
//                Spacer()
//                Text("剩余时间").frame(width: 42, alignment: .trailing)
//                Text("状态").frame(width: 54, alignment: .trailing)
//            }
//            .font(.caption2.weight(.semibold))
//            .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                                .frame(width: 22, height: 22)
                                .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                            Text(UIStamp.expiryString(value))
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ResetExpiryTiming.remainingDays(for: value))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                            Text(ResetExpiryTiming.status(for: value))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ResetExpiryTiming.statusColor(for: value))
                                .frame(width: 54, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .top)
        .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
    }
}

private struct UsageQuotaCycleCard: View {
    let window: CodexUsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("额度与周期").font(.headline)
                Spacer()
                Text(window.map { String(format: "%.0f%%", $0.remainingPercent) } ?? "--")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Week 额度").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: window?.remainingPercent ?? 0, total: 100).tint(.blue)
            }
            Divider().overlay(PrototypePalette.line)
            HStack {
                Text("下一次重置").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(window?.resetsAt.map(UIStamp.expiryString) ?? "暂未提供")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
        .background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PrototypePalette.line))
    }
}

private struct UsageSummaryCard: View {
    let title: String
    let value: String
    let note: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.weight(.bold)); Text(note).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 94, alignment: .leading).padding(15).background(PrototypePalette.panel, in: RoundedRectangle(cornerRadius: 14)) }
}

private struct ResetExpiryList: View {
    let values: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reset 到期时间").font(.headline)
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack { Text("第 \(index + 1) 次"); Spacer(); Text(value).foregroundStyle(.secondary) }
                    .padding(12).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
