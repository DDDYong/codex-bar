import CryptoKit
import Foundation
import SweetCookieKit

struct DeepSeekDailyUsage: Equatable {
    let date: String
    let cost: Double?
    let tokenCount: Int
    let requestCount: Int
}

struct DeepSeekPlatformUsage: Equatable {
    let todayInputTokens: Int
    let todayOutputTokens: Int
    let todayCachedTokens: Int
    let todayRequestCount: Int
    let currentMonthTokens: Int
    let currentMonthRequestCount: Int
    let todayCost: Double?
    let currentMonthCost: Double?
    let lifetimeCost: Double?
    let currency: String
    let updatedAt: Date
    let dailyUsage: [DeepSeekDailyUsage]

    init(
        todayInputTokens: Int,
        todayOutputTokens: Int,
        todayCachedTokens: Int,
        todayRequestCount: Int,
        currentMonthTokens: Int,
        currentMonthRequestCount: Int,
        todayCost: Double?,
        currentMonthCost: Double?,
        lifetimeCost: Double?,
        currency: String,
        updatedAt: Date,
        dailyUsage: [DeepSeekDailyUsage] = []
    ) {
        self.todayInputTokens = todayInputTokens
        self.todayOutputTokens = todayOutputTokens
        self.todayCachedTokens = todayCachedTokens
        self.todayRequestCount = todayRequestCount
        self.currentMonthTokens = currentMonthTokens
        self.currentMonthRequestCount = currentMonthRequestCount
        self.todayCost = todayCost
        self.currentMonthCost = currentMonthCost
        self.lifetimeCost = lifetimeCost
        self.currency = currency
        self.updatedAt = updatedAt
        self.dailyUsage = dailyUsage
    }
}

enum DeepSeekPlatformUsageError: LocalizedError, Equatable {
    case sessionMissing
    case sessionExpired
    case apiRejected(Int)
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .sessionMissing:
            "未在 Chrome 中找到 DeepSeek 平台登录态，请先登录 platform.deepseek.com。"
        case .sessionExpired:
            "Chrome 中的 DeepSeek 平台登录态已失效，请重新登录。"
        case .apiRejected(let code):
            "DeepSeek 平台接口返回错误码 \(code)。"
        case .invalidResponse:
            "DeepSeek 平台用量数据格式异常。"
        case .unavailable:
            "DeepSeek 平台用量暂不可用。"
        }
    }
}

protocol DeepSeekPlatformUsageReading: AnyObject {
    func fetchUsage(now: Date) async throws -> DeepSeekPlatformUsage
}

enum DeepSeekPlatformUsageParser {
    private struct Envelope<Value: Decodable>: Decodable {
        let data: DataEnvelope<Value>?
    }

    private struct DataEnvelope<Value: Decodable>: Decodable {
        let bizData: Value?

        private enum CodingKeys: String, CodingKey {
            case bizData = "biz_data"
        }
    }

    private struct UsageBucket: Decodable {
        let total: [ModelUsage]?
        let days: [DayUsage]?
        let currency: String?
    }

    private struct DayUsage: Decodable {
        let date: String?
        let data: [ModelUsage]?
    }

    private struct ModelUsage: Decodable {
        let model: String?
        let usage: [UsageItem]?
    }

    private struct UsageItem: Decodable {
        let type: String?
        let amount: String?
    }

    private enum Category: String {
        case cacheHit = "PROMPT_CACHE_HIT_TOKEN"
        case cacheMiss = "PROMPT_CACHE_MISS_TOKEN"
        case response = "RESPONSE_TOKEN"
        case request = "REQUEST"
    }

    private struct TokenTotals {
        var input = 0
        var output = 0
        var cached = 0
        var requests = 0

        var tokens: Int { input + output }

        mutating func add(_ other: TokenTotals) {
            input += other.input
            output += other.output
            cached += other.cached
            requests += other.requests
        }
    }

