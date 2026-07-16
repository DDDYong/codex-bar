import Foundation

struct UsageSnapshotRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let weeklyRemainingPercent: Double
    let shortRemainingPercent: Double?
    let resetCredits: UInt64?

    init(snapshot: CodexUsageSnapshot) {
        id = UUID()
        capturedAt = snapshot.updatedAt
        weeklyRemainingPercent = snapshot.weeklyWindow?.remainingPercent ?? 0
        shortRemainingPercent = snapshot.shortWindow?.remainingPercent
        resetCredits = snapshot.resetCredits.availableCount
    }
}
