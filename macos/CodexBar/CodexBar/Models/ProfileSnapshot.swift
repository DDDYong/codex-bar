import Foundation

struct ProfileSnapshot: Codable, Equatable {
    let totalTokens: Int
    let peakDayTokens: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let importedAt: Date
    let sourceLabel: String
}

struct ProfileSnapshotDraft: Equatable {
    var totalTokens: Int?
    var peakDayTokens: Int?
    var currentStreakDays: Int?
    var longestStreakDays: Int?
}
