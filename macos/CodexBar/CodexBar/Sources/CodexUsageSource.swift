import Foundation
import LocalAuthentication
import Security

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

private enum CodexAppServerResetCreditsError: Error {
    case unavailable
    case timedOut
    case invalidResponse
}

private final class CodexAppServerResetCreditsSource {
    private static let timeout: TimeInterval = 12
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func fetchResetCredits() async throws -> CodexResetCredits {
        let executableURL = try resolveCodexExecutable()
        return try await Task.detached(priority: .utility) { [environment] in
            try Self.readResetCredits(executableURL: executableURL, environment: environment)
        }.value
    }

    private func resolveCodexExecutable() throws -> URL {
        let configured = environment["CODEX_BIN"].map(URL.init(fileURLWithPath:))
        let common = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
            .map(URL.init(fileURLWithPath:))
        let nvmRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvmCandidates = (try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/codex") } ?? []

        guard let executableURL = ([configured].compactMap { $0 } + common + nvmCandidates)
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw CodexAppServerResetCreditsError.unavailable
        }
        return executableURL
    }

    private static func readResetCredits(
        executableURL: URL,
        environment: [String: String]
    ) throws -> CodexResetCredits {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let completionQueue = DispatchQueue(label: "app.codexbar.reset-credits-source")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CodexResetCredits, Error>?
        var buffer = Data()
        var didSendRequest = false

        func finish(_ value: Result<CodexResetCredits, Error>) {
            completionQueue.sync {
                guard result == nil else { return }
                result = value
                if process.isRunning { process.terminate() }
                semaphore.signal()
            }
        }

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        var processEnvironment = environment
        let existingPath = processEnvironment["PATH"] ?? "/usr/bin:/bin"
        processEnvironment["PATH"] = "\(executableURL.deletingLastPathComponent().path):\(existingPath)"
        process.environment = processEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let identifier = message["id"] as? Int else { continue }

                if identifier == 1, !didSendRequest {
                    didSendRequest = true
                    writeJSON(
                        ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
                        to: input.fileHandleForWriting
                    )
                    writeJSON(
                        ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]],
                        to: input.fileHandleForWriting
                    )
                } else if identifier == 2 {
                    guard message["error"] == nil,
                          let payload = try? JSONSerialization.data(withJSONObject: message["result"] ?? [:]),
                          let credits = try? CodexUsageSource.parseResetCredits(from: payload),
                          credits.availableCount != nil || !credits.expiresAt.isEmpty else {
                        finish(.failure(CodexAppServerResetCreditsError.invalidResponse))
                        continue
                    }
                    finish(.success(credits))
                }
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerResetCreditsError.unavailable
        }

        let timeout = DispatchWorkItem {
            finish(.failure(CodexAppServerResetCreditsError.timedOut))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.timeout,
            execute: timeout
        )
        writeJSON(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "codex-bar", "version": "1.0"],
                    "capabilities": [:]
                ]
            ],
            to: input.fileHandleForWriting
        )
        semaphore.wait()
        timeout.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        guard let result else { throw CodexAppServerResetCreditsError.invalidResponse }
        return try result.get()
    }

    private static func writeJSON(_ object: [String: Any], to handle: FileHandle) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
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
    private static var networkPolicy: FixedHostHTTPSPolicy {
        FixedHostHTTPSPolicy(
            allowedHosts: ["chatgpt.com"],
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private let session: URLSession
    private let environment: [String: String]
    private let fileManager: FileManager
    private let appServerResetCreditsSource: CodexAppServerResetCreditsSource
    private let resetCreditsCacheLifetime: TimeInterval = 5 * 60
    private var resetCreditsCache: CachedResetCredits?
    private var resetCreditsLastAttemptAt: Date?

    private struct CachedResetCredits {
        let value: CodexResetCredits
        let fetchedAt: Date
    }

    init(
        session: URLSession? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.session = session ?? FixedHostURLSession.make(policy: Self.networkPolicy)
        self.environment = environment
        self.fileManager = fileManager
        self.appServerResetCreditsSource = CodexAppServerResetCreditsSource(
            fileManager: fileManager,
            environment: environment
        )
    }

    func fetchSnapshot() async throws -> CodexUsageSnapshot {
        try await fetchDashboardData().snapshot
    }

    func fetchDashboardData() async throws -> CodexDashboardData {
        let auth = try loadAuth()
        let requestHeaders = try requestHeaders(for: auth)

        let usageData = try await fetchUsageData(headers: requestHeaders)
        var snapshot = try Self.parseSnapshot(from: usageData, updatedAt: Date())
        if let credits = await fetchOptionalResetCredits(headers: requestHeaders) {
            snapshot = CodexUsageSnapshot(
                plan: snapshot.plan,
                shortWindow: snapshot.shortWindow,
                weeklyWindow: snapshot.weeklyWindow,
                resetCredits: credits.availableCount == nil && credits.expiresAt.isEmpty ? snapshot.resetCredits : credits,
                updatedAt: snapshot.updatedAt,
                providerType: snapshot.providerType
            )
        }
        return CodexDashboardData(snapshot: snapshot, account: auth.account)
    }

    static func parseSnapshot(from data: Data, updatedAt: Date = Date(), providerType: ProviderType = .officialCodex) throws -> CodexUsageSnapshot {
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
            updatedAt: updatedAt,
            providerType: providerType
        )
    }

    static func parseResetCredits(from data: Data) throws -> CodexResetCredits {
        let root = try object(from: data)
        return parseResetCredits(
            objectValue(root, keys: ["rate_limit_reset_credits", "rateLimitResetCredits"]) ?? root
        )
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

    private func fetchOptionalResetCredits(headers: [String: String]) async -> CodexResetCredits? {
        let now = Date()
        if let cached = resetCreditsCache,
           now.timeIntervalSince(cached.fetchedAt) < resetCreditsCacheLifetime,
           let value = ResetCreditsCachePolicy.cachedValue(
               cached.value,
               capturedAt: cached.fetchedAt,
               now: now
           ) {
            return value
        }
        if let lastAttemptAt = resetCreditsLastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < resetCreditsCacheLifetime {
            return nil
        }
        resetCreditsLastAttemptAt = now

        if let credits = try? await appServerResetCreditsSource.fetchResetCredits(),
           credits.availableCount != nil || !credits.expiresAt.isEmpty {
            let value = ResetCreditsCachePolicy.currentValue(credits, now: now)
            guard value.availableCount != nil || !value.expiresAt.isEmpty else { return nil }
            resetCreditsCache = CachedResetCredits(value: value, fetchedAt: now)
            return value
        }

        guard let result = try? await fetch(Self.resetCreditsEndpoint, headers: headers),
              case .success(let data) = result,
              let credits = try? Self.parseResetCredits(from: data) else { return nil }

        let value = ResetCreditsCachePolicy.currentValue(credits, now: now)
        guard value.availableCount != nil || !value.expiresAt.isEmpty else { return nil }
        resetCreditsCache = CachedResetCredits(value: value, fetchedAt: now)
        return value
    }

    private enum FetchResult {
        case success(Data)
        case httpFailure(Int)
    }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> FetchResult {
        guard Self.networkPolicy.allows(url) else { throw CodexUsageError.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CodexUsageError.unavailable }
            guard Self.networkPolicy.accepts(data: data, response: response) else {
                throw CodexUsageError.invalidResponse
            }
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

// MARK: - CCSwitchConfigSource

import SQLite3

private let codexBarSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum CCSwitchError: LocalizedError, Equatable {
    case dbNotFound
    case dbReadFailed(String)
    case noProviders
    case apiKeyMissing

    var errorDescription: String? {
        switch self {
        case .dbNotFound: "cc-switch 数据库未找到，请确认已安装并配置 cc-switch。"
        case .dbReadFailed(let msg): "读取 cc-switch 配置失败：\(msg)"
        case .noProviders: "cc-switch 中未找到 Codex 第三方提供商配置。"
        case .apiKeyMissing: "cc-switch 提供商配置中缺少 API Key。"
        }
    }
}

final class CCSwitchConfigSource {
    private let dbPath: String

    private struct CurrentProvider {
        let id: String
        let name: String
        let providerType: String?
        let settingsConfig: String
    }

    init(dbPath: String = NSHomeDirectory() + "/.cc-switch/cc-switch.db") {
        self.dbPath = dbPath
    }

    func deepSeekProviderID() -> String? {
        try? currentDeepSeekProvider().id
    }

    func readAPIKeyForDeepSeekProvider() throws -> String {
        let provider = try currentDeepSeekProvider()
        let config = parseSettingsConfig(provider.settingsConfig)

        if let apiKey = config["api_key"] as? String, !apiKey.isEmpty {
            return apiKey
        }

        if let auth = config["auth"] as? [String: Any],
           let apiKey = auth["OPENAI_API_KEY"] as? String,
           !apiKey.isEmpty {
            return apiKey
        }

        throw CCSwitchError.apiKeyMissing
    }

    func isLocalProxyEnabled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return settings["enableLocalProxy"] as? Bool ?? false
    }

    private func currentDeepSeekProvider() throws -> CurrentProvider {
        let rows = try sqliteRows(
            """
            SELECT id, name, provider_type, settings_config
            FROM providers
            WHERE app_type = ? AND is_current = 1
            ORDER BY id
            LIMIT 2
            """,
            params: ["codex"]
        )
        guard rows.count == 1,
              let id = rows[0]["id"] as? String,
              let name = rows[0]["name"] as? String,
              let settingsConfig = rows[0]["settings_config"] as? String else {
            throw CCSwitchError.noProviders
        }
        let providerType = rows[0]["provider_type"] as? String
        guard name.caseInsensitiveCompare("DeepSeek") == .orderedSame
                || providerType?.caseInsensitiveCompare("deepseek") == .orderedSame else {
            throw CCSwitchError.noProviders
        }
        return CurrentProvider(
            id: id,
            name: name,
            providerType: providerType,
            settingsConfig: settingsConfig
        )
    }

    private func sqliteRows(_ sql: String, params: [String]) throws -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database = db else {
            throw CCSwitchError.dbReadFailed("无法打开数据库")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            throw CCSwitchError.dbReadFailed("SQL 准备失败")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            let result = p.withCString {
                sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, codexBarSQLiteTransient)
            }
            guard result == SQLITE_OK else {
                throw CCSwitchError.dbReadFailed("SQL 参数绑定失败")
            }
        }

        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else {
                throw CCSwitchError.dbReadFailed("SQL 查询失败")
            }
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(stmt) {
                guard let name = sqlite3_column_name(stmt, index) else { continue }
                let key = String(cString: name)
                switch sqlite3_column_type(stmt, index) {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, index) {
                        row[key] = String(cString: text)
                    }
                case SQLITE_INTEGER:
                    row[key] = Int(sqlite3_column_int64(stmt, index))
                case SQLITE_FLOAT:
                    row[key] = sqlite3_column_double(stmt, index)
                case SQLITE_NULL:
                    row[key] = NSNull()
                default:
                    throw CCSwitchError.dbReadFailed("SQL 字段类型异常")
                }
            }
            rows.append(row)
        }
    }

    private func parseSettingsConfig(_ value: String) -> [String: Any] {
        guard let data = value.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return config
    }

    private func readSettings() throws -> [String: Any] {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.cc-switch/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CCSwitchError.dbReadFailed("无法解析 settings.json")
        }
        return json
    }

}

