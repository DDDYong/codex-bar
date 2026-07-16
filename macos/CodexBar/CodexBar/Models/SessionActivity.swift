import Foundation

enum SessionActivity: String, Equatable {
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
        case "task_complete", "message": return .completed
        case "reasoning", "agent_reasoning", "custom_tool_call", "function_call", "custom_tool_call_output", "function_call_output": return .running
        case "permission_request", "approval_request", "request_user_input": return .waiting
        case "error", "failure", "failed": return .failed
        default: return .unknown
        }
    }
}
