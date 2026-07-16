import Foundation

struct PluginSkillEntry: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case plugin
        case skill
        case mcp

        var id: Self { self }
        var title: String {
            switch self {
            case .plugin: "插件"
            case .skill: "Skill"
            case .mcp: "MCP"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let detail: String?
    let path: String
}