// MARK: - DeepSeekCredentialSource

final class DeepSeekCredentialSource {
    private let ccSwitchSource: CCSwitchConfigSource
    private let providerCredentialStore: ProviderCredentialStoring?
    private let keychainService: String
    private let keychainAccount: String
    private let legacyCredentialLock = NSLock()
    private var cachedLegacyCredential: String?
    private var didAttemptLegacyCredentialRead = false

    init(
        ccSwitchSource: CCSwitchConfigSource = CCSwitchConfigSource(),
        providerCredentialStore: ProviderCredentialStoring? = nil,
        keychainService: String = "codex-deepseek-api-key",
        keychainAccount: String = NSUserName()
    ) {
        self.ccSwitchSource = ccSwitchSource
        self.providerCredentialStore = providerCredentialStore
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    var isConfigured: Bool {
        providerCredentialStore?.contains(providerID: .deepseek, kind: .apiKey) == true
            || hasKeychainCredential
            || ccSwitchSource.deepSeekProviderID() != nil
    }

    func readAPIKey() throws -> String {
        if let key = try? providerCredentialStore?.read(providerID: .deepseek, kind: .apiKey),
           !key.isEmpty {
            return key
        }

        if let key = legacyCredentialIfLoaded() { return key }
        if beginLegacyCredentialRead(), let key = readKeychainCredential(), !key.isEmpty {
            cacheLegacyCredential(key)
            try? providerCredentialStore?.save(key, providerID: .deepseek, kind: .apiKey)
            return key
        }
        return try ccSwitchSource.readAPIKeyForDeepSeekProvider()
    }

    private var hasKeychainCredential: Bool {
        var result: CFTypeRef?
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private func readKeychainCredential() -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func legacyCredentialIfLoaded() -> String? {
        legacyCredentialLock.lock()
        defer { legacyCredentialLock.unlock() }
        return cachedLegacyCredential
    }

    private func beginLegacyCredentialRead() -> Bool {
        legacyCredentialLock.lock()
        defer { legacyCredentialLock.unlock() }
        guard !didAttemptLegacyCredentialRead else { return false }
        didAttemptLegacyCredentialRead = true
        return true
    }

    private func cacheLegacyCredential(_ credential: String) {
        legacyCredentialLock.lock()
        cachedLegacyCredential = credential
        legacyCredentialLock.unlock()
    }
}

// MARK: - ProxyUsageSource (reads cc-switch proxy logs)

struct ProxyDailyUsage: Equatable {
    let requestCount: Int
    let successfulRequestCount: Int
    let failedRequestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let totalCostUSD: Double
    let models: [String]
    let updatedAt: Date

    init(
        requestCount: Int,
        successfulRequestCount: Int? = nil,
        failedRequestCount: Int = 0,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        totalCostUSD: Double,
        models: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.requestCount = requestCount
        self.successfulRequestCount = successfulRequestCount ?? max(0, requestCount - failedRequestCount)
        self.failedRequestCount = failedRequestCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
        self.models = models
        self.updatedAt = updatedAt
    }

    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

struct ProxyUsageReport: Equatable {
    let schemaVersion: Int
    let usageByProvider: [ProviderID: ProxyDailyUsage]
    let detectedProviderIDs: Set<ProviderID>
    let updatedAt: Date
}

enum ProxyUsageError: LocalizedError, Equatable {
    case databaseUnavailable
    case unsupportedSchema(Int)
    case queryFailed

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: "cc-switch 代理日志不可用。"
        case .unsupportedSchema(let version): "cc-switch 日志结构不兼容（版本 \(version)）。"
        case .queryFailed: "cc-switch 代理日志查询失败。"
        }
    }
}

protocol ProxyUsageReading: AnyObject {
    func todayReport(appType: String, now: Date) throws -> ProxyUsageReport
}

final class ProxyUsageSource: ProxyUsageReading {
    private let dbPath: String

