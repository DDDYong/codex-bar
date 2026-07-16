import Foundation

protocol SkillLifecycleManaging {
    func uninstall(_ entry: PluginSkillEntry) throws
}

enum SkillLifecycleError: LocalizedError {
    case notSkill
    case invalidSkillFile
    case skillFileMissing
    case invalidSkillPath

    var errorDescription: String? {
        switch self {
        case .notSkill:
            return "只能卸载 Skill。"
        case .invalidSkillFile:
            return "只能卸载包含 SKILL.md 的 Skill 目录。"
        case .skillFileMissing:
            return "要卸载的 Skill 文件不存在或不是普通文件。"
        case .invalidSkillPath:
            return "只能卸载 ~/.codex/skills 目录内的 Skill。"
        }
    }
}

struct SkillLifecycleSource: SkillLifecycleManaging {
    private let skillRootURL: URL
    private let fileManager: FileManager

    init(skillRootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.skillRootURL = skillRootURL ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills", isDirectory: true)
    }

    func uninstall(_ entry: PluginSkillEntry) throws {
        guard entry.kind == .skill else { throw SkillLifecycleError.notSkill }
        let skillFileURL = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().standardizedFileURL
        guard skillFileURL.lastPathComponent == "SKILL.md" else { throw SkillLifecycleError.invalidSkillFile }
        guard fileManager.fileExists(atPath: skillFileURL.path),
              (try? skillFileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw SkillLifecycleError.skillFileMissing
        }
        let directory = skillFileURL.deletingLastPathComponent()
        let root = skillRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard directory.path.hasPrefix(root + "/") else { throw SkillLifecycleError.invalidSkillPath }
        try fileManager.removeItem(at: directory)
    }
}
