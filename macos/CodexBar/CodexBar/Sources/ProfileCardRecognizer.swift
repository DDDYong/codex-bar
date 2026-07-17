import AppKit
import Foundation
import Vision

protocol ProfileCardRecognizing {
    func recognize(imageData: Data) throws -> ProfileSnapshotDraft
}

final class ProfileCardRecognizer: ProfileCardRecognizing {
    func recognize(imageData: Data) throws -> ProfileSnapshotDraft {
        guard NSImage(data: imageData) != nil else {
            throw ProfileCardRecognizerError.invalidImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])

        let lines = request.results?.compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedLine(text: text, x: observation.boundingBox.midX, y: observation.boundingBox.midY)
        } ?? []
        return try Self.parse(recognizedLines: lines)
    }

    static func parse(lines: [String]) throws -> ProfileSnapshotDraft {
        ProfileSnapshotDraft(
            totalTokens: numberAdjacent(toAnyOf: ["累计 Token"], in: lines),
            peakDayTokens: numberAdjacent(toAnyOf: ["峰值 Token", "峰值日"], in: lines),
            longestTaskDurationSeconds: durationAdjacent(toAnyOf: ["最长任务"], in: lines),
            currentStreakDays: numberAdjacent(toAnyOf: ["当前连续"], in: lines),
            longestStreakDays: numberAdjacent(toAnyOf: ["最长连续"], in: lines)
        )
    }

    static func parseNumber(_ text: String) -> Int? {
        let normalized = text.replacingOccurrences(of: ",", with: "")
        let multiplier = normalized.contains("亿") ? 100_000_000 : normalized.contains("万") ? 10_000 : 1
        let digits = normalized
            .replacingOccurrences(of: "亿", with: "")
            .replacingOccurrences(of: "万", with: "")
            .replacingOccurrences(of: "天", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(digits) else { return nil }
        return Int((value * Double(multiplier)).rounded())
    }

    static func parseDuration(_ text: String) -> Int? {
        let normalized = text.lowercased().replacingOccurrences(of: " ", with: "")
        let values = normalized.matches(of: /\d+(?:\.\d+)?/).compactMap { Double($0.output) }
        guard !values.isEmpty else { return nil }

        let hasHours = normalized.contains("小时") || normalized.contains("hour") || normalized.contains("hr")
        let hasMinutes = normalized.contains("分") || normalized.contains("minute") || normalized.contains("min")
        var seconds = 0.0
        var valueIndex = 0
        if hasHours {
            seconds += values[valueIndex] * 3_600
            valueIndex += 1
        }
        if hasMinutes, values.indices.contains(valueIndex) {
            seconds += values[valueIndex] * 60
        } else if !hasHours {
            return nil
        }
        return Int(seconds.rounded())
    }

    static func parse(recognizedLines: [RecognizedLine]) -> ProfileSnapshotDraft {
        ProfileSnapshotDraft(
            totalTokens: numberNearest(toAnyOf: ["累计 Token"], in: recognizedLines),
            peakDayTokens: numberNearest(toAnyOf: ["峰值 Token", "峰值日"], in: recognizedLines),
            longestTaskDurationSeconds: durationNearest(toAnyOf: ["最长任务"], in: recognizedLines),
            currentStreakDays: numberNearest(toAnyOf: ["当前连续"], in: recognizedLines),
            longestStreakDays: numberNearest(toAnyOf: ["最长连续"], in: recognizedLines)
        )
    }

    private static func numberAdjacent(toAnyOf labels: [String], in lines: [String]) -> Int? {
        guard let labelIndex = lines.firstIndex(where: { line in labels.contains { line.contains($0) } }) else { return nil }

        for index in [labelIndex - 1, labelIndex + 1] where lines.indices.contains(index) {
            if let value = parseNumber(lines[index]) {
                return value
            }
        }
        return nil
    }

    private static func numberNearest(toAnyOf labels: [String], in lines: [RecognizedLine]) -> Int? {
        guard let label = lines.first(where: { line in labels.contains { line.text.contains($0) } }) else { return nil }

        return lines
            .compactMap { line -> (value: Int, distance: Double)? in
                guard let value = parseNumber(line.text) else { return nil }
                let horizontal = line.x - label.x
                let vertical = line.y - label.y
                return (value, horizontal * horizontal + vertical * vertical)
            }
            .min(by: { $0.distance < $1.distance })?
            .value
    }

    private static func durationAdjacent(toAnyOf labels: [String], in lines: [String]) -> Int? {
        guard let labelIndex = lines.firstIndex(where: { line in labels.contains { line.contains($0) } }) else { return nil }

        for index in [labelIndex - 1, labelIndex + 1] where lines.indices.contains(index) {
            if let value = parseDuration(lines[index]) {
                return value
            }
        }
        return nil
    }

    private static func durationNearest(toAnyOf labels: [String], in lines: [RecognizedLine]) -> Int? {
        guard let label = lines.first(where: { line in labels.contains { line.text.contains($0) } }) else { return nil }

        return lines
            .compactMap { line -> (value: Int, distance: Double)? in
                guard let value = parseDuration(line.text) else { return nil }
                let horizontal = line.x - label.x
                let vertical = line.y - label.y
                return (value, horizontal * horizontal + vertical * vertical)
            }
            .min(by: { $0.distance < $1.distance })?
            .value
    }
}