    init(dbPath: String = NSHomeDirectory() + "/.cc-switch/cc-switch.db") {
        self.dbPath = dbPath
    }

    func todayReport(appType: String = "codex", now: Date = Date()) throws -> ProxyUsageReport {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ProxyUsageError.databaseUnavailable
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database = db else {
            throw ProxyUsageError.databaseUnavailable
        }
        defer { sqlite3_close(database) }

        let schemaVersion = try integer(from: "PRAGMA user_version", database: database)
        let logColumns = try columns(in: "proxy_request_logs", database: database)
        let providerColumns = try columns(in: "providers", database: database)
        let requiredLogColumns: Set<String> = [
            "provider_id", "app_type", "model", "input_tokens", "output_tokens",
            "cache_read_tokens", "cache_creation_tokens", "total_cost_usd", "status_code", "created_at"
        ]
        let requiredProviderColumns: Set<String> = ["id", "name", "provider_type"]
        guard requiredLogColumns.isSubset(of: logColumns), requiredProviderColumns.isSubset(of: providerColumns) else {
            throw ProxyUsageError.unsupportedSchema(schemaVersion)
        }

        guard let interval = Calendar.current.dateInterval(of: .day, for: now) else {
            throw ProxyUsageError.queryFailed
        }
        let sql = """
            SELECT p.name,
                   p.provider_type,
                   COUNT(*),
                   COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 400 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN l.status_code < 200 OR l.status_code >= 400 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(l.input_tokens), 0),
                   COALESCE(SUM(l.output_tokens), 0),
                   COALESCE(SUM(l.cache_read_tokens), 0),
                   COALESCE(SUM(l.cache_creation_tokens), 0),
                   COALESCE(SUM(CAST(l.total_cost_usd AS REAL)), 0),
                   COALESCE(GROUP_CONCAT(DISTINCT l.model), '')
            FROM proxy_request_logs AS l
            INNER JOIN providers AS p ON p.id = l.provider_id AND p.app_type = l.app_type
            WHERE l.app_type = ?1
              AND l.created_at >= ?2
              AND l.created_at < ?3
            GROUP BY l.provider_id, p.name, p.provider_type
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw ProxyUsageError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = appType.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        guard bindResult == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, Int64(interval.start.timeIntervalSince1970)) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 3, Int64(interval.end.timeIntervalSince1970)) == SQLITE_OK else {
            throw ProxyUsageError.queryFailed
        }

        var usageByProvider: [ProviderID: ProxyDailyUsage] = [:]
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ProxyUsageError.queryFailed }
            let name = text(at: 0, in: stmt)
            let providerType = text(at: 1, in: stmt)
            guard let providerID = ProviderID.fromCCSwitch(name: name, providerType: providerType) else { continue }
            let cost = sqlite3_column_double(stmt, 9)
            guard cost.isFinite, cost >= 0 else { throw ProxyUsageError.queryFailed }
            let models = text(at: 10, in: stmt)
                .split(separator: ",")
                .map(String.init)
                .filter { !$0.isEmpty }
                .sorted()
            usageByProvider[providerID] = ProxyDailyUsage(
                requestCount: Int(sqlite3_column_int64(stmt, 2)),
                successfulRequestCount: Int(sqlite3_column_int64(stmt, 3)),
                failedRequestCount: Int(sqlite3_column_int64(stmt, 4)),
                inputTokens: Int(sqlite3_column_int64(stmt, 5)),
                outputTokens: Int(sqlite3_column_int64(stmt, 6)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 7)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 8)),
                totalCostUSD: cost,
                models: models,
                updatedAt: now
            )
        }

        return ProxyUsageReport(
            schemaVersion: schemaVersion,
            usageByProvider: usageByProvider,
            detectedProviderIDs: Set(usageByProvider.keys),
            updatedAt: now
        )
    }

    private func integer(from sql: String, database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw ProxyUsageError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ProxyUsageError.queryFailed }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func columns(in table: String, database: OpaquePointer) throws -> Set<String> {
        guard table == "proxy_request_logs" || table == "providers" else {
            throw ProxyUsageError.queryFailed
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            throw ProxyUsageError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        var result = Set<String>()
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ProxyUsageError.queryFailed }
            result.insert(text(at: 1, in: stmt))
        }
        return result
    }

    private func text(at index: Int32, in statement: OpaquePointer) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }
}

// MARK: - DeepSeekBalanceSource

enum DeepSeekBalanceError: LocalizedError, Equatable {
    case apiKeyMissing
    case requestFailed(String)
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: "DeepSeek API Key 未配置或无法从钥匙串读取。"
        case .requestFailed(let msg): "DeepSeek 余额查询失败：\(msg)"
        case .invalidResponse: "DeepSeek 余额数据格式异常。"
        case .unavailable: "DeepSeek 服务暂不可用，请稍后重试。"
        }
    }
}

private struct DeepSeekBalanceAPIResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let toppedUpBalance: String
        let grantedBalance: String

        private enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case toppedUpBalance = "topped_up_balance"
            case grantedBalance = "granted_balance"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

final class DeepSeekBalanceSource {
    private let apiKey: () throws -> String
    private let session: URLSession
    private let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let maximumResponseBytes = 64 * 1024
    private static var networkPolicy: FixedHostHTTPSPolicy {
        FixedHostHTTPSPolicy(
            allowedHosts: ["api.deepseek.com"],
            maximumResponseBytes: maximumResponseBytes
        )
    }

    init(
        apiKey: @escaping () throws -> String,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.session = session ?? FixedHostURLSession.make(policy: Self.networkPolicy)
    }

    func fetchBalance() async throws -> ProviderBalance {
        let key: String
        do {
            key = try apiKey()
        } catch {
            throw DeepSeekBalanceError.apiKeyMissing
        }

        guard !key.isEmpty else {
            throw DeepSeekBalanceError.apiKeyMissing
        }

        var request = URLRequest(url: balanceURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeepSeekBalanceError.requestFailed("网络请求失败")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekBalanceError.unavailable
        }
        guard Self.networkPolicy.accepts(data: data, response: httpResponse) else {
            throw DeepSeekBalanceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw DeepSeekBalanceError.apiKeyMissing
            }
            throw DeepSeekBalanceError.unavailable
        }

        return try Self.parseBalance(from: data)
    }

    static func parseBalance(from data: Data, updatedAt: Date = Date()) throws -> ProviderBalance {
        let balanceResponse: DeepSeekBalanceAPIResponse
        do {
            balanceResponse = try JSONDecoder().decode(DeepSeekBalanceAPIResponse.self, from: data)
        } catch {
            throw DeepSeekBalanceError.invalidResponse
        }

        guard balanceResponse.isAvailable,
              let primary = balanceResponse.balanceInfos.first else {
            throw DeepSeekBalanceError.unavailable
        }
        guard let totalBalance = Double(primary.totalBalance),
              let toppedUpBalance = Double(primary.toppedUpBalance),
              let grantedBalance = Double(primary.grantedBalance) else {
            throw DeepSeekBalanceError.invalidResponse
        }

        return ProviderBalance(
            provider: "deepseek",
            totalBalance: totalBalance,
            toppedUpBalance: toppedUpBalance,
            grantedBalance: grantedBalance,
            currency: primary.currency,
            updatedAt: updatedAt
        )
    }
}
