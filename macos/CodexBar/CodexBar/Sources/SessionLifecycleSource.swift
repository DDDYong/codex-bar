import Foundation

protocol SessionLifecycleManaging {
    func archive(_ entry: SessionIndexEntry) throws
    func unarchive(_ entry: SessionIndexEntry) throws
    func delete(_ entry: SessionIndexEntry) throws
}

protocol SessionCommandRunning {
    func run(executable: String, arguments: [String]) throws -> SessionCommandResult
}

struct SessionCommandResult {
    let status: Int32
    let standardError: String
}

enum SessionLifecycleError: LocalizedError {
    case missingThreadID
    case commandFailed(operation: String, status: Int32, standardError: String)
    case invalidDeletionPath
    case deletionFileMissing
    case deletionFileNotJSONL

    var errorDescription: String? {
        switch self {
        case .missingThreadID:
            return "该会话没有可用于生命周期操作的 thread ID。"
        case let .commandFailed(operation, status, standardError):
            let details = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return details.isEmpty
                ? "Codex \(operation) 命令失败（退出码 \(status)）。"
                : "Codex \(operation) 命令失败（退出码 \(status)）：\(details)"
        case .invalidDeletionPath:
            return "只能删除活动或已归档会话目录内的文件。"
        case .deletionFileMissing:
            return "要删除的会话文件不存在或不是普通文件。"
        case .deletionFileNotJSONL:
            return "只能删除 .jsonl 会话文件。"
        }
    }
}

struct SessionLifecycleSource: SessionLifecycleManaging {
    private let activeRootURL: URL
    private let archivedRootURL: URL
    private let commandRunner: SessionCommandRunning
    private let fileManager: FileManager

    init(
        activeRootURL: URL? = nil,
        archivedRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let codexRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.activeRootURL = activeRootURL ?? codexRoot.appendingPathComponent("sessions", isDirectory: true)
        self.archivedRootURL = archivedRootURL ?? codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        self.commandRunner = ProcessSessionCommandRunner()
        self.fileManager = fileManager
    }

    init(
        activeRootURL: URL? = nil,
        archivedRootURL: URL? = nil,
        commandRunner: SessionCommandRunning,
        fileManager: FileManager = .default
    ) {
        let codexRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.activeRootURL = activeRootURL ?? codexRoot.appendingPathComponent("sessions", isDirectory: true)
        self.archivedRootURL = archivedRootURL ?? codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func archive(_ entry: SessionIndexEntry) throws {
        try run(operation: "archive", entry: entry)
    }

    func unarchive(_ entry: SessionIndexEntry) throws {
        do {
            try run(operation: "unarchive", entry: entry)
        } catch {
            // Some Codex CLI versions move the JSONL back to sessions before
            // returning a nonzero exit status for the stale active-path state.
            guard restoredToActiveSessions(entry) else { throw error }
        }
    }

    func delete(_ entry: SessionIndexEntry) throws {
        let fileURL = URL(fileURLWithPath: entry.filePath).resolvingSymlinksInPath().standardizedFileURL
        guard fileURL.pathExtension == "jsonl" else { throw SessionLifecycleError.deletionFileNotJSONL }
        guard fileManager.fileExists(atPath: fileURL.path),
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw SessionLifecycleError.deletionFileMissing
        }
        guard isWithinConfiguredRoot(fileURL, rootURL: activeRootURL)
                || isWithinConfiguredRoot(fileURL, rootURL: archivedRootURL) else {
            throw SessionLifecycleError.invalidDeletionPath
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func run(operation: String, entry: SessionIndexEntry) throws {
        guard let threadID = entry.threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty else {
            throw SessionLifecycleError.missingThreadID
        }
        let result = try commandRunner.run(executable: "/usr/bin/env", arguments: ["codex", operation, threadID])
        guard result.status == 0 else {
            throw SessionLifecycleError.commandFailed(operation: operation, status: result.status, standardError: result.standardError)
        }
    }

    private func isWithinConfiguredRoot(_ fileURL: URL, rootURL: URL) -> Bool {
        let normalizedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return fileURL.path.hasPrefix(normalizedRoot + "/")
    }

    private func restoredToActiveSessions(_ entry: SessionIndexEntry) -> Bool {
        guard entry.storage == .archived,
              !fileManager.fileExists(atPath: entry.filePath) else { return false }
        let fileName = URL(fileURLWithPath: entry.filePath).lastPathComponent
        guard let enumerator = fileManager.enumerator(
            at: activeRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return enumerator.contains { item in
            guard let fileURL = item as? URL,
                  fileURL.lastPathComponent == fileName,
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }
    }
}

private struct ProcessSessionCommandRunner: SessionCommandRunning {
    func run(executable: String, arguments: [String]) throws -> SessionCommandResult {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        return SessionCommandResult(
            status: process.terminationStatus,
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
