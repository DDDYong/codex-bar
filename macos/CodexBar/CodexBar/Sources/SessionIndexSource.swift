import Foundation

struct SessionIndexSource {
    private let activeRootURL: URL
    private let archivedRootURL: URL
    private let sessionIndexURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, sessionIndexURL: URL? = nil, fileManager: FileManager = .default) {
        let codexRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.activeRootURL = rootURL ?? codexRoot.appendingPathComponent("sessions", isDirectory: true)
        self.archivedRootURL = rootURL?
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
            ?? codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        self.sessionIndexURL = sessionIndexURL ?? codexRoot.appendingPathComponent("session_index.jsonl")
        self.fileManager = fileManager
    }

    init(activeRootURL: URL, archivedRootURL: URL, sessionIndexURL: URL? = nil, fileManager: FileManager = .default) {
        self.activeRootURL = activeRootURL
        self.archivedRootURL = archivedRootURL
        let codexRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.sessionIndexURL = sessionIndexURL ?? codexRoot.appendingPathComponent("session_index.jsonl")
        self.fileManager = fileManager
    }

    func scan() -> [SessionIndexEntry] {
        let titles = sessionTitles()
        return (scan(rootURL: activeRootURL, storage: .active, titles: titles)
            + scan(rootURL: archivedRootURL, storage: .archived, titles: titles))
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func scan(rootURL: URL, storage: SessionIndexEntry.Storage, titles: [String: String]) -> [SessionIndexEntry] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let fileURL = item as? URL,
                  fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let metadata = readMetadata(from: fileURL) else { return nil }
            return SessionIndexEntry(
                id: fileURL.path,
                threadID: metadata.id,
                title: metadata.id.flatMap { titles[$0] } ?? fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path,
                projectPath: metadata.projectPath,
                modifiedAt: modifiedAt,
                fileSize: Int64(values.fileSize ?? 0),
                storage: storage
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func readMetadata(from fileURL: URL) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n", omittingEmptySubsequences: true).first,
              let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        let payload = root["payload"] as? [String: Any]
        return Metadata(
            projectPath: payload?["cwd"] as? String ?? root["cwd"] as? String,
            id: payload?["id"] as? String ?? root["id"] as? String
        )
    }

    private func sessionTitles() -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: sessionIndexURL) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return [:] }
        return text.split(separator: "\n").reduce(into: [:]) { result, line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String else { return }
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { result[id] = cleaned }
        }
    }

    private struct Metadata {
        let projectPath: String?
        let id: String?
    }
}
