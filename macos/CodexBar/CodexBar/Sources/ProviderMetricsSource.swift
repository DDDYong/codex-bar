import Foundation

enum ProviderMetricsError: LocalizedError, Equatable {
    case credentialMissing(String)
    case unauthorized(String)
    case rateLimited(String)
    case unavailable(String)
    case invalidResponse(String)
    case unsafeEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .credentialMissing(let provider):
            "\(provider) API Key 未配置。"
        case .unauthorized(let provider):
            "\(provider) 凭据无效或权限不足。"
        case .rateLimited(let provider):
            "\(provider) 请求过于频繁，请稍后重试。"
        case .unavailable(let provider):
            "\(provider) 服务暂不可用，请稍后重试。"
        case .invalidResponse(let provider):
            "\(provider) 返回的数据格式异常。"
        case .unsafeEndpoint(let provider):
            "\(provider) 请求被安全策略拒绝。"
        }
    }
}

protocol ProviderMetricsSource: AnyObject {
    var providerID: ProviderID { get }
    var capabilities: ProviderCapabilities { get }
    var isConfigured: Bool { get }
    func fetchSnapshot() async throws -> ProviderFinancialSnapshot
}

protocol ProviderCredentialValidating: AnyObject {
    func validateCredential(kind: ProviderCredentialKind) async throws
}

struct FixedHostHTTPSPolicy: Equatable {
    let allowedHosts: Set<String>
    let maximumResponseBytes: Int

    init(allowedHosts: Set<String>, maximumResponseBytes: Int) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.maximumResponseBytes = maximumResponseBytes
    }

    func allows(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    func accepts(data: Data, response: URLResponse) -> Bool {
        data.count <= maximumResponseBytes && allows(response.url)
    }
}

final class FixedHostRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let policy: FixedHostHTTPSPolicy

    init(policy: FixedHostHTTPSPolicy) {
        self.policy = policy
    }

    func allowedRedirectRequest(_ request: URLRequest) -> URLRequest? {
        policy.allows(request.url) ? request : nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(allowedRedirectRequest(request))
    }
}

enum FixedHostURLSession {
    static func make(policy: FixedHostHTTPSPolicy) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = FixedHostRedirectGuard(policy: policy)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

struct ProviderAPIClient {
    let providerName: String
    let allowedHosts: Set<String>
    let session: URLSession
    let maximumResponseBytes: Int
    private let policy: FixedHostHTTPSPolicy

    init(
        providerName: String,
        allowedHosts: Set<String>,
        session: URLSession? = nil,
        maximumResponseBytes: Int = 64 * 1024
    ) {
        self.providerName = providerName
        let policy = FixedHostHTTPSPolicy(
            allowedHosts: allowedHosts,
            maximumResponseBytes: maximumResponseBytes
        )
        self.allowedHosts = policy.allowedHosts
        self.maximumResponseBytes = maximumResponseBytes
        self.policy = policy
        if let session {
            self.session = session
        } else {
            self.session = FixedHostURLSession.make(policy: policy)
        }
    }

    func get(_ url: URL, bearerToken: String) async throws -> Data {
        guard policy.allows(url) else {
            throw ProviderMetricsError.unsafeEndpoint(providerName)
        }
        guard !bearerToken.isEmpty else {
            throw ProviderMetricsError.credentialMissing(providerName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderMetricsError.unavailable(providerName)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderMetricsError.unavailable(providerName)
        }
        guard policy.accepts(data: data, response: httpResponse) else {
            throw ProviderMetricsError.invalidResponse(providerName)
        }
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw ProviderMetricsError.unauthorized(providerName)
        case 429:
            throw ProviderMetricsError.rateLimited(providerName)
        default:
            throw ProviderMetricsError.unavailable(providerName)
        }
        return data
    }
}

final class DeepSeekMetricsSource: ProviderMetricsSource, ProviderCredentialValidating {
    let providerID: ProviderID = .deepseek
    let capabilities: ProviderCapabilities = [.accountBalance, .usageCost, .tokenUsage]

