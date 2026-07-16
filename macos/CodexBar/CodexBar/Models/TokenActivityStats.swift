import Foundation

struct TokenActivityDay: Identifiable, Equatable {
    let date: Date
    let totalTokens: Int

    var id: Date { date }
}

struct TokenActivityStats: Equatable {
    let totalTokens: Int
    let peakTokens: Int
    let longestSessionDuration: TimeInterval
    let currentStreakDays: Int
    let longestStreakDays: Int
    let daily: [TokenActivityDay]
    let activeDays: [Date]

    static let empty = TokenActivityStats(
        totalTokens: 0,
        peakTokens: 0,
        longestSessionDuration: 0,
        currentStreakDays: 0,
        longestStreakDays: 0,
        daily: [],
        activeDays: []
    )
}