    static func parse(
        amountData: Data,
        costData: Data,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DeepSeekPlatformUsage {
        try validateEnvelope(amountData)
        try validateEnvelope(costData)

        let amountBucket: UsageBucket
        let costBucket: UsageBucket
        do {
            guard let decodedAmount = try JSONDecoder()
                .decode(Envelope<UsageBucket>.self, from: amountData)
                .data?.bizData,
                  let decodedCost = try JSONDecoder()
                .decode(Envelope<[UsageBucket]>.self, from: costData)
                .data?.bizData?.first else {
                throw DeepSeekPlatformUsageError.invalidResponse
            }
            amountBucket = decodedAmount
            costBucket = decodedCost
        } catch let error as DeepSeekPlatformUsageError {
            throw error
        } catch {
            throw DeepSeekPlatformUsageError.invalidResponse
        }

        let today = dayString(now, calendar: calendar)
        var todayTokens = TokenTotals()
        var monthTokens = TokenTotals()
        var todayCost: Double?
        var monthCost: Double?
        var dailyTokens: [String: TokenTotals] = [:]
        var dailyCosts: [String: Double] = [:]

        for day in amountBucket.days ?? [] {
            guard let date = day.date, isCurrentMonth(date, now: now, calendar: calendar) else { continue }
            let totals = try tokenTotals(in: day.data ?? [])
            dailyTokens[date] = totals
            monthTokens.add(totals)
            if date == today { todayTokens.add(totals) }
        }

        for day in costBucket.days ?? [] {
            guard let date = day.date, isCurrentMonth(date, now: now, calendar: calendar) else { continue }
            let cost = try monetaryTotal(in: day.data ?? [])
            if cost.hasReportedValue {
                dailyCosts[date] = cost.amount
                monthCost = (monthCost ?? 0) + cost.amount
                if date == today { todayCost = (todayCost ?? 0) + cost.amount }
            }
        }

        let dailyUsage = Set(dailyTokens.keys).union(dailyCosts.keys).sorted().map { date in
            let tokens = dailyTokens[date] ?? TokenTotals()
            return DeepSeekDailyUsage(
                date: date,
                cost: dailyCosts[date],
                tokenCount: tokens.tokens,
                requestCount: tokens.requests
            )
        }

        return DeepSeekPlatformUsage(
            todayInputTokens: todayTokens.input,
            todayOutputTokens: todayTokens.output,
            todayCachedTokens: todayTokens.cached,
            todayRequestCount: todayTokens.requests,
            currentMonthTokens: monthTokens.tokens,
            currentMonthRequestCount: monthTokens.requests,
            todayCost: todayCost,
            currentMonthCost: monthCost,
            lifetimeCost: nil,
            currency: costBucket.currency ?? "CNY",
            updatedAt: now,
            dailyUsage: dailyUsage
        )
    }

    static func parseMonthCost(costData: Data) throws -> Double {
        try validateEnvelope(costData)
        let bucket: UsageBucket
        do {
            guard let decoded = try JSONDecoder()
                .decode(Envelope<[UsageBucket]>.self, from: costData)
                .data?.bizData?.first else {
                throw DeepSeekPlatformUsageError.invalidResponse
            }
            bucket = decoded
        } catch let error as DeepSeekPlatformUsageError {
            throw error
        } catch {
            throw DeepSeekPlatformUsageError.invalidResponse
        }

        let dayModels = (bucket.days ?? []).flatMap { $0.data ?? [] }
        let models = dayModels.isEmpty ? (bucket.total ?? []) : dayModels
        let total = try monetaryTotal(in: models)
        return total.hasReportedValue ? total.amount : 0
    }

    private static func validateEnvelope(_ data: Data) throws {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeepSeekPlatformUsageError.invalidResponse
            }
            root = object
        } catch let error as DeepSeekPlatformUsageError {
            throw error
        } catch {
            throw DeepSeekPlatformUsageError.invalidResponse
        }

