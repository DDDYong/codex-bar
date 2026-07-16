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
        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])

        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return try Self.parse(lines: lines)
    }

    static func parse(lines: [String]) throws -> ProfileSnapshotDraft {
        ProfileSnapshotDraft(
            totalTokens: numberAdjacent(to: "累计 Token", in: lines),
            peakDayTokens: numberAdjacent(to: "峰值日", in: lines),
            currentStreakDays: numberAdjacent(to: "当前连续天数", in: lines),
            longestStreakDays: numberAdjacent(to: "最长连续", in: lines)
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

    private static func numberAdjacent(to label: String, in lines: [String]) -> Int? {
        guard let labelIndex = lines.firstIndex(where: { $0.contains(label) }) else { return nil }

        for index in [labelIndex - 1, labelIndex + 1] where lines.indices.contains(index) {
            if let value = parseNumber(lines[index]) {
                return value
            }
        }
        return nil
    }
}

enum ProfileCardRecognizerError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "无法识别图片"
    }
}
