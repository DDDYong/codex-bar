import Foundation

struct ProfileSnapshot: Codable, Equatable {
    let totalTokens: Int
    let peakDayTokens: Int
    let longestTaskDurationSeconds: Int?
    let currentStreakDays: Int
    let longestStreakDays: Int
    let importedAt: Date
    let sourceLabel: String
    let dailyUsageBuckets: [TokenActivityDay]

    init(
        totalTokens: Int,
        peakDayTokens: Int,
        longestTaskDurationSeconds: Int?,
        currentStreakDays: Int,
        longestStreakDays: Int,
        importedAt: Date,
        sourceLabel: String,
        dailyUsageBuckets: [TokenActivityDay] = []
    ) {
        self.totalTokens = totalTokens
        self.peakDayTokens = peakDayTokens
        self.longestTaskDurationSeconds = longestTaskDurationSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.importedAt = importedAt
        self.sourceLabel = sourceLabel
        self.dailyUsageBuckets = dailyUsageBuckets
    }

    private enum CodingKeys: String, CodingKey {
        case totalTokens, peakDayTokens, longestTaskDurationSeconds, currentStreakDays, longestStreakDays, importedAt, sourceLabel, dailyUsageBuckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        peakDayTokens = try container.decode(Int.self, forKey: .peakDayTokens)
        longestTaskDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .longestTaskDurationSeconds)
        currentStreakDays = try container.decode(Int.self, forKey: .currentStreakDays)
        longestStreakDays = try container.decode(Int.self, forKey: .longestStreakDays)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        dailyUsageBuckets = try container.decodeIfPresent([TokenActivityDay].self, forKey: .dailyUsageBuckets) ?? []
    }
}

struct TokenActivityDay: Codable, Equatable, Identifiable {
    let startDate: String
    let tokens: Int

    var id: String { startDate }
}

struct ProfileSnapshotDraft: Equatable {
    var totalTokens: Int?
    var peakDayTokens: Int?
    var longestTaskDurationSeconds: Int? = nil
    var currentStreakDays: Int?
    var longestStreakDays: Int?

    var isReadyToSave: Bool {
        [totalTokens, peakDayTokens, currentStreakDays, longestStreakDays]
            .allSatisfy { $0.map { $0 >= 0 } ?? false }
    }
}