        let topCode = (root["code"] as? NSNumber)?.intValue
        let nestedCode = ((root["data"] as? [String: Any])?["biz_code"] as? NSNumber)?.intValue
        for code in [topCode, nestedCode].compactMap({ $0 }) where code != 0 {
            if code == 40_002 || code == 40_003 {
                throw DeepSeekPlatformUsageError.sessionExpired
            }
            throw DeepSeekPlatformUsageError.apiRejected(code)
        }
    }

    private static func tokenTotals(in models: [ModelUsage]) throws -> TokenTotals {
        var totals = TokenTotals()
        for item in models.flatMap({ $0.usage ?? [] }) {
            guard let rawType = item.type?.uppercased(), let category = Category(rawValue: rawType) else { continue }
            guard let rawAmount = item.amount?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let amount64 = Int64(rawAmount),
                  amount64 >= 0,
                  let amount = Int(exactly: amount64) else {
                throw DeepSeekPlatformUsageError.invalidResponse
            }
            switch category {
            case .cacheHit:
                totals.cached += amount
                totals.input += amount
            case .cacheMiss:
                totals.input += amount
            case .response:
                totals.output += amount
            case .request:
                totals.requests += amount
            }
        }
        return totals
    }

    private static func monetaryTotal(in models: [ModelUsage]) throws -> (amount: Double, hasReportedValue: Bool) {
        var total = 0.0
        var hasReportedValue = false
        for item in models.flatMap({ $0.usage ?? [] }) {
            guard let rawType = item.type?.uppercased(), let category = Category(rawValue: rawType), category != .request else {
                continue
            }
            guard let rawAmount = item.amount?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let amount = Double(rawAmount),
                  amount.isFinite,
                  amount >= 0 else {
                throw DeepSeekPlatformUsageError.invalidResponse
            }
            total += amount
            hasReportedValue = true
        }
        return (total, hasReportedValue)
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func isCurrentMonth(_ value: String, now: Date, calendar: Calendar) -> Bool {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let current = calendar.dateComponents([.year, .month], from: now)
        return parts[0] == current.year && parts[1] == current.month
    }
}