    private let balanceSource: DeepSeekBalanceSource
    private let platformUsageSource: (any DeepSeekPlatformUsageReading)?
    private let platformUsageEnabled: () -> Bool
    private let configured: () -> Bool

    init(
        balanceSource: DeepSeekBalanceSource,
        platformUsageSource: (any DeepSeekPlatformUsageReading)? = nil,
        platformUsageEnabled: @escaping () -> Bool = { false },
        configured: @escaping () -> Bool
    ) {
        self.balanceSource = balanceSource
        self.platformUsageSource = platformUsageSource
        self.platformUsageEnabled = platformUsageEnabled
        self.configured = configured
    }

    var isConfigured: Bool { configured() }

    func validateCredential(kind: ProviderCredentialKind) async throws {
        guard kind == .apiKey else {
            throw ProviderMetricsError.credentialMissing(providerID.displayName)
        }
        _ = try await balanceSource.fetchBalance()
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot {
        let balance = try await balanceSource.fetchBalance()
        var spending: [SpendingSnapshot] = []
        var tokens: TokenUsageSnapshot?
        var dailyUsage: [ProviderDailyUsageSnapshot] = []
        var todayRequestCount: Int?
        var issues: [String] = []
        var source: MetricSource = .providerOfficialAPI
        var confidence: MetricConfidence = .verified
        var sourceVersion: String?
        var updatedAt = balance.updatedAt

        if platformUsageEnabled(), let platformUsageSource {
            do {
                let usage = try await platformUsageSource.fetchUsage(now: Date())
                if let todayCost = usage.todayCost {
                    spending.append(SpendingSnapshot(
                        amount: todayCost,
                        currency: usage.currency,
                        period: .today,
                        isProviderReported: true
                    ))
                }
                if let monthCost = usage.currentMonthCost {
                    spending.append(SpendingSnapshot(
                        amount: monthCost,
                        currency: usage.currency,
                        period: .month,
                        isProviderReported: true
                    ))
                }
                if let lifetimeCost = usage.lifetimeCost {
                    spending.append(SpendingSnapshot(
                        amount: lifetimeCost,
                        currency: usage.currency,
                        period: .lifetime,
                        isProviderReported: true
                    ))
                } else {
                    issues.append("历史累计正在后台补齐；今日与本月指标已更新")
                }
                tokens = TokenUsageSnapshot(
                    input: usage.todayInputTokens,
                    output: usage.todayOutputTokens,
                    cached: usage.todayCachedTokens,
                    reasoning: nil,
                    period: .today,
                    coverage: .account
                )
                dailyUsage = usage.dailyUsage.map {
                    ProviderDailyUsageSnapshot(
                        date: $0.date,
                        cost: $0.cost,
                        tokenCount: $0.tokenCount,
                        requestCount: $0.requestCount,
                        currency: usage.currency
                    )
                }
                todayRequestCount = usage.todayRequestCount
                source = .providerDashboard
                confidence = .reported
                sourceVersion = "v0"
                updatedAt = max(updatedAt, usage.updatedAt)
            } catch {
                issues.append("平台详细用量：\(error.localizedDescription)")
            }
        }

        return ProviderFinancialSnapshot(
            providerID: .deepseek,
            capabilities: capabilities,
            balance: MoneySnapshot(
                available: balance.totalBalance,
                toppedUp: balance.toppedUpBalance,
                granted: balance.grantedBalance,
                currency: balance.currency
            ),
            spending: spending,
            tokens: tokens,
            dailyUsage: dailyUsage,
            budget: nil,
            source: source,
            confidence: confidence,
            coverage: .account,
            updatedAt: updatedAt,
            sourceVersion: sourceVersion,
            issues: issues,
            todayRequestCount: todayRequestCount
        )
    }
}

final class OpenRouterMetricsSource: ProviderMetricsSource, ProviderCredentialValidating {
    let providerID: ProviderID = .openRouter
    let capabilities: ProviderCapabilities = [.accountBalance, .usageCost, .requestBudget]

