import Foundation

struct ProviderUsageSnapshotRecord: Codable, Identifiable, Equatable {
    var id: ProviderID { providerID }

    let providerID: ProviderID
    let available: Double?
    let todaySpend: Double?
    let lifetimeSpend: Double?
    let todayTokens: Int?
    let currency: String?
    let updatedAt: Date?
    let source: MetricSource?
    let isStale: Bool

    init(snapshot: ProviderFinancialSnapshot, cycleStartedAt: Date? = nil) {
        providerID = snapshot.providerID
        available = snapshot.balance?.available
        todaySpend = snapshot.spending.first { $0.period == .today }?.amount
        lifetimeSpend = snapshot.spending.first { $0.period == .lifetime }?.amount
        todayTokens = snapshot.tokens.map { $0.input + $0.output }
        currency = snapshot.balance?.currency
            ?? snapshot.spending.first?.currency
        updatedAt = snapshot.updatedAt
        source = snapshot.source
        isStale = cycleStartedAt.map { snapshot.updatedAt < $0 } ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case available
        case todaySpend
        case lifetimeSpend
        case todayTokens
        case currency
        case updatedAt
        case source
        case isStale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        available = try container.decodeIfPresent(Double.self, forKey: .available)
        todaySpend = try container.decodeIfPresent(Double.self, forKey: .todaySpend)
        lifetimeSpend = try container.decodeIfPresent(Double.self, forKey: .lifetimeSpend)
        todayTokens = try container.decodeIfPresent(Int.self, forKey: .todayTokens)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        source = try container.decodeIfPresent(MetricSource.self, forKey: .source)
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? true
    }
}

struct UsageSnapshotRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let weeklyRemainingPercent: Double
    let shortRemainingPercent: Double?
    let resetCredits: UInt64?
    let resetCreditExpirations: [String]?
    let providerUsage: [ProviderUsageSnapshotRecord]?

    init(
        snapshot: CodexUsageSnapshot,
        providerSnapshots: [ProviderFinancialSnapshot] = [],
        cycleStartedAt: Date? = nil,
        capturedAt: Date? = nil
    ) {
        id = UUID()
        self.capturedAt = capturedAt ?? snapshot.updatedAt
        weeklyRemainingPercent = snapshot.weeklyWindow?.remainingPercent ?? 0
        shortRemainingPercent = snapshot.shortWindow?.remainingPercent
        resetCredits = snapshot.resetCredits.availableCount
        resetCreditExpirations = snapshot.resetCredits.expiresAt.isEmpty
            ? nil
            : snapshot.resetCredits.expiresAt
        providerUsage = providerSnapshots.map {
            ProviderUsageSnapshotRecord(snapshot: $0, cycleStartedAt: cycleStartedAt)
        }
    }
}