final actor DeepSeekPlatformUsageSource: DeepSeekPlatformUsageReading {
    private struct MonthKey: Hashable, Sendable {
        let year: Int
        let month: Int

        var id: String { String(format: "%04d-%02d", year, month) }
    }

    private struct HistoricalCostCache: Codable {
        let credentialFingerprint: String
        var monthlyCosts: [String: Double]
    }

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let client: ProviderAPIClient
    private let historyCacheURL: URL
    private let historyStart: DateComponents
    private let tokenImporter: @Sendable () -> [String]
    private var cachedToken: String?
    private var historicalCostCache: HistoricalCostCache?
    private var historyBackfillTask: Task<Void, Never>?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        session: URLSession? = nil,
        historyCacheURL: URL? = nil,
        historyStart: DateComponents = DateComponents(year: 2023, month: 1),
        tokenImporter: (@Sendable () -> [String])? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.historyCacheURL = historyCacheURL ?? homeDirectory
            .appendingPathComponent("Library/Application Support/Codex Bar", isDirectory: true)
            .appendingPathComponent("deepseek-history-cost-v1.json")
        self.historyStart = historyStart
        self.tokenImporter = tokenImporter ?? {
            Self.importTokens(fileManager: FileManager(), homeDirectory: homeDirectory)
        }
        self.client = ProviderAPIClient(
            providerName: "DeepSeek 平台",
            allowedHosts: ["platform.deepseek.com"],
            session: session,
            maximumResponseBytes: 512 * 1024
        )
    }

    func fetchUsage(now: Date = Date()) async throws -> DeepSeekPlatformUsage {
        var rejectedCachedToken: String?
        if let cachedToken {
            do {
                return try await fetchUsage(token: cachedToken, now: now)
            } catch {
                guard Self.isSessionFailure(error) else { throw error }
                rejectedCachedToken = cachedToken
                self.cachedToken = nil
            }
        }

        let importer = tokenImporter
        let importedTokens = await Task.detached(priority: .utility) { importer() }.value
        let candidates = importedTokens
            .filter { $0 != rejectedCachedToken }
            .uniqued()
        guard !candidates.isEmpty else { throw DeepSeekPlatformUsageError.sessionMissing }

        var lastError: Error = DeepSeekPlatformUsageError.unavailable
        for token in candidates {
            do {
                let usage = try await fetchUsage(token: token, now: now)
                cachedToken = token
                return usage
            } catch {
                lastError = error
                if Self.isSessionFailure(error) { continue }
            }
        }

        if Self.isSessionFailure(lastError) {
            throw DeepSeekPlatformUsageError.sessionExpired
        }
        throw lastError
    }

    private func fetchUsage(token: String, now: Date) async throws -> DeepSeekPlatformUsage {
        let urls = try usageURLs(now: now)
        async let amountData = client.get(urls.amount, bearerToken: token)
        async let costData = client.get(urls.cost, bearerToken: token)
        let current = try await DeepSeekPlatformUsageParser.parse(
            amountData: amountData,
            costData: costData,
            now: now,
            calendar: .current
        )
        let lifetimeCost = cachedLifetimeCost(
            token: token,
            currentMonthCost: current.currentMonthCost ?? 0,
            now: now
        )
        scheduleHistoryBackfill(token: token, now: now)
        return DeepSeekPlatformUsage(
            todayInputTokens: current.todayInputTokens,
            todayOutputTokens: current.todayOutputTokens,
            todayCachedTokens: current.todayCachedTokens,
            todayRequestCount: current.todayRequestCount,
            currentMonthTokens: current.currentMonthTokens,
            currentMonthRequestCount: current.currentMonthRequestCount,
            todayCost: current.todayCost,
            currentMonthCost: current.currentMonthCost,
            lifetimeCost: lifetimeCost,
            currency: current.currency,
            updatedAt: current.updatedAt,
            dailyUsage: current.dailyUsage
        )
    }

    private static func isSessionFailure(_ error: Error) -> Bool {
        error as? ProviderMetricsError == .unauthorized("DeepSeek 平台")
            || error as? DeepSeekPlatformUsageError == .sessionExpired
    }

    private func usageURLs(now: Date) throws -> (amount: URL, cost: URL) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        guard let year = components.year, let month = components.month else {
            throw DeepSeekPlatformUsageError.invalidResponse
        }
        return try usageURLs(year: year, month: month)
    }

    private func usageURLs(year: Int, month: Int) throws -> (amount: URL, cost: URL) {
        func makeURL(path: String) throws -> URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "platform.deepseek.com"
            components.path = path
            components.queryItems = [
                URLQueryItem(name: "month", value: String(month)),
                URLQueryItem(name: "year", value: String(year))
            ]
            guard let url = components.url else { throw DeepSeekPlatformUsageError.invalidResponse }
            return url
        }
        return (
            try makeURL(path: "/api/v0/usage/amount"),
            try makeURL(path: "/api/v0/usage/cost")
        )
    }

    private func cachedLifetimeCost(token: String, currentMonthCost: Double, now: Date) -> Double? {
        let fingerprint = Self.fingerprint(token)
        prepareHistoricalCache(for: fingerprint)
        let months = closedMonths(before: now)
        guard let cache = historicalCostCache,
              months.allSatisfy({ cache.monthlyCosts[$0.id] != nil }) else { return nil }
        return months.reduce(currentMonthCost) { total, month in
            total + (cache.monthlyCosts[month.id] ?? 0)
        }
    }

    private func scheduleHistoryBackfill(token: String, now: Date) {
        let fingerprint = Self.fingerprint(token)
        prepareHistoricalCache(for: fingerprint)
        let missing = closedMonths(before: now).filter {
            historicalCostCache?.monthlyCosts[$0.id] == nil
        }
        guard !missing.isEmpty, historyBackfillTask == nil else { return }

        historyBackfillTask = Task { [weak self] in
            await self?.backfillHistoricalCosts(
                token: token,
                fingerprint: fingerprint,
                months: missing
            )
        }
    }

    private func backfillHistoricalCosts(
        token: String,
        fingerprint: String,
        months: [MonthKey]
    ) async {
        defer { historyBackfillTask = nil }
        let client = client

        for start in stride(from: 0, to: months.count, by: 4) {
            guard historicalCostCache?.credentialFingerprint == fingerprint else { return }
            let end = min(start + 4, months.count)
            let batch = Array(months[start..<end])
            let values = await withTaskGroup(of: (MonthKey, Double?).self) { group in
                for month in batch {
                    group.addTask {
                        do {
                            var components = URLComponents()
                            components.scheme = "https"
                            components.host = "platform.deepseek.com"
                            components.path = "/api/v0/usage/cost"
                            components.queryItems = [
                                URLQueryItem(name: "month", value: String(month.month)),
                                URLQueryItem(name: "year", value: String(month.year))
                            ]
                            guard let url = components.url else { return (month, nil) }
                            let data = try await client.get(url, bearerToken: token)
                            return (month, try DeepSeekPlatformUsageParser.parseMonthCost(costData: data))
                        } catch {
                            return (month, nil)
                        }
                    }
                }
                var result: [(MonthKey, Double?)] = []
                for await value in group { result.append(value) }
                return result
            }

            guard var cache = historicalCostCache,
                  cache.credentialFingerprint == fingerprint else { return }
            for (month, cost) in values {
                guard let cost else { continue }
                cache.monthlyCosts[month.id] = cost
            }
            historicalCostCache = cache
            try? persistHistoricalCache(cache)
        }
    }

    private func closedMonths(before now: Date) -> [MonthKey] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var start = historyStart
        start.day = 1
        guard var cursor = calendar.date(from: start) else { return [] }
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        var months: [MonthKey] = []
        while cursor < current {
            let components = calendar.dateComponents([.year, .month], from: cursor)
            if let year = components.year, let month = components.month {
                months.append(MonthKey(year: year, month: month))
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    private func prepareHistoricalCache(for fingerprint: String) {
        if historicalCostCache?.credentialFingerprint == fingerprint { return }
        guard let data = try? Data(contentsOf: historyCacheURL),
              let decoded = try? JSONDecoder().decode(HistoricalCostCache.self, from: data),
              decoded.credentialFingerprint == fingerprint else {
            historicalCostCache = HistoricalCostCache(
                credentialFingerprint: fingerprint,
                monthlyCosts: [:]
            )
            return
        }
        historicalCostCache = decoded
    }

    private func persistHistoricalCache(_ cache: HistoricalCostCache) throws {
        try fileManager.createDirectory(
            at: historyCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cache).write(to: historyCacheURL, options: .atomic)
    }

    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func importTokens(fileManager: FileManager, homeDirectory: URL) -> [String] {
        let chromeRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard let profiles = try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return profiles
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap { profile -> [String] in
                let levelDB = profile
                    .appendingPathComponent("Local Storage", isDirectory: true)
                    .appendingPathComponent("leveldb", isDirectory: true)
                guard fileManager.fileExists(atPath: levelDB.path) else { return [] }
                return ChromiumLocalStorageReader.readEntries(
                    for: "https://platform.deepseek.com",
                    in: levelDB
                )
                .filter { $0.key == "userToken" }
                .compactMap { extractToken(from: $0.value) }
            }
            .uniqued()
    }

    private static func extractToken(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let token = object as? String { return plausible(token) }
            if let dictionary = object as? [String: Any] {
                for key in ["value", "token", "access_token", "accessToken", "userToken"] {
                    if let token = dictionary[key] as? String, let value = plausible(token) { return value }
                }
            }
        }
        let unquoted = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        return plausible(unquoted)
    }

    private static func plausible(_ value: String) -> String? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count >= 20 && !token.contains(where: \.isWhitespace) ? token : nil
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