    private let credentialStore: ProviderCredentialStoring
    private let client: ProviderAPIClient
    private let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    private let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    init(credentialStore: ProviderCredentialStoring, session: URLSession? = nil) {
        self.credentialStore = credentialStore
        self.client = ProviderAPIClient(
            providerName: ProviderID.openRouter.displayName,
            allowedHosts: ["openrouter.ai"],
            session: session
        )
    }

    var isConfigured: Bool {
        credentialStore.contains(providerID: providerID, kind: .managementKey)
            || credentialStore.contains(providerID: providerID, kind: .apiKey)
    }

    func validateCredential(kind: ProviderCredentialKind) async throws {
        switch kind {
        case .managementKey:
            let credential = try credentialStore.read(providerID: providerID, kind: kind)
            let data = try await client.get(creditsURL, bearerToken: credential)
            _ = try Self.parseSnapshot(creditsData: data, keyData: nil)
        case .apiKey:
            let credential = try credentialStore.read(providerID: providerID, kind: kind)
            let data = try await client.get(keyURL, bearerToken: credential)
            _ = try Self.parseSnapshot(creditsData: nil, keyData: data)
        }
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot {
        var creditsData: Data?
        var keyData: Data?
        var issues: [String] = []
        var firstError: Error?

        if credentialStore.contains(providerID: providerID, kind: .managementKey) {
            do {
                let credential = try credentialStore.read(providerID: providerID, kind: .managementKey)
                creditsData = try await client.get(creditsURL, bearerToken: credential)
            } catch {
                firstError = error
                issues.append("账户 credits 暂不可用")
            }
        }

        if credentialStore.contains(providerID: providerID, kind: .apiKey) {
            do {
                let credential = try credentialStore.read(providerID: providerID, kind: .apiKey)
                keyData = try await client.get(keyURL, bearerToken: credential)
            } catch {
                if firstError == nil { firstError = error }
                issues.append("当前 Key 用量暂不可用")
            }
        }

        guard creditsData != nil || keyData != nil else {
            if let firstError { throw firstError }
            throw ProviderMetricsError.credentialMissing(providerID.displayName)
        }

        var snapshot = try Self.parseSnapshot(creditsData: creditsData, keyData: keyData)
        if !issues.isEmpty {
            snapshot = ProviderFinancialSnapshot(
                providerID: snapshot.providerID,
                capabilities: snapshot.capabilities,
                balance: snapshot.balance,
                spending: snapshot.spending,
                tokens: snapshot.tokens,
                budget: snapshot.budget,
                source: snapshot.source,
                confidence: snapshot.confidence,
                coverage: snapshot.coverage,
                updatedAt: snapshot.updatedAt,
                issues: issues
            )
        }
        return snapshot
    }

    static func parseSnapshot(
        creditsData: Data?,
        keyData: Data?,
        updatedAt: Date = Date()
    ) throws -> ProviderFinancialSnapshot {
        guard creditsData != nil || keyData != nil else {
            throw ProviderMetricsError.invalidResponse(ProviderID.openRouter.displayName)
        }

        let credits: OpenRouterCreditsResponse.DataValue?
        let key: OpenRouterKeyResponse.DataValue?
        do {
            credits = try creditsData.map { try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: $0).data }
            key = try keyData.map { try JSONDecoder().decode(OpenRouterKeyResponse.self, from: $0).data }
        } catch {
            throw ProviderMetricsError.invalidResponse(ProviderID.openRouter.displayName)
        }

        let monetaryValues = [
            credits?.totalCredits,
            credits?.totalUsage,
            key?.limit,
            key?.limitRemaining,
            key?.usage,
            key?.usageDaily,
            key?.usageWeekly,
            key?.usageMonthly
        ].compactMap { $0 }
        guard monetaryValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ProviderMetricsError.invalidResponse(ProviderID.openRouter.displayName)
        }

