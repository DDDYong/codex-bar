import Foundation

struct CodexAccount: Equatable {
    let displayName: String?
    let email: String?
    let accountID: String?

    var initials: String {
        let source = displayName ?? email ?? "C"
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "C" : String(letters).uppercased()
    }
}

struct CodexDashboardData: Equatable {
    let snapshot: CodexUsageSnapshot
    let account: CodexAccount
}

struct CodexUsageWindow: Equatable {
    let remainingPercent: Double
    let resetsAt: String?
    let windowSeconds: UInt64
}

struct CodexResetCredits: Equatable {
    let availableCount: UInt64?
    let expiresAt: [String]
}

struct CodexUsageSnapshot: Equatable {
    let plan: String?
    let shortWindow: CodexUsageWindow?
    let weeklyWindow: CodexUsageWindow?
    let resetCredits: CodexResetCredits
    let updatedAt: Date
}
