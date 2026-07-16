import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Codable {
    case detailed
    case compact
    case iconOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .detailed: "详细"
        case .compact: "简略"
        case .iconOnly: "仅图标"
        }
    }
}

enum MenuBarPresentation {
    static func title(for mode: MenuBarDisplayMode, snapshot: CodexUsageSnapshot?) -> String {
        let detailed = summary(snapshot)
        switch mode {
        case .detailed: return detailed
        case .compact: return detailed.components(separatedBy: " · ").first ?? "week --"
        case .iconOnly: return ""
        }
    }

    static func summary(_ snapshot: CodexUsageSnapshot?) -> String {
        guard let snapshot else { return "week -- · -- · --" }
        let percent = snapshot.weeklyWindow.map { String(format: "%.0f%%", $0.remainingPercent) } ?? "--"
        let reset = snapshot.weeklyWindow?.resetsAt.map(resetLabel) ?? "--"
        let credits = snapshot.resetCredits.availableCount.map { "\($0)次" } ?? "--"
        return "week \(percent) · \(reset) · \(credits)"
    }

    private static func resetLabel(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = fractional.date(from: value) ?? parser.date(from: value) else { return "--" }
        return weekdayLabel(for: date)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func weekdayLabel(for date: Date) -> String {
        let symbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return symbols[Calendar.current.component(.weekday, from: date) - 1]
    }

}
