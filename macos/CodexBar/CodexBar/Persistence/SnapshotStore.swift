import Foundation

final class SnapshotStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Bar/usage-snapshots.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [UsageSnapshotRecord] {
        guard let data = try? Data(contentsOf: fileURL), let records = try? decoder.decode([UsageSnapshotRecord].self, from: data) else { return [] }
        return records.sorted { $0.capturedAt < $1.capturedAt }
    }

    func append(_ record: UsageSnapshotRecord, retentionDays: Int = 90) throws {
        var records = load()
        if let last = records.last,
           abs(last.weeklyRemainingPercent - record.weeklyRemainingPercent) < 0.01,
           last.shortRemainingPercent == record.shortRemainingPercent,
           last.resetCredits == record.resetCredits {
            return
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        records = records.filter { $0.capturedAt >= cutoff }
        records.append(record)
        try save(records)
    }

    func clear() throws { try save([]) }
    func export() throws -> Data { try encoder.encode(load()) }

    private func save(_ records: [UsageSnapshotRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records.sorted { $0.capturedAt < $1.capturedAt }).write(to: fileURL, options: .atomic)
    }
}
