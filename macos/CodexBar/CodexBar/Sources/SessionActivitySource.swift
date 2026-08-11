import Foundation

protocol SessionActivityReading {
    func liveActivities() -> ProviderActivitySnapshot
}

final class SessionActivitySource: SessionActivityReading {
    struct Root {
        let url: URL
        let providerHint: ProviderType?
    }

    private let fileManager: FileManager
    private let roots: [Root]
    private let now: () -> Date
    private let liveEventWindow: TimeInterval
    private let terminalEventWindow: TimeInterval
    private let cacheLock = NSLock()
    private var parseCache: [String: CachedActivity] = [:]

    private struct SessionFile {
        let url: URL
        let modifiedAt: Date
        let size: Int
    }

    private struct CachedActivity {
        let modifiedAt: Date
        let size: Int
        let providerType: ProviderType
        let activity: SessionActivity
    }

    init(
        fileManager: FileManager = .default,
        roots: [Root]? = nil,
        now: @escaping () -> Date = Date.init,
        liveEventWindow: TimeInterval = 180,
        terminalEventWindow: TimeInterval = 15 * 60
    ) {
        self.fileManager = fileManager
        self.now = now
        self.liveEventWindow = liveEventWindow
        self.terminalEventWindow = terminalEventWindow

        if let roots {
            self.roots = roots
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.roots = [
                Root(url: home.appendingPathComponent(".codex/sessions", isDirectory: true), providerHint: nil),
                Root(url: home.appendingPathComponent(".codex-deepseek/sessions", isDirectory: true), providerHint: .deepseek),
                Root(url: home.appendingPathComponent(".codex-openai/sessions", isDirectory: true), providerHint: .officialCodex)
            ]
        }
    }

    func liveActivities() -> ProviderActivitySnapshot {
        let observedAt = now()
        var statusesByProvider: [ProviderType: [SessionActivity]] = [:]
        var visitedPaths = Set<String>()

        for root in roots {
            for file in recentSessionFiles(in: root.url, observedAt: observedAt)
            where visitedPaths.insert(file.url.standardizedFileURL.path).inserted {
                guard let record = activityRecord(
                    from: file,
                    providerHint: root.providerHint,
                    observedAt: observedAt
                ) else { continue }
                statusesByProvider[record.providerType, default: []].append(record.activity)
            }
        }
        pruneCache(keeping: visitedPaths)

        if statusesByProvider.isEmpty {
            statusesByProvider[.officialCodex] = [hookFallbackActivity()]
        }

        return ProviderActivitySnapshot(
            activities: statusesByProvider.mapValues(SessionActivity.aggregate)
        )
    }

    func liveActivity() -> SessionActivity {
        liveActivities().aggregate
    }

    private func recentSessionFiles(in directory: URL, observedAt: Date) -> [SessionFile] {
        candidateDirectories(in: directory, observedAt: observedAt).flatMap { candidate in
            let files = (try? fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return files.compactMap { file -> SessionFile? in
            guard file.pathExtension == "jsonl" else { return nil }
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else { return nil }
            let age = observedAt.timeIntervalSince(modifiedAt)
            guard age >= -60, age <= terminalEventWindow else { return nil }
            return SessionFile(url: file, modifiedAt: modifiedAt, size: values.fileSize ?? 0)
            }
        }
    }

    private func candidateDirectories(in root: URL, observedAt: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dates = [
            observedAt,
            observedAt.addingTimeInterval(-terminalEventWindow)
        ]
        var directories = [root]
        var seen = Set([root.standardizedFileURL.path])
        for date in dates {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            if seen.insert(directory.standardizedFileURL.path).inserted {
                directories.append(directory)
            }
        }
        return directories
    }

    private func activityRecord(
        from file: SessionFile,
        providerHint: ProviderType?,
        observedAt: Date
    ) -> (providerType: ProviderType, activity: SessionActivity)? {
        let path = file.url.standardizedFileURL.path
        let cached = cachedActivity(for: path, matching: file)
        let parsed: CachedActivity
        if let cached {
            parsed = cached
        } else {
            guard let fragments = readMetadataAndEventTail(from: file.url) else { return nil }
            let providerType = providerHint ?? providerType(from: fragments.metadataLines + fragments.eventLines)
            let eventTypes = fragments.eventLines.compactMap(eventType)
            parsed = CachedActivity(
                modifiedAt: file.modifiedAt,
                size: file.size,
                providerType: providerType,
                activity: SessionActivity.from(eventTypes: eventTypes)
            )
            storeCachedActivity(parsed, for: path)
        }

        var activity = parsed.activity
        if activity.isConsuming, observedAt.timeIntervalSince(file.modifiedAt) > liveEventWindow {
            activity = .unknown
        }
        guard activity != .unknown else { return nil }
        return (parsed.providerType, activity)
    }

    private func cachedActivity(for path: String, matching file: SessionFile) -> CachedActivity? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = parseCache[path],
              cached.modifiedAt == file.modifiedAt,
              cached.size == file.size else { return nil }
        return cached
    }

