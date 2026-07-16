import Foundation

/// Aggregates only timestamped token counters from local Codex event metadata.
/// Conversation text, tool arguments, and authentication data are never retained.
struct TokenActivitySource {
    private let rootURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar

    init(rootURL: URL? = nil, fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.rootURL = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func scan() -> TokenActivityStats {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        var dailyTotals: [Date: Int] = [:]
        var activeDays: Set<Date> = []
        var seenUsage: Set<String> = []
        var peakTokens = 0
        var longestDuration: TimeInterval = 0

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  values.fileSize ?? 0 <= 16 * 1024 * 1024,
                  let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var activityStartedAt: Date?
            var previousTimestamp: Date?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let timestamp = root["timestamp"] as? String,
                      let date = Self.date(from: timestamp) else { continue }

                activeDays.insert(calendar.startOfDay(for: date))
                if let previousTimestamp,
                   date.timeIntervalSince(previousTimestamp) > Self.activityGap {
                    if let activityStartedAt {
                        longestDuration = max(longestDuration, previousTimestamp.timeIntervalSince(activityStartedAt))
                    }
                    activityStartedAt = date
                } else if activityStartedAt == nil {
                    activityStartedAt = date
                }
                previousTimestamp = date
                guard let payload = root["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any],
                      let total = Self.integer(usage["total_tokens"]), total > 0 else { continue }

                let usageID = "\(timestamp)-\(total)"
                guard seenUsage.insert(usageID).inserted else { continue }
                dailyTotals[calendar.startOfDay(for: date), default: 0] += total
                peakTokens = max(peakTokens, total)
            }
            if let activityStartedAt, let previousTimestamp {
                longestDuration = max(longestDuration, previousTimestamp.timeIntervalSince(activityStartedAt))
            }
        }

        let daily = dailyTotals.map { TokenActivityDay(date: $0.key, totalTokens: $0.value) }
            .sorted { $0.date < $1.date }
        let activeDayList = activeDays.sorted()
        let streaks = Self.streaks(for: activeDayList, calendar: calendar)
        return TokenActivityStats(
            totalTokens: daily.reduce(0) { $0 + $1.totalTokens },
            peakTokens: peakTokens,
            longestSessionDuration: longestDuration,
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest,
            daily: daily,
            activeDays: activeDayList
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func date(from value: String) -> Date? {
        fractionalISO.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func streaks(for days: [Date], calendar: Calendar) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let sorted = days.sorted()
        var longest = 1
        var running = 1
        for index in 1..<sorted.count {
            if calendar.dateComponents([.day], from: sorted[index - 1], to: sorted[index]).day == 1 {
                running += 1
                longest = max(longest, running)
            } else {
                running = 1
            }
        }
        let today = calendar.startOfDay(for: Date())
        let last = sorted.last!
        guard calendar.dateComponents([.day], from: last, to: today).day ?? 2 <= 1 else { return (0, longest) }
        var current = 1
        for index in stride(from: sorted.count - 1, through: 1, by: -1) {
            guard calendar.dateComponents([.day], from: sorted[index - 1], to: sorted[index]).day == 1 else { break }
            current += 1
        }
        return (current, longest)
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let activityGap: TimeInterval = 20 * 60
}
