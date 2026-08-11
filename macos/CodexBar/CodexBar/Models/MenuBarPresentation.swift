import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Codable {
    case detailed
    case compact
    case iconOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .detailed: "详细"
        case .compact: "简略"
        case .iconOnly: "仅图标"
        }
    }

    var thirdPartySummary: String {
        switch self {
        case .detailed: "图标 + 可用/预算/配额 + Provider 可核验明细"
        case .compact: "图标 + 可用余额、Key 预算或配额"
        case .iconOnly: "仅显示图标"
        }
    }
}

struct MenuBarProviderItem: Equatable {
    let providerType: ProviderType
    let title: String
    let activity: SessionActivity

    init(providerType: ProviderType, title: String, activity: SessionActivity = .unknown) {
        self.providerType = providerType
        self.title = title
        self.activity = activity
    }
}

enum MenuBarPresentation {
    static func title(
        for mode: MenuBarDisplayMode,
        snapshot: CodexUsageSnapshot?,
        balance: ProviderBalance? = nil,
        isThirdParty: Bool = false
    ) -> String {
        if isThirdParty, let balance {
            return thirdPartyTitle(for: mode, balance: balance)
        }
        let detailed = summary(snapshot)
        switch mode {
        case .detailed: return detailed
        case .compact: return detailed.components(separatedBy: " · ").first ?? "Week --"
        case .iconOnly: return ""
        }
    }

    static func providerItems(
        for mode: MenuBarDisplayMode,
        snapshot: CodexUsageSnapshot?,
        deepSeekBalance: ProviderBalance?,
        deepSeekConfigured: Bool,
        isRefreshingDeepSeek: Bool,
        activities: ProviderActivitySnapshot = .unknown
    ) -> [MenuBarProviderItem] {
        let providerSnapshots: [ProviderID: ProviderFinancialSnapshot]
        if let deepSeekBalance {
            providerSnapshots = [
                .deepseek: ProviderFinancialSnapshot(
                    providerID: .deepseek,
                    capabilities: [.accountBalance],
                    balance: MoneySnapshot(
                        available: deepSeekBalance.totalBalance,
                        toppedUp: deepSeekBalance.toppedUpBalance,
                        granted: deepSeekBalance.grantedBalance,
                        currency: deepSeekBalance.currency
                    ),
                    spending: [],
                    tokens: nil,
                    budget: nil,
                    source: .providerOfficialAPI,
                    confidence: .verified,
                    coverage: .account,
                    updatedAt: deepSeekBalance.updatedAt
                )
            ]
        } else {
            providerSnapshots = [:]
        }
        return providerItems(
            for: mode,
            snapshot: snapshot,
            providerSnapshots: providerSnapshots,
            enabledProviderIDs: deepSeekConfigured ? [.deepseek] : [],
            refreshingProviderIDs: isRefreshingDeepSeek ? [.deepseek] : [],
            activities: activities
        )
    }

    static func providerItems(
        for mode: MenuBarDisplayMode,
        snapshot: CodexUsageSnapshot?,
        providerSnapshots: [ProviderID: ProviderFinancialSnapshot],
        enabledProviderIDs: Set<ProviderID>,
        refreshingProviderIDs: Set<ProviderID>,
        activities: ProviderActivitySnapshot = .unknown
    ) -> [MenuBarProviderItem] {
        var items = [MenuBarProviderItem(
            providerType: .officialCodex,
            title: title(for: mode, snapshot: snapshot),
            activity: activities.officialCodex
        )]

        for providerID in ProviderID.allCases where enabledProviderIDs.contains(providerID) {
            let providerTitle: String
            if mode == .iconOnly {
                providerTitle = ""
            } else if let providerSnapshot = providerSnapshots[providerID] {
                providerTitle = thirdPartyTitle(for: mode, snapshot: providerSnapshot)
            } else if refreshingProviderIDs.contains(providerID) {
                providerTitle = providerID.capabilities == [.accountBalance] ? "余额查询中" : "指标查询中"
            } else {
                providerTitle = providerID.capabilities == [.accountBalance] ? "余额不可用" : "指标不可用"
            }
            items.append(MenuBarProviderItem(
                providerType: providerID.providerType,
                title: providerTitle,
                activity: activities.activity(for: providerID.providerType)
            ))
        }
        return items
    }

    static func visibleProviderItems(from candidates: [MenuBarProviderItem]) -> [MenuBarProviderItem] {
        let consuming = candidates.filter { $0.activity.isConsuming }
        if !consuming.isEmpty { return consuming }
        if let official = candidates.first(where: { $0.providerType == .officialCodex }) {
            return [official]
        }
        return Array(candidates.prefix(1))
    }

    static func thirdPartyTitle(for mode: MenuBarDisplayMode, balance: ProviderBalance) -> String {
        switch mode {
        case .iconOnly: return ""
        case .compact:
            return "\(balance.currencySymbol)\(balance.formattedTotal)"
        case .detailed:
            return "\(balance.currencySymbol)\(balance.formattedTotal) · 充值\(balance.currencySymbol)\(balance.formattedToppedUp) · 赠送\(balance.currencySymbol)\(balance.formattedGranted)"
        }
    }

