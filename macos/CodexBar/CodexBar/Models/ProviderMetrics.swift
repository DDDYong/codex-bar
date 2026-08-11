import Foundation

enum ProviderID: String, CaseIterable, Codable, Hashable, Identifiable {
    case deepseek
    case openRouter = "openrouter"
    case siliconFlow = "siliconflow"
    case kimi
    case glm
    case miniMax = "minimax"
    case volcengine
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .siliconFlow: "SiliconFlow"
        case .kimi: "Kimi"
        case .glm: "GLM"
        case .miniMax: "MiniMax"
        case .volcengine: "火山方舟"
        case .qwen: "通义千问"
        }
    }

    var providerType: ProviderType {
        switch self {
        case .deepseek: .deepseek
        case .openRouter: .openRouter
        case .siliconFlow: .siliconFlow
        case .kimi: .custom("Kimi")
        case .glm: .custom("GLM")
        case .miniMax: .custom("MiniMax")
        case .volcengine: .custom("火山方舟")
        case .qwen: .custom("通义千问")
        }
    }

    var capabilities: ProviderCapabilities {
        switch self {
        case .siliconFlow:
            [.accountBalance]
        case .deepseek:
            [.accountBalance, .usageCost, .tokenUsage]
        case .openRouter:
            [.accountBalance, .usageCost, .requestBudget]
        case .kimi, .glm, .volcengine, .qwen:
            [.usageCost, .tokenUsage]
        case .miniMax:
            [.subscriptionQuota, .usageCost, .tokenUsage]
        }
    }

    var credentialKinds: [ProviderCredentialKind] {
        switch self {
        case .deepseek, .siliconFlow: [.apiKey]
        case .openRouter: [.managementKey, .apiKey]
        case .kimi, .glm, .miniMax, .volcengine, .qwen: []
        }
    }

    var sourceDescription: String {
        switch self {
        case .deepseek:
            "官方余额 + 可选 DeepSeek 平台今日与历史累计用量"
        case .openRouter:
            "官方 /credits + /key：账户 credits、Key 预算与周期消费"
        case .siliconFlow:
            "官方 /v1/user/info：账户可用余额"
        case .kimi, .glm, .volcengine, .qwen:
            "实验：只读 cc-switch 已有代理日志，不接管 Provider 路由"
        case .miniMax:
            "实验：官方 mmx CLI 配额（如已安装登录）+ 只读代理日志"
        }
    }

    var dataSourceName: String {
        switch self {
        case .deepseek: "DeepSeek 余额"
        case .openRouter: "OpenRouter 余额与用量"
        case .siliconFlow: "SiliconFlow 余额"
        case .kimi: "Kimi 实验指标"
        case .glm: "GLM 实验指标"
        case .miniMax: "MiniMax 实验指标"
        case .volcengine: "火山方舟实验指标"
        case .qwen: "通义千问实验指标"
        }
    }

    var isExperimental: Bool {
        switch self {
        case .kimi, .glm, .miniMax, .volcengine, .qwen: true
        case .deepseek, .openRouter, .siliconFlow: false
        }
    }

    static func fromCCSwitch(name: String, providerType: String?) -> ProviderID? {
        let marker = "\(name) \(providerType ?? "")".lowercased()
        if marker.contains("openai") { return nil }
        if marker.contains("deepseek") { return .deepseek }
        if marker.contains("openrouter") || marker.contains("open router") { return .openRouter }
        if marker.contains("siliconflow") || marker.contains("silicon flow") { return .siliconFlow }
        if marker.contains("minimax") { return .miniMax }
        if marker.contains("moonshot") || marker.contains("kimi") { return .kimi }
        if marker.contains("bigmodel") || marker.contains("zhipu") || marker.contains("glm") || marker.contains("智谱") { return .glm }
        if marker.contains("volc") || marker.contains("ark") || marker.contains("火山") || marker.contains("方舟") { return .volcengine }
        if marker.contains("dashscope") || marker.contains("qwen") || marker.contains("千问") || marker.contains("通义") { return .qwen }
        return nil
    }
}

enum ProviderCredentialKind: String, Codable, Hashable, Identifiable {
    case apiKey = "api-key"
    case managementKey = "management-key"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiKey: "API Key"
        case .managementKey: "Management Key"
        }
    }

    func helpText(for providerID: ProviderID) -> String {
        switch (providerID, self) {
        case (.openRouter, .managementKey):
            "用于读取账户购买 credits 与累计使用，不用于模型推理。"
        case (.openRouter, .apiKey):
            "用于读取当前推理 Key 的预算及日、周、月消费。"
        default:
            "仅用于查询该 Provider 的只读余额或用量接口。"
        }
    }
}

struct ProviderCapabilities: OptionSet, Codable, Equatable, Hashable {
    let rawValue: Int

    static let accountBalance = ProviderCapabilities(rawValue: 1 << 0)
    static let subscriptionQuota = ProviderCapabilities(rawValue: 1 << 1)
    static let usageCost = ProviderCapabilities(rawValue: 1 << 2)
    static let tokenUsage = ProviderCapabilities(rawValue: 1 << 3)
    static let requestBudget = ProviderCapabilities(rawValue: 1 << 4)
}

enum MetricSource: String, Codable, Equatable {
    case providerOfficialAPI
    case providerDashboard
    case providerResponse
    case localProxy
    case localEstimate
    case experimentalScrape
    case localCLI

