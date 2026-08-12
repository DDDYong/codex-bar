import Foundation

enum ProviderType: Hashable, Codable {
    case officialCodex
    case deepseek
    case openRouter
    case siliconFlow
    case custom(String)

    var displayName: String {
        switch self {
        case .officialCodex: "ChatGPT 订阅"
        case .deepseek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .siliconFlow: "SiliconFlow"
        case .custom(let name): name
        }
    }

    var category: ProviderCategory {
        switch self {
        case .officialCodex: .official
        case .deepseek, .openRouter, .siliconFlow, .custom: .thirdParty
        }
    }

    var iconName: String {
        switch self {
        case .officialCodex: "openai"
        case .deepseek: "deepseek"
        case .openRouter: "openrouter"
        case .siliconFlow: "siliconflow"
        case .custom: "provider-generic"
        }
    }

    var isOfficial: Bool { self == .officialCodex }
    var isThirdParty: Bool { !isOfficial }

    private enum CodingKeys: String, CodingKey {
        case kind, customName
    }

    private enum Kind: String, Codable {
        case officialCodex, deepseek, openRouter, siliconFlow, custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .officialCodex: self = .officialCodex
        case .deepseek: self = .deepseek
        case .openRouter: self = .openRouter
        case .siliconFlow: self = .siliconFlow
        case .custom: self = .custom(try container.decode(String.self, forKey: .customName))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .officialCodex: try container.encode(Kind.officialCodex, forKey: .kind)
        case .deepseek: try container.encode(Kind.deepseek, forKey: .kind)
        case .openRouter: try container.encode(Kind.openRouter, forKey: .kind)
        case .siliconFlow: try container.encode(Kind.siliconFlow, forKey: .kind)
        case .custom(let name):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(name, forKey: .customName)
        }
    }
}

enum ProviderCategory: String, Codable {
    case official
    case thirdParty
}

struct ProviderConfig: Equatable, Codable {
    let type: ProviderType
    let baseURL: String?
    let name: String?

    var isOfficial: Bool { type.isOfficial }
    var isThirdParty: Bool { type.isThirdParty }
}

struct ProviderBalance: Equatable, Codable {
    let provider: String
    let totalBalance: Double
    let toppedUpBalance: Double
    let grantedBalance: Double
    let currency: String
    let updatedAt: Date

    var formattedTotal: String {
        String(format: "%.2f", totalBalance)
    }

    var formattedToppedUp: String {
        String(format: "%.2f", toppedUpBalance)
    }

    var formattedGranted: String {
        String(format: "%.2f", grantedBalance)
    }

    var currencySymbol: String {
        currency.uppercased() == "USD" ? "$" : "¥"
    }

    var isAvailable: Bool { totalBalance > 0 }
}

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

enum ResetCreditsCachePolicy {
    static let maximumAge: TimeInterval = 60 * 60
    private static let allowedClockSkew: TimeInterval = 5 * 60

    static func merged(
        fetched: CodexResetCredits,
        previous: CodexUsageSnapshot?,
        storedRecords: [UsageSnapshotRecord],
        now: Date
    ) -> CodexResetCredits {
        let fetchedValue = currentValue(fetched, now: now)
        let fetchedReportsNoCredits = fetched.availableCount == 0
        let cachedValues = ([previous].compactMap { $0 }.map { ($0.resetCredits, $0.updatedAt) }
            + storedRecords.reversed().map {
                (
                    CodexResetCredits(
                        availableCount: $0.resetCredits,
                        expiresAt: $0.resetCreditExpirations ?? []
                    ),
                    $0.capturedAt
                )
            })
            .compactMap { cachedValue($0.0, capturedAt: $0.1, now: now) }

        return CodexResetCredits(
            availableCount: fetchedValue.availableCount
                ?? cachedValues.lazy.compactMap(\.availableCount).first,
            expiresAt: fetchedReportsNoCredits
                ? []
                : fetchedValue.expiresAt.isEmpty
                ? cachedValues.lazy.map(\.expiresAt).first(where: { !$0.isEmpty }) ?? []
                : fetchedValue.expiresAt
        )
    }

    static func currentValue(_ value: CodexResetCredits, now: Date) -> CodexResetCredits {
        guard value.availableCount != 0 else {
            return CodexResetCredits(availableCount: 0, expiresAt: [])
        }
        let future = futureExpirations(value.expiresAt, now: now)
        let count = value.expiresAt.isEmpty || !future.isEmpty ? value.availableCount : nil
        return CodexResetCredits(
            availableCount: count,
            expiresAt: future
        )
    }

    static func cachedValue(
        _ value: CodexResetCredits,
        capturedAt: Date,
        now: Date
    ) -> CodexResetCredits? {
        let age = now.timeIntervalSince(capturedAt)
        guard age >= -allowedClockSkew, age <= maximumAge else { return nil }

        let current = currentValue(value, now: now)
        guard current.availableCount != nil || !current.expiresAt.isEmpty else { return nil }
        return current
    }

    static func isAvailable(
        _ value: CodexResetCredits,
        capturedAt: Date,
        now: Date
    ) -> Bool {
        cachedValue(value, capturedAt: capturedAt, now: now) != nil
    }

    private static func futureExpirations(_ values: [String], now: Date) -> [String] {
        values
            .compactMap { value -> (String, Date)? in
                guard let date = date(from: value), date > now else { return nil }
                return (value, date)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct CodexUsageSnapshot: Equatable {
    let plan: String?
    let shortWindow: CodexUsageWindow?
    let weeklyWindow: CodexUsageWindow?
    let resetCredits: CodexResetCredits
    let updatedAt: Date
    let providerType: ProviderType

    init(
        plan: String?,
        shortWindow: CodexUsageWindow?,
        weeklyWindow: CodexUsageWindow?,
        resetCredits: CodexResetCredits,
        updatedAt: Date,
        providerType: ProviderType = .officialCodex
    ) {
        self.plan = plan
        self.shortWindow = shortWindow
        self.weeklyWindow = weeklyWindow
        self.resetCredits = resetCredits
        self.updatedAt = updatedAt
        self.providerType = providerType
    }
}
