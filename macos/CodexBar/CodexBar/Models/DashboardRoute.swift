import SwiftUI

enum DashboardRoute: String, CaseIterable, Identifiable {
    case dashboard
    case usage
    case activity
    case sessions
    case pluginsSkills
    case dataSources
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .usage: "额度与 Reset"
        case .activity: "活动统计"
        case .sessions: "Codex 会话"
        case .pluginsSkills: "插件与 Skills"
        case .dataSources: "数据源"
        case .settings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "汇总 ChatGPT 与已启用 Provider 的当前状态。"
        case .usage: "在同一页面独立展示 ChatGPT 与第三方 Provider 指标、Reset 和本地快照。"
        case .activity: "展示 Codex app-server 汇总的 Token 活动与趋势。"
        case .sessions: "索引本机会话，并提供受保护的归档与删除操作。"
        case .pluginsSkills: "展示本机插件、Skills 与 MCP 配置元数据。"
        case .dataSources: "展示各数据源的可用状态、范围与最近错误。"
        case .settings: "管理外观、本地数据、Provider 凭据与启动选项。"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .usage: "gauge.with.dots.needle.67percent"
        case .activity: "chart.line.uptrend.xyaxis"
        case .sessions: "rectangle.stack"
        case .pluginsSkills: "puzzlepiece.extension"
        case .dataSources: "externaldrive"
        case .settings: "gearshape"
        }
    }
}