        let balance = credits.map {
            MoneySnapshot(
                available: max(0, $0.totalCredits - $0.totalUsage),
                purchased: $0.totalCredits,
                currency: "USD"
            )
        }
        var spending: [SpendingSnapshot] = []
        if let lifetime = credits?.totalUsage ?? key?.usage {
            spending.append(SpendingSnapshot(amount: lifetime, currency: "USD", period: .lifetime, isProviderReported: true))
        }
        if let amount = key?.usageDaily {
            spending.append(SpendingSnapshot(amount: amount, currency: "USD", period: .today, isProviderReported: true))
        }
        if let amount = key?.usageWeekly {
            spending.append(SpendingSnapshot(amount: amount, currency: "USD", period: .week, isProviderReported: true))
        }
        if let amount = key?.usageMonthly {
            spending.append(SpendingSnapshot(amount: amount, currency: "USD", period: .month, isProviderReported: true))
        }

        let budget: BudgetSnapshot?
        if let limit = key?.limit, let remaining = key?.limitRemaining {
            budget = BudgetSnapshot(
                limit: limit,
                remaining: remaining,
                currency: "USD",
                resetPeriod: BudgetResetPeriod(rawValue: key?.limitReset ?? "") ?? .none
            )
        } else {
            budget = nil
        }

        let coverage: MetricCoverage = credits != nil && key != nil
            ? .accountAndAPIKey
            : (credits != nil ? .account : .apiKey)
        return ProviderFinancialSnapshot(
            providerID: .openRouter,
            capabilities: ProviderID.openRouter.capabilities,
            balance: balance,
            spending: spending,
            tokens: nil,
            budget: budget,
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: coverage,
            updatedAt: updatedAt
        )
    }
}

private struct OpenRouterCreditsResponse: Decodable {
    let data: DataValue

    struct DataValue: Decodable {
        let totalCredits: Double
        let totalUsage: Double

        private enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }
    }
}

private struct OpenRouterKeyResponse: Decodable {
    let data: DataValue

    struct DataValue: Decodable {
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: String?
        let usage: Double?
        let usageDaily: Double?
        let usageWeekly: Double?
        let usageMonthly: Double?

        private enum CodingKeys: String, CodingKey {
            case limit
            case limitRemaining = "limit_remaining"
            case limitReset = "limit_reset"
            case usage
            case usageDaily = "usage_daily"
            case usageWeekly = "usage_weekly"
            case usageMonthly = "usage_monthly"
        }
    }
}

final class SiliconFlowMetricsSource: ProviderMetricsSource, ProviderCredentialValidating {
    let providerID: ProviderID = .siliconFlow
    let capabilities: ProviderCapabilities = [.accountBalance]

    private let credentialStore: ProviderCredentialStoring
    private let client: ProviderAPIClient
    private let userInfoURL = URL(string: "https://api.siliconflow.cn/v1/user/info")!

    init(credentialStore: ProviderCredentialStoring, session: URLSession? = nil) {
        self.credentialStore = credentialStore
        self.client = ProviderAPIClient(
            providerName: ProviderID.siliconFlow.displayName,
            allowedHosts: ["api.siliconflow.cn"],
            session: session
        )
    }

    var isConfigured: Bool {
        credentialStore.contains(providerID: providerID, kind: .apiKey)
    }

