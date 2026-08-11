import Foundation

enum SessionActivity: String, Hashable {
    case running
    case waiting
    case completed
    case failed
    case unknown

    var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .waiting: "circle.fill"
        case .completed: "circle.fill"
        case .failed: "circle.fill"
        case .unknown: "circle.fill"
        }
    }

    var isConsuming: Bool { self == .running }

    var indicatorStyle: ActivityIndicatorStyle {
        switch self {
        case .running: .active
        case .waiting: .attention
        case .failed: .failure
        case .completed, .unknown: .idle
        }
    }

    static func aggregate(_ statuses: [SessionActivity]) -> SessionActivity {
        if statuses.contains(.running) { return .running }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.completed) { return .completed }
        return .unknown
    }

    static func from(eventTypes: [String]) -> SessionActivity {
        guard let last = eventTypes.last else { return .unknown }
        switch last {
        case "task_complete", "turn_aborted": return .completed
        case "task_started", "reasoning", "agent_reasoning", "message", "agent_message", "custom_tool_call", "function_call", "custom_tool_call_output", "function_call_output": return .running
        case "permission_request", "approval_request", "request_user_input": return .waiting
        case "error", "failure", "failed": return .failed
        default: return .unknown
        }
    }
}

enum ActivityIndicatorStyle: Equatable {
    case active
    case attention
    case failure
    case idle
}

struct ProviderActivitySnapshot: Equatable {
    private(set) var activities: [ProviderType: SessionActivity]

    init(activities: [ProviderType: SessionActivity]) {
        self.activities = activities
    }

    init(officialCodex: SessionActivity, deepSeek: SessionActivity) {
        self.activities = [
            .officialCodex: officialCodex,
            .deepseek: deepSeek
        ]
    }

    static let unknown = ProviderActivitySnapshot(activities: [:])

    var officialCodex: SessionActivity { activity(for: .officialCodex) }
    var deepSeek: SessionActivity { activity(for: .deepseek) }

    var aggregate: SessionActivity {
        SessionActivity.aggregate(Array(activities.values))
    }

    var isSimultaneouslyConsuming: Bool {
        activities.values.filter(\.isConsuming).count > 1
    }

    func activity(for providerType: ProviderType) -> SessionActivity {
        activities[providerType] ?? .unknown
    }
}