    private func storeCachedActivity(_ activity: CachedActivity, for path: String) {
        cacheLock.lock()
        parseCache[path] = activity
        cacheLock.unlock()
    }

    private func pruneCache(keeping paths: Set<String>) {
        cacheLock.lock()
        parseCache = parseCache.filter { paths.contains($0.key) }
        cacheLock.unlock()
    }

    private func readMetadataAndEventTail(from file: URL) -> (metadataLines: [Substring], eventLines: [Substring])? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        do {
            let prefixData = try handle.read(upToCount: 64 * 1024) ?? Data()
            let endOffset = try handle.seekToEnd()
            let tailStart = endOffset > 256 * 1024 ? endOffset - 256 * 1024 : 0
            try handle.seek(toOffset: tailStart)
            let tailData = try handle.readToEnd() ?? Data()

            return (
                metadataLines: Array(completeLines(
                    from: prefixData,
                    dropLeadingPartialLine: false,
                    dropTrailingPartialLine: endOffset > UInt64(prefixData.count)
                ).prefix(80)),
                eventLines: Array(completeLines(
                    from: tailData,
                    dropLeadingPartialLine: tailStart > 0,
                    dropTrailingPartialLine: false
                ).suffix(300))
            )
        } catch {
            return nil
        }
    }

    private func completeLines(
        from data: Data,
        dropLeadingPartialLine: Bool,
        dropTrailingPartialLine: Bool
    ) -> [Substring] {
        var completeData = data
        if dropLeadingPartialLine {
            guard let newline = completeData.firstIndex(of: 0x0A) else { return [] }
            completeData.removeSubrange(completeData.startIndex...newline)
        }
        if dropTrailingPartialLine {
            guard let newline = completeData.lastIndex(of: 0x0A) else { return [] }
            let trailingStart = completeData.index(after: newline)
            completeData.removeSubrange(trailingStart..<completeData.endIndex)
        }
        return String(decoding: completeData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func providerType(from lines: [Substring]) -> ProviderType {
        var providerMarkers: [String] = []

        for line in lines {
            guard let object = jsonObject(from: line),
                  let payload = object["payload"] as? [String: Any] else { continue }
            if object["type"] as? String == "session_meta" {
                providerMarkers.append(contentsOf: strings(in: payload, keys: ["model_provider", "agent_role", "agent_nickname"]))
            } else if object["type"] as? String == "turn_context" {
                providerMarkers.append(contentsOf: strings(in: payload, keys: ["model_provider", "model", "agent_role"]))
            }
        }

        if providerMarkers.contains(where: { $0.localizedCaseInsensitiveContains("deepseek") }) {
            return .deepseek
        }
        if providerMarkers.contains(where: { $0.localizedCaseInsensitiveContains("openrouter") }) {
            return .openRouter
        }
        if providerMarkers.contains(where: {
            $0.localizedCaseInsensitiveContains("siliconflow")
                || $0.localizedCaseInsensitiveContains("silicon flow")
        }) {
            return .siliconFlow
        }
        if let providerID = ProviderID.fromCCSwitch(
            name: providerMarkers.joined(separator: " "),
            providerType: nil
        ), providerID.isExperimental {
            return providerID.providerType
        }
        return .officialCodex
    }

    private func eventType(from line: Substring) -> String? {
        guard let object = jsonObject(from: line),
              let payload = object["payload"] as? [String: Any] else { return nil }
        if payload["name"] as? String == "request_user_input" {
            return "request_user_input"
        }
        guard let type = payload["type"] as? String else { return nil }
        let recognized = SessionActivity.from(eventTypes: [type])
        return recognized == .unknown ? nil : type
    }

    private func jsonObject(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func strings(in object: [String: Any], keys: [String]) -> [String] {
        keys.compactMap { object[$0] as? String }
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