    func validateCredential(kind: ProviderCredentialKind) async throws {
        guard kind == .apiKey else {
            throw ProviderMetricsError.credentialMissing(providerID.displayName)
        }
        _ = try await fetchSnapshot()
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot {
        guard isConfigured else {
            throw ProviderMetricsError.credentialMissing(providerID.displayName)
        }
        let credential = try credentialStore.read(providerID: providerID, kind: .apiKey)
        let data = try await client.get(userInfoURL, bearerToken: credential)
        return try Self.parseSnapshot(from: data)
    }

    static func parseSnapshot(from data: Data, updatedAt: Date = Date()) throws -> ProviderFinancialSnapshot {
        let response: SiliconFlowUserInfoResponse
        do {
            response = try JSONDecoder().decode(SiliconFlowUserInfoResponse.self, from: data)
        } catch {
            throw ProviderMetricsError.invalidResponse(ProviderID.siliconFlow.displayName)
        }
        guard response.status,
              response.code == 20_000,
              let available = Double(response.data.balance),
              available.isFinite,
              available >= 0 else {
            throw ProviderMetricsError.invalidResponse(ProviderID.siliconFlow.displayName)
        }
        return ProviderFinancialSnapshot(
            providerID: .siliconFlow,
            capabilities: ProviderID.siliconFlow.capabilities,
            balance: MoneySnapshot(available: available, currency: "CNY"),
            spending: [],
            tokens: nil,
            budget: nil,
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .account,
            updatedAt: updatedAt
        )
    }
}

private struct SiliconFlowUserInfoResponse: Decodable {
    let code: Int
    let status: Bool
    let data: DataValue

    struct DataValue: Decodable {
        let balance: String
    }
}

enum MiniMaxCLIError: LocalizedError, Equatable {
    case unavailable
    case timedOut
    case commandFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "MiniMax 官方 mmx CLI 未安装或不可执行。"
        case .timedOut: "MiniMax 配额查询超时。"
        case .commandFailed: "MiniMax 配额查询失败，请确认 mmx 已登录且 Token Plan 有效。"
        case .invalidResponse: "MiniMax CLI 返回的数据格式与当前版本不兼容。"
        }
    }
}

private struct LocalCommandResult {
    let status: Int32
    let standardOutput: Data
}

private protocol LocalCommandRunning: AnyObject {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) throws -> LocalCommandResult
}

private final class LocalCommandRunner: LocalCommandRunning {
    private let maximumOutputBytes = 256 * 1024

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) throws -> LocalCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var didTimeOut = false
        let timeoutItem = DispatchWorkItem {
            lock.lock()
            didTimeOut = true
            lock.unlock()
            if process.isRunning { process.terminate() }
        }
        do {
            try process.run()
        } catch {
            throw MiniMaxCLIError.unavailable
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()

        lock.lock()
        let timedOut = didTimeOut
        lock.unlock()
        if timedOut { throw MiniMaxCLIError.timedOut }
        guard data.count <= maximumOutputBytes else { throw MiniMaxCLIError.invalidResponse }
        return LocalCommandResult(status: process.terminationStatus, standardOutput: data)
    }
}

final class MiniMaxCLIMetricsSource: ProviderMetricsSource {
    let providerID: ProviderID = .miniMax
    let capabilities: ProviderCapabilities = ProviderID.miniMax.capabilities

    private let executableURL: URL
    private let runner: any LocalCommandRunning

    private init(executableURL: URL, runner: any LocalCommandRunning = LocalCommandRunner()) {
        self.executableURL = executableURL
        self.runner = runner
    }

