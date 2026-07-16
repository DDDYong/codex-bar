import Foundation

struct CodexAuth {
    let accessToken: String
    let accountID: String?
    let account: CodexAccount
}

enum CodexUsageError: LocalizedError, Equatable {
    case signedOut
    case invalidAuthentication
    case unavailable
    case invalidResponse
    case missingWeeklyWindow

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "请先在 Codex Desktop 中完成登录。"
        case .invalidAuthentication:
            "Codex 登录数据不可用，请重新登录。"
        case .unavailable:
            "额度服务暂时不可用，请稍后重试。"
        case .invalidResponse:
            "额度服务返回的数据格式已变化。"
        case .missingWeeklyWindow:
            "额度服务返回的数据缺少周额度窗口。"
        }
    }
}

final class CodexUsageSource {
    static let usageEndpoints = [
        URL(string: "https://chatgpt.com/backend-api/api/codex/usage")!,
        URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ]
    private static let resetCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let maximumAuthBytes = 256 * 1024
    private static let maximumResponseBytes = 1024 * 1024

    private let session: URLSession
    private let environment: [String: String]
    private let fileManager: FileManager

    init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.environment = environment
        self.fileManager = fileManager
    }

    func fetchSnapshot() async throws -> CodexUsageSnapshot {
        try await fetchDashboardData().snapshot
    }

    func fetchDashboardData() async throws -> CodexDashboardData {
        let auth = try loadAuth()
        let requestHeaders = try requestHeaders(for: auth)

        async let usageTask = fetchUsageData(headers: requestHeaders)
        async let resetCreditsTask = fetchOptionalResetCredits(headers: requestHeaders)

        let usageData = try await usageTask
        var snapshot = try Self.parseSnapshot(from: usageData, updatedAt: Date())
        let creditData = await resetCreditsTask
        if let creditData, let credits = try? Self.parseResetCredits(from: creditData) {
            snapshot = CodexUsageSnapshot(
                plan: snapshot.plan,
                shortWindow: snapshot.shortWindow,
                weeklyWindow: snapshot.weeklyWindow,
                resetCredits: credits.availableCount == nil && credits.expiresAt.isEmpty ? snapshot.resetCredits : credits,
                updatedAt: snapshot.updatedAt
            )
        }
        return CodexDashboardData(snapshot: snapshot, account: auth.account)
    }

    static func parseSnapshot(from data: Data, updatedAt: Date = Date()) throws -> CodexUsageSnapshot {
        let root = try object(from: data)
        let rateLimit = objectValue(root, keys: ["rate_limit", "rateLimit"]) ?? root
        let shortWindow = parseWindow(findWindow(
            in: rateLimit,
            names: ["primary_window", "primaryWindow", "short_window", "shortWindow", "five_hour_window", "fiveHourWindow", "5h", "primary"],
            expectedSeconds: 18_000
        ))
        let weeklyWindow = parseWindow(findWindow(
            in: rateLimit,
            names: ["secondary_window", "secondaryWindow", "weekly_window", "weeklyWindow", "week_window", "weekWindow", "weekly", "secondary"],
            expectedSeconds: 604_800
        )) ?? shortWindow
        guard let weeklyWindow else { throw CodexUsageError.missingWeeklyWindow }

        let embeddedCredits = objectValue(root, keys: ["rate_limit_reset_credits", "rateLimitResetCredits"])
        return CodexUsageSnapshot(
            plan: stringValue(root, keys: ["plan_type", "planType"])?.uppercased(),
            shortWindow: shortWindow,
            weeklyWindow: weeklyWindow,
            resetCredits: embeddedCredits.map(parseResetCredits) ?? CodexResetCredits(availableCount: nil, expiresAt: []),
            updatedAt: updatedAt
        )
    }

    static func parseResetCredits(from data: Data) throws -> CodexResetCredits {
        try parseResetCredits(object(from: data))
    }

    static func parseAuth(from data: Data) throws -> CodexAuth {
        let root = try object(from: data)
        let tokens = objectValue(root, keys: ["tokens"]) ?? root
        guard let accessToken = stringValue(tokens, keys: ["access_token", "accessToken"]), !accessToken.isEmpty else {
            throw CodexUsageError.signedOut
        }
        let claims = jwtClaims(from: accessToken)
        let accountID = safePresentationString(stringValue(tokens, keys: ["account_id", "accountId"]) ?? accountID(from: claims))
        return CodexAuth(
            accessToken: accessToken,
            accountID: accountID,
            account: CodexAccount(
                displayName: safePresentationString(stringValue(root, keys: ["name", "display_name", "displayName"]) ?? stringValue(tokens, keys: ["name", "display_name", "displayName"]) ?? stringValue(claims, keys: ["name", "preferred_username"])),
                email: safeEmail(stringValue(root, keys: ["email"]) ?? stringValue(tokens, keys: ["email"]) ?? stringValue(claims, keys: ["email"])),
                accountID: accountID
            )
        )
    }

    private func loadAuth() throws -> CodexAuth {
        let authURL = authFileURL()
        guard let attributes = try? fileManager.attributesOfItem(atPath: authURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumAuthBytes else {
            throw CodexUsageError.signedOut
        }
        do {
            return try Self.parseAuth(from: Data(contentsOf: authURL))
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.invalidAuthentication
        }
    }

    private func authFileURL() -> URL {
        let directory = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return directory.appendingPathComponent("auth.json", isDirectory: false)
    }

    private func requestHeaders(for auth: CodexAuth) throws -> [String: String] {
        guard !auth.accessToken.contains(where: { $0.isNewline }) else {
            throw CodexUsageError.invalidAuthentication
        }
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "originator": "Codex Desktop",
            "OAI-Product-Sku": "CODEX"
        ]
        if let accountID = auth.accountID, !accountID.contains(where: { $0.isNewline }) {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }

    private func fetchUsageData(headers: [String: String]) async throws -> Data {
        let primary = try await fetch(Self.usageEndpoints[0], headers: headers)
        switch primary {
        case .success(let data): return data
        case .httpFailure:
            let legacy = try await fetch(Self.usageEndpoints[1], headers: headers)
            switch legacy {
            case .success(let data): return data
            case .httpFailure(let status): throw safeHTTPError(status)
            }
        }
    }

    private func fetchOptionalResetCredits(headers: [String: String]) async -> Data? {
        guard let result = try? await fetch(Self.resetCreditsEndpoint, headers: headers),
              case .success(let data) = result else { return nil }
        return data
    }

    private enum FetchResult {
        case success(Data)
        case httpFailure(Int)
    }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CodexUsageError.unavailable }
            guard data.count <= Self.maximumResponseBytes else { throw CodexUsageError.invalidResponse }
            return (200...299).contains(response.statusCode) ? .success(data) : .httpFailure(response.statusCode)
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.unavailable
        }
    }

    private func safeHTTPError(_ status: Int) -> CodexUsageError {
        switch status {
        case 401, 403: .signedOut
        default: .unavailable
        }
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        return object
    }

    private static func objectValue(_ object: [String: Any], keys: [String]) -> [String: Any]? {
        keys.lazy.compactMap { object[$0] as? [String: Any] }.first
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first
    }

    private static func numberValue(_ object: [String: Any], keys: [String]) -> (String, Double)? {
        keys.lazy.compactMap { key in
            guard let number = object[key] as? NSNumber else { return nil }
            return (key, number.doubleValue)
        }.first
    }

    private static func integerValue(_ object: [String: Any], keys: [String]) -> UInt64? {
        keys.lazy.compactMap { key in
            guard let number = object[key] as? NSNumber, number.doubleValue >= 0 else { return nil }
            return UInt64(number.doubleValue)
        }.first
    }

    private static func parseWindow(_ value: [String: Any]?) -> CodexUsageWindow? {
        guard let value else { return nil }
        let remaining: Double
        if let (key, rawRemaining) = numberValue(value, keys: ["remaining_percent", "remainingPercent", "remaining_pct", "remainingPct", "remaining_ratio", "remainingRatio", "remaining"]) {
            remaining = scaleRatio(key: key, value: rawRemaining) ? rawRemaining * 100 : rawRemaining
        } else if let (key, rawUsed) = numberValue(value, keys: ["used_percent", "usedPercent", "used_pct", "usedPct", "used_ratio", "usedRatio", "utilization", "used"]) {
            let used = scaleRatio(key: key, value: rawUsed) ? rawUsed * 100 : rawUsed
            remaining = 100 - used
        } else {
            return nil
        }
        return CodexUsageWindow(
            remainingPercent: min(max(remaining, 0), 100),
            resetsAt: timestampValue(value, keys: ["reset_at", "resetAt", "resets_at", "resetsAt", "reset_time", "resetTime"]),
            windowSeconds: integerValue(value, keys: ["limit_window_seconds", "limitWindowSeconds", "window_seconds", "windowSeconds", "duration_seconds", "durationSeconds", "period_seconds", "periodSeconds"]) ?? 0
        )
    }

    private static func findWindow(in rateLimit: [String: Any], names: [String], expectedSeconds: UInt64) -> [String: Any]? {
        for name in names {
            if let direct = rateLimit[name] as? [String: Any], parseWindow(direct) != nil { return direct }
        }
        for key in ["windows", "limit_windows", "limitWindows", "limits", "buckets"] {
            guard let windows = rateLimit[key] as? [[String: Any]] else { continue }
            for window in windows {
                guard let parsed = parseWindow(window) else { continue }
                let durationMatches = expectedSeconds > 0 && parsed.windowSeconds >= expectedSeconds - 60 && parsed.windowSeconds <= expectedSeconds + 60
                let label = stringValue(window, keys: ["name", "type", "id", "window", "label"])?.lowercased() ?? ""
                let nameMatches = names.contains { label == $0.lowercased() || label.contains($0.lowercased()) }
                if durationMatches || nameMatches { return window }
            }
        }
        return nil
    }

    private static func parseResetCredits(_ object: [String: Any]) -> CodexResetCredits {
        var expirations = Set<String>()
        collectExpirations(in: object, into: &expirations)
        return CodexResetCredits(
            availableCount: integerValue(object, keys: ["available_count", "availableCount", "remaining", "count", "quantity"]),
            expiresAt: expirations.sorted()
        )
    }

    private static func collectExpirations(in value: Any, into output: inout Set<String>) {
        if let array = value as? [Any] {
            array.forEach { collectExpirations(in: $0, into: &output) }
        } else if let object = value as? [String: Any] {
            if let timestamp = timestampValue(object, keys: ["expires_at", "expiresAt", "expiration_time", "expirationTime", "expires"]) {
                output.insert(timestamp)
            }
            ["credits", "reset_credits", "resetCredits", "available", "items", "grants"].forEach { key in
                if let child = object[key] { collectExpirations(in: child, into: &output) }
            }
        }
    }

    private static func timestampValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
            if let seconds = (object[key] as? NSNumber)?.doubleValue {
                return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
            }
        }
        return nil
    }

    private static func scaleRatio(key: String, value: Double) -> Bool {
        ["remaining_ratio", "remainingRatio", "used_ratio", "usedRatio", "utilization"].contains(key)
            || (!key.localizedCaseInsensitiveContains("percent") && !key.localizedCaseInsensitiveContains("pct") && value <= 1)
    }

    private static func accountID(from object: [String: Any]) -> String? {
        stringValue(object, keys: ["https://api.openai.com/auth.chatgpt_account_id", "chatgpt_account_id"])
    }

    private static func jwtClaims(from token: String) -> [String: Any] {
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return [:] }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let payload = Data(base64Encoded: encoded), let object = try? object(from: payload) else { return [:] }
        return object
    }

    private static func safePresentationString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return trimmed
    }

    private static func safeEmail(_ value: String?) -> String? {
        guard let value = safePresentationString(value), value.contains("@"), !value.contains(" ") else { return nil }
        return value
    }
}
