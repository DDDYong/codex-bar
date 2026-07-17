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
        case .dashboard: "原生仪表盘将在真实数据源接入后显示额度与摘要。"
        case .usage: "Usage 与 Reset 数据将在 N2 和 N4 阶段接入。"
        case .activity: "活动趋势与统计将在快照能力完成后显示。"
        case .sessions: "会话索引将在 N7 阶段以只读方式接入。"
        case .pluginsSkills: "插件和 Skills 元数据将在 N8 阶段以只读方式接入。"
        case .dataSources: "数据源状态将在相应读取能力接入后显示。"
        case .settings: "设置持久化和可操作选项将在 N6 阶段接入。"
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
