import Foundation

/// Finds only calendar dates for local Codex JSONL records with valid timestamps.
/// Event payloads and Token values are intentionally not read.
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

        var localRecordDays = Set<Date>()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  values.fileSize ?? 0 <= 16 * 1024 * 1024 else { continue }

            readLines(from: fileURL) { line in
                guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let timestamp = root["timestamp"] as? String,
                      let date = Self.date(from: timestamp) else { return }
                localRecordDays.insert(calendar.startOfDay(for: date))
            }
        }
        return TokenActivityStats(localRecordDays: localRecordDays.sorted())
    }

    private func readLines(from fileURL: URL, consume: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        var pending = Data()
        while let chunk = try? handle.read(upToCount: 4_096), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                consume(pending.prefix(upTo: newline))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { consume(pending) }
    }

    private static func date(from value: String) -> Date? {
        fractionalISO.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