struct RecognizedLine {
    let text: String
    let x: Double
    let y: Double
}

enum ProfileCardRecognizerError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "无法识别图片"
    }
}

struct CodexActivitySummary: Equatable {
    let lifetimeTokens: Int
    let peakDailyTokens: Int
    let longestRunningTurnSeconds: Int?
    let currentStreakDays: Int
    let longestStreakDays: Int
    let dailyUsageBuckets: [TokenActivityDay]
}

protocol CodexActivityReading {
    func fetchSummary() async throws -> CodexActivitySummary
}

enum CodexActivityError: LocalizedError, Equatable {
    case codexUnavailable
    case timedOut
    case invalidResponse
    case unsupported

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: "未找到可用的 Codex CLI，请在终端执行 codex update 后重试。"
        case .timedOut: "读取全设备 Token 活动超时，请稍后重试。"
        case .invalidResponse: "Codex CLI 返回的 Token 活动数据格式已变化。"
        case .unsupported: "当前 Codex CLI 不支持读取全设备 Token 活动，请更新后重试。"
        }
    }
}

final class CodexActivitySource: CodexActivityReading {
    private static let timeout: TimeInterval = 12
    private let fileManager: FileManager
    private let environment: [String: String]

    init(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func fetchSummary() async throws -> CodexActivitySummary {
        let executable = try resolveCodexExecutable()
        return try await Task.detached(priority: .utility) { [environment] in
            try Self.readSummary(executableURL: executable, environment: environment)
        }.value
    }

    static func parseSummary(from payload: Data) throws -> CodexActivitySummary {
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let summary = root["summary"] as? [String: Any],
              let lifetimeTokens = nonnegativeInt(summary["lifetimeTokens"]),
              let peakDailyTokens = nonnegativeInt(summary["peakDailyTokens"]),
              let currentStreakDays = nonnegativeInt(summary["currentStreakDays"]),
              let longestStreakDays = nonnegativeInt(summary["longestStreakDays"]) else {
            throw CodexActivityError.invalidResponse
        }

        return CodexActivitySummary(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakDailyTokens,
            longestRunningTurnSeconds: nonnegativeInt(summary["longestRunningTurnSec"]),
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            dailyUsageBuckets: parseDailyUsageBuckets(root["dailyUsageBuckets"])
        )
    }

    private func resolveCodexExecutable() throws -> URL {
        let configured = environment["CODEX_BIN"].map(URL.init(fileURLWithPath:))
        let common = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"].map(URL.init(fileURLWithPath:))
        let nvmRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvmCandidates = (try? fileManager.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/codex") } ?? []

        guard let executable = ([configured].compactMap { $0 } + common + nvmCandidates)
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw CodexActivityError.codexUnavailable
        }
        return executable
    }

    private static func readSummary(executableURL: URL, environment: [String: String]) throws -> CodexActivitySummary {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let completionQueue = DispatchQueue(label: "app.codexbar.activity-source")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CodexActivitySummary, Error>?
        var buffer = Data()
        var didSendRequest = false

        func finish(_ value: Result<CodexActivitySummary, Error>) {
            completionQueue.sync {
                guard result == nil else { return }
                result = value
                process.terminate()
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
        process.standardError = error

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
                    Self.writeJSON(["jsonrpc": "2.0", "method": "initialized", "params": [:]], to: input.fileHandleForWriting)
                    Self.writeJSON(["jsonrpc": "2.0", "id": 2, "method": "account/usage/read", "params": [:]], to: input.fileHandleForWriting)
                } else if identifier == 2 {
                    if message["error"] != nil {
                        finish(.failure(CodexActivityError.unsupported))
                    } else if let payload = try? JSONSerialization.data(withJSONObject: message["result"] ?? [:]) {
                        finish(Result { try parseSummary(from: payload) })
                    } else {
                        finish(.failure(CodexActivityError.invalidResponse))
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw CodexActivityError.codexUnavailable
        }

        let timeout = DispatchWorkItem { finish(.failure(CodexActivityError.timedOut)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
        writeJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "codex-bar", "version": "1.0"], "capabilities": [:]]
        ], to: input.fileHandleForWriting)
        semaphore.wait()
        timeout.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        error.fileHandleForReading.closeFile()
        guard let result else { throw CodexActivityError.invalidResponse }
        return try result.get()
    }

    private static func writeJSON(_ object: [String: Any], to handle: FileHandle) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.doubleValue >= 0, number.doubleValue <= Double(Int.max) else { return nil }
        return Int(number.doubleValue)
    }

    private static func parseDailyUsageBuckets(_ value: Any?) -> [TokenActivityDay] {
        guard let buckets = value as? [[String: Any]] else { return [] }
        return buckets.compactMap { bucket in
            guard let startDate = bucket["startDate"] as? String,
                  let tokens = nonnegativeInt(bucket["tokens"]),
                  startDate.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/) != nil else { return nil }
            return TokenActivityDay(startDate: startDate, tokens: tokens)
        }
    }
}