    var displayName: String {
        switch self {
        case .providerOfficialAPI: "官方 API"
        case .providerDashboard: "Provider 平台"
        case .providerResponse: "请求响应"
        case .localProxy: "本地代理"
        case .localEstimate: "本地估算"
        case .experimentalScrape: "实验抓取"
        case .localCLI: "本地 CLI"
        }
    }
}

enum MetricConfidence: String, Codable, Equatable {
    case verified
    case reported
    case estimated
    case experimental

    var displayName: String {
        switch self {
        case .verified: "已核验"
        case .reported: "Provider 报告"
        case .estimated: "估算"
        case .experimental: "实验"
        }
    }
}

enum MetricCoverage: String, Codable, Equatable {
    case account
    case apiKey
    case accountAndAPIKey
    case proxiedRequests
    case localEstimate

    var displayName: String {
        switch self {
        case .account: "账户"
        case .apiKey: "当前 API Key"
        case .accountAndAPIKey: "账户 + 当前 API Key"
        case .proxiedRequests: "仅代理请求"
        case .localEstimate: "本地估算"
        }
    }
}

enum SpendingPeriod: String, Codable, Equatable, CaseIterable {
    case today
    case week
    case month
    case lifetime
    case custom

    var displayName: String {
        switch self {
        case .today: "今日"
        case .week: "本周"
        case .month: "本月"
        case .lifetime: "累计"
        case .custom: "自定义"
        }
    }
}

enum BudgetResetPeriod: String, Codable, Equatable {
    case daily
    case weekly
    case monthly
    case none

    var displayName: String {
        switch self {
        case .daily: "每日"
        case .weekly: "每周"
        case .monthly: "每月"
        case .none: "不重置"
        }
    }
}

struct MoneySnapshot: Codable, Equatable {
    let available: Double
    let toppedUp: Double?
    let granted: Double?
    let purchased: Double?
    let currency: String

    init(
        available: Double,
        toppedUp: Double? = nil,
        granted: Double? = nil,
        purchased: Double? = nil,
        currency: String
    ) {
        self.available = available
        self.toppedUp = toppedUp
        self.granted = granted
        self.purchased = purchased
        self.currency = currency
    }

    var currencySymbol: String {
        switch currency.uppercased() {
        case "USD": "$"
        case "EUR": "€"
        default: "¥"
        }
    }

    func formatted(_ amount: Double) -> String {
        "\(currencySymbol)\(String(format: "%.2f", amount))"
    }
}

struct SpendingSnapshot: Codable, Equatable {
    let amount: Double
    let currency: String
    let period: SpendingPeriod
    let isProviderReported: Bool
}

struct TokenUsageSnapshot: Codable, Equatable {
    let input: Int
    let output: Int
    let cached: Int?
    let reasoning: Int?
    let period: SpendingPeriod
    let coverage: MetricCoverage
}

struct ProviderDailyUsageSnapshot: Codable, Equatable, Identifiable {
    var id: String { date }

    let date: String
    let cost: Double?
    let tokenCount: Int
    let requestCount: Int
    let currency: String
}

struct BudgetSnapshot: Codable, Equatable {
    let limit: Double
    let remaining: Double
    let currency: String
    let resetPeriod: BudgetResetPeriod
}

struct QuotaWindowSnapshot: Codable, Equatable {
    let name: String
    let remainingPercent: Double
    let usedCount: Int?
    let totalCount: Int?
    let resetsAt: Date?
}

struct ProviderFinancialSnapshot: Codable, Equatable, Identifiable {
    var id: ProviderID { providerID }

    let providerID: ProviderID
    let capabilities: ProviderCapabilities
    let balance: MoneySnapshot?
    let spending: [SpendingSnapshot]
    let tokens: TokenUsageSnapshot?
    let dailyUsage: [ProviderDailyUsageSnapshot]
    let budget: BudgetSnapshot?
    let quotaWindows: [QuotaWindowSnapshot]
    let source: MetricSource
    let confidence: MetricConfidence
    let coverage: MetricCoverage
    let updatedAt: Date
    let sourceVersion: String?
    let issues: [String]
    let todayRequestCount: Int?

    init(
        providerID: ProviderID,
        capabilities: ProviderCapabilities,
        balance: MoneySnapshot?,
        spending: [SpendingSnapshot],
        tokens: TokenUsageSnapshot?,
        dailyUsage: [ProviderDailyUsageSnapshot] = [],
        budget: BudgetSnapshot?,
        quotaWindows: [QuotaWindowSnapshot] = [],
        source: MetricSource,
        confidence: MetricConfidence,
        coverage: MetricCoverage,
        updatedAt: Date,
        sourceVersion: String? = nil,
        issues: [String] = [],
        todayRequestCount: Int? = nil
    ) {
        self.providerID = providerID
        self.capabilities = capabilities
        self.balance = balance
        self.spending = spending
        self.tokens = tokens
        self.dailyUsage = dailyUsage
        self.budget = budget
        self.quotaWindows = quotaWindows
        self.source = source
        self.confidence = confidence
        self.coverage = coverage
        self.updatedAt = updatedAt
        self.sourceVersion = sourceVersion
        self.issues = issues
        self.todayRequestCount = todayRequestCount
    }

    var legacyProviderBalance: ProviderBalance? {
        guard providerID == .deepseek, let balance else { return nil }
        return ProviderBalance(
            provider: providerID.rawValue,
            totalBalance: balance.available,
            toppedUpBalance: balance.toppedUp ?? 0,
            grantedBalance: balance.granted ?? 0,
            currency: balance.currency,
            updatedAt: updatedAt
        )
    }
}

enum ProviderConnectionState: Equatable {
    case idle
    case testing
    case succeeded(String)
    case failed(String)
}