    static func thirdPartyTitle(for mode: MenuBarDisplayMode, snapshot: ProviderFinancialSnapshot) -> String {
        guard mode != .iconOnly else { return "" }
        let primary = snapshot.balance.map { $0.formatted($0.available) }
            ?? snapshot.budget.map { formattedMoney($0.remaining, currency: $0.currency) }
            ?? snapshot.quotaWindows.first.map { String(format: "%.0f%%", $0.remainingPercent) }
            ?? snapshot.spending.first.map { formattedMoney($0.amount, currency: $0.currency) }
            ?? "--"
        guard mode == .detailed else { return primary }

        var details: [String] = [primary]
        if let balance = snapshot.balance {
            if let toppedUp = balance.toppedUp {
                details.append("充值\(balance.formatted(toppedUp))")
            }
            if let granted = balance.granted {
                details.append("赠送\(balance.formatted(granted))")
            }
        }
        if let today = snapshot.spending.first(where: { $0.period == .today }) {
            details.append("今日\(formattedMoney(today.amount, currency: today.currency))")
        }
        if let budget = snapshot.budget {
            details.append("Key余\(formattedMoney(budget.remaining, currency: budget.currency))")
        }
        for quota in snapshot.quotaWindows.prefix(2) {
            details.append("\(quota.name)余\(String(format: "%.0f%%", quota.remainingPercent))")
        }
        return details.joined(separator: " · ")
    }

    static func providerDetailLines(
        snapshot: ProviderFinancialSnapshot,
        proxyUsage: ProxyDailyUsage? = nil
    ) -> [String] {
        if snapshot.providerID == .deepseek {
            let todaySpend = snapshot.spending.first(where: { $0.period == .today })
            let todayCost = todaySpend.map { formattedMoney($0.amount, currency: $0.currency) }
                ?? proxyUsage.map { "$\(String(format: "%.2f", $0.totalCostUSD))" }
                ?? "--"
            let reportedTokens: String?
            if let tokens = snapshot.tokens, tokens.period == .today {
                reportedTokens = compactTokenCount(tokens.input + tokens.output)
            } else {
                reportedTokens = nil
            }
            let proxyTokens = proxyUsage.map { compactTokenCount($0.totalTokens) }
            let todayTokens = reportedTokens ?? proxyTokens ?? "--"

            let available = snapshot.balance.map { $0.formatted($0.available) } ?? "--"
            let lifetimeSnapshot = snapshot.spending.first(where: { $0.period == .lifetime })
            let lifetimeSpend = lifetimeSnapshot
                .map { formattedMoney($0.amount, currency: $0.currency) }
                ?? "--"
            let cumulative: String
            if let balance = snapshot.balance, let lifetimeSnapshot {
                cumulative = formattedMoney(
                    balance.available + lifetimeSnapshot.amount,
                    currency: lifetimeSnapshot.currency
                )
            } else {
                cumulative = "--"
            }
            let balanceLine = "Avail \(available) · Used \(lifetimeSpend) · Total \(cumulative)"
            return [
                "DeepSeek: Today \(todayCost) · Tokens \(todayTokens)",
                balanceLine
            ]
        }

        var lines: [String] = []
        if let balance = snapshot.balance {
            lines.append("\(snapshot.providerID.displayName) 可用：\(balance.formatted(balance.available))")
            if balance.toppedUp != nil || balance.granted != nil {
                let toppedUp = balance.toppedUp.map(balance.formatted) ?? "--"
                let granted = balance.granted.map(balance.formatted) ?? "--"
                lines.append("充值余额 \(toppedUp) · 赠送余额 \(granted)")
            }
        }

        if let lifetime = snapshot.spending.first(where: { $0.period == .lifetime }) {
            lines.append("累计已用：\(formattedMoney(lifetime.amount, currency: lifetime.currency))")
        } else {
            lines.append("累计已用：官方接口未提供")
        }

        if let balance = snapshot.balance, let purchased = balance.purchased {
            lines.append("总充值/购买：\(balance.formatted(purchased))")
        } else {
            lines.append("总充值：官方接口未提供")
        }

        if snapshot.source != .localProxy,
           let today = snapshot.spending.first(where: { $0.period == .today }) {
            lines.append("今日消费：\(formattedMoney(today.amount, currency: today.currency))")
        } else if let proxyUsage {
            lines.append("今日消费：$\(String(format: "%.2f", proxyUsage.totalCostUSD))（代理）")
        } else {
            lines.append("今日消费：当前链路无统计")
        }

        if snapshot.source != .localProxy {
            for spending in snapshot.spending where spending.period != .lifetime && spending.period != .today {
                lines.append("\(spending.period.displayName)消费：\(formattedMoney(spending.amount, currency: spending.currency))")
            }
        }
        if let budget = snapshot.budget {
            lines.append(
                "Key预算：\(formattedMoney(budget.remaining, currency: budget.currency)) / \(formattedMoney(budget.limit, currency: budget.currency))"
            )
        }
        for quota in snapshot.quotaWindows {
            var detail = "\(quota.name)：剩余 \(String(format: "%.0f%%", quota.remainingPercent))"
            if let used = quota.usedCount, let total = quota.totalCount {
                detail += "（\(formattedInteger(used)) / \(formattedInteger(total))）"
            }
            lines.append(detail)
        }

        if let tokens = snapshot.tokens, tokens.period == .today {
            lines.append("今日 Token：\(formattedInteger(tokens.input + tokens.output))")
            lines.append("输入 \(formattedInteger(tokens.input)) · 输出 \(formattedInteger(tokens.output))")
        } else if let proxyUsage {
            lines.append("今日 Token：\(formattedInteger(proxyUsage.totalTokens))（代理）")
            lines.append("输入 \(formattedInteger(proxyUsage.inputTokens)) · 输出 \(formattedInteger(proxyUsage.outputTokens))")
        } else {
            lines.append("今日 Token：当前链路无统计")
        }

        if let proxyUsage {
            lines.append("今日代理请求：\(proxyUsage.requestCount)次")
        }
        if !snapshot.issues.isEmpty {
            lines.append("状态：部分降级 · \(snapshot.issues.joined(separator: "、"))")
        }
        return lines
    }