    var isConfigured: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    static func locate(fileManager: FileManager = .default) -> MiniMaxCLIMetricsSource? {
        let candidates = [
            "/opt/homebrew/bin/mmx",
            "/usr/local/bin/mmx"
        ]
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else { return nil }
        return MiniMaxCLIMetricsSource(executableURL: URL(fileURLWithPath: path))
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot {
        guard isConfigured else { throw MiniMaxCLIError.unavailable }
        let executableURL = executableURL
        let runner = runner
        return try await Task.detached(priority: .utility) {
            let versionResult = try runner.run(executableURL: executableURL, arguments: ["--version"], timeout: 5)
            guard versionResult.status == 0,
                  let versionText = String(data: versionResult.standardOutput, encoding: .utf8),
                  let version = Self.version(from: versionText) else {
                throw MiniMaxCLIError.invalidResponse
            }
            let quotaResult = try runner.run(
                executableURL: executableURL,
                arguments: ["quota", "show", "--output", "json"],
                timeout: 10
            )
            guard quotaResult.status == 0 else { throw MiniMaxCLIError.commandFailed }
            return try Self.parseSnapshot(from: quotaResult.standardOutput, version: version)
        }.value
    }

    static func parseSnapshot(
        from data: Data,
        version: String,
        updatedAt: Date = Date()
    ) throws -> ProviderFinancialSnapshot {
        let response: MiniMaxQuotaResponse
        do {
            response = try JSONDecoder().decode(MiniMaxQuotaResponse.self, from: data)
        } catch {
            throw MiniMaxCLIError.invalidResponse
        }

        var quotaWindows: [QuotaWindowSnapshot] = []
        for model in response.modelRemains {
            if let window = quotaWindow(
                name: "\(model.modelName) · 5 小时",
                total: model.currentIntervalTotalCount,
                used: model.currentIntervalUsageCount,
                reportedRemainingPercent: model.currentIntervalRemainingPercent,
                resetMilliseconds: model.endTime
            ) {
                quotaWindows.append(window)
            }
            if let window = quotaWindow(
                name: "\(model.modelName) · 本周",
                total: model.currentWeeklyTotalCount,
                used: model.currentWeeklyUsageCount,
                reportedRemainingPercent: model.currentWeeklyRemainingPercent,
                resetMilliseconds: model.weeklyEndTime
            ) {
                quotaWindows.append(window)
            }
        }
        guard !quotaWindows.isEmpty else { throw MiniMaxCLIError.invalidResponse }

        return ProviderFinancialSnapshot(
            providerID: .miniMax,
            capabilities: ProviderID.miniMax.capabilities,
            balance: nil,
            spending: [],
            tokens: nil,
            budget: nil,
            quotaWindows: quotaWindows,
            source: .localCLI,
            confidence: .experimental,
            coverage: .apiKey,
            updatedAt: updatedAt,
            sourceVersion: version
        )
    }

    private static func quotaWindow(
        name: String,
        total: Int?,
        used: Int?,
        reportedRemainingPercent: Double?,
        resetMilliseconds: Double?
    ) -> QuotaWindowSnapshot? {
        guard let total, let used, total > 0, used >= 0, used <= total else { return nil }
        let calculatedPercent = Double(total - used) / Double(total) * 100
        let remainingPercent = reportedRemainingPercent ?? calculatedPercent
        guard remainingPercent.isFinite, (0...1_000).contains(remainingPercent) else { return nil }
        let resetsAt = resetMilliseconds.flatMap { value -> Date? in
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        }
        return QuotaWindowSnapshot(
            name: name,
            remainingPercent: remainingPercent,
            usedCount: used,
            totalCount: total,
            resetsAt: resetsAt
        )
    }

    private static func version(from text: String) -> String? {
        let expression = try? NSRegularExpression(pattern: #"\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression?.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

private struct MiniMaxQuotaResponse: Decodable {
    let modelRemains: [ModelRemain]

    private enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
    }

    struct ModelRemain: Decodable {
        let modelName: String
        let endTime: Double?
        let currentIntervalTotalCount: Int?
        let currentIntervalUsageCount: Int?
        let currentIntervalRemainingPercent: Double?
        let currentWeeklyTotalCount: Int?
        let currentWeeklyUsageCount: Int?
        let currentWeeklyRemainingPercent: Double?
        let weeklyEndTime: Double?

        private enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case endTime = "end_time"
            case currentIntervalTotalCount = "current_interval_total_count"
            case currentIntervalUsageCount = "current_interval_usage_count"
            case currentIntervalRemainingPercent = "current_interval_remaining_percent"
            case currentWeeklyTotalCount = "current_weekly_total_count"
            case currentWeeklyUsageCount = "current_weekly_usage_count"
            case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
            case weeklyEndTime = "weekly_end_time"
        }
    }
}
