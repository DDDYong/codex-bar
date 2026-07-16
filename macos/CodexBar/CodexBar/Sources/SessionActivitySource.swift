import Foundation

struct SessionActivitySource {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func liveActivity() -> SessionActivity {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let statuses = sessionStatuses(in: root)
        if !statuses.isEmpty { return SessionActivity.aggregate(statuses) }
        return hookFallbackActivity()
    }

    private func sessionStatuses(in directory: URL) -> [SessionActivity] {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return []
        }
        var statuses: [SessionActivity] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard isRecent(file), let activity = activity(from: file) else { continue }
            statuses.append(activity)
        }
        return statuses
    }

    private func isRecent(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else { return false }
        return Date().timeIntervalSince(modified) <= 15 * 60
    }

    private func activity(from file: URL) -> SessionActivity? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let eventTypes = contents.split(separator: "\n").suffix(200).compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { return nil }
            if payload["name"] as? String == "request_user_input" { return "request_user_input" }
            return type
        }
        let activity = SessionActivity.from(eventTypes: eventTypes)
        return activity == .unknown ? nil : activity
    }

    private func hookFallbackActivity() -> SessionActivity {
        let file = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-bar/session-status.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["sessions"] != nil,
              let state = root["state"] as? String else { return .unknown }
        return SessionActivity(rawValue: state) ?? .unknown
    }
}