    static func deepSeekDetailLines(balance: ProviderBalance, proxyUsage: ProxyDailyUsage?) -> [String] {
        var lines = [
            "DeepSeek: 可用余额 \(balance.currencySymbol)\(balance.formattedTotal)",
            "充值余额 \(balance.currencySymbol)\(balance.formattedToppedUp) · 赠送余额 \(balance.currencySymbol)\(balance.formattedGranted)"
        ]
        if let proxyUsage {
            lines.append("今日代理 \(proxyUsage.requestCount) 次 · $\(String(format: "%.2f", proxyUsage.totalCostUSD))")
            lines.append(
                "今日 Token \(formattedInteger(proxyUsage.inputTokens + proxyUsage.outputTokens))（输入 \(formattedInteger(proxyUsage.inputTokens)) · 输出 \(formattedInteger(proxyUsage.outputTokens))）"
            )
        } else {
            lines.append("今日消费 / Token：当前直连链路无可核验统计")
        }
        return lines
    }

    static func summary(_ snapshot: CodexUsageSnapshot?) -> String {
        guard let snapshot else { return "Week -- · -- · --" }
        let percent = snapshot.weeklyWindow.map { String(format: "%.0f%%", $0.remainingPercent) } ?? "--"
        let reset = snapshot.weeklyWindow?.resetsAt.map(resetLabel) ?? "--"
        let credits = resetCreditLabel(snapshot.resetCredits.availableCount)
        return "Week \(percent) · \(reset) · \(credits)"
    }

    static func resetExpiryLine(index: Int, formattedExpiry: String) -> String {
        "Reset #\(index + 1) · Expires \(formattedExpiry)"
    }

    static func thirdPartySummary(balance: ProviderBalance?) -> String {
        guard let balance else { return "DeepSeek --" }
        return "DS \(balance.currencySymbol)\(balance.formattedTotal)"
    }

    static func providerSummary(snapshot: CodexUsageSnapshot?, balance: ProviderBalance?) -> String {
        var lines: [String] = []

        if let snapshot, snapshot.providerType.isOfficial || snapshot.weeklyWindow != nil {
            let percent = snapshot.weeklyWindow.map { String(format: "%.0f%%", $0.remainingPercent) } ?? "--"
            let reset = snapshot.weeklyWindow?.resetsAt.map(resetLabel) ?? "--"
            let credits = resetCreditLabel(snapshot.resetCredits.availableCount)
            lines.append("ChatGPT: Week \(percent) · \(reset) · \(credits)")
        }

        if let balance {
            lines.append("DeepSeek: \(balance.currencySymbol)\(balance.formattedTotal) (充值余额 \(balance.currencySymbol)\(balance.formattedToppedUp))")
        }

        return lines.isEmpty ? "暂无数据" : lines.joined(separator: "\n")
    }

    private static func resetLabel(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = fractional.date(from: value) ?? parser.date(from: value) else { return "--" }
        let secondsUntil = date.timeIntervalSinceNow
        if secondsUntil > 0, secondsUntil < 86_400 {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        return weekdayLabel(for: date)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func weekdayLabel(for date: Date) -> String {
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return symbols[Calendar.current.component(.weekday, from: date) - 1]
    }

    private static func resetCreditLabel(_ count: UInt64?) -> String {
        guard let count else { return "--" }
        return "\(count) \(count == 1 ? "Reset" : "Resets")"
    }

    private static func formattedInteger(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func compactTokenCount(_ value: Int) -> String {
        let units: [(threshold: Int, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K")
        ]
        guard let unit = units.first(where: { value >= $0.threshold }) else {
            return "\(value)"
        }

        let scaled = Double(value) / Double(unit.threshold)
        var number = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            scaled
        )
        while number.last == "0" { number.removeLast() }
        if number.last == "." { number.removeLast() }
        return number + unit.suffix
    }

    private static func formattedMoney(_ amount: Double, currency: String) -> String {
        MoneySnapshot(available: amount, currency: currency).formatted(amount)
    }

}
