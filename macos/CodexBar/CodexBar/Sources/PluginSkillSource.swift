import Foundation

struct PluginSkillSource {
    private let pluginRoot: URL
    private let skillRoot: URL
    private let configURL: URL
    private let fileManager: FileManager

    init(pluginRoot: URL? = nil, skillRoot: URL? = nil, configURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.pluginRoot = pluginRoot ?? home.appendingPathComponent(".codex/plugins/cache", isDirectory: true)
        self.skillRoot = skillRoot ?? home.appendingPathComponent(".codex/skills", isDirectory: true)
        self.configURL = configURL ?? home.appendingPathComponent(".codex/config.toml")
    }

    func scan() -> [PluginSkillEntry] {
        (plugins() + skills() + mcpServers()).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func plugins() -> [PluginSkillEntry] {
        let configured = configSections(prefix: "plugins.").map { name in
            PluginSkillEntry(id: "plugin:\(name)", kind: .plugin, name: name, detail: "已启用的 Codex 插件", path: configURL.path)
        }
        if !configured.isEmpty { return configured }
        return files(in: pluginRoot, named: "package.json").compactMap { url in
            guard let object = jsonObject(url), let name = object["name"] as? String, !name.isEmpty else { return nil }
            return PluginSkillEntry(id: url.path, kind: .plugin, name: name, detail: "已安装插件", path: url.deletingLastPathComponent().path)
        }
    }

    private func skills() -> [PluginSkillEntry] {
        files(in: skillRoot, named: "SKILL.md").compactMap { url in
            let header = frontmatter(url)
            let name = cleanMetadataValue(header["name"] ?? url.deletingLastPathComponent().lastPathComponent)
            guard !name.isEmpty else { return nil }
            return PluginSkillEntry(id: url.path, kind: .skill, name: name, detail: header["description"].map(cleanMetadataValue), path: url.path)
        }
    }

    private func mcpServers() -> [PluginSkillEntry] {
        configSections(prefix: "mcp_servers.").map { name in
            PluginSkillEntry(id: "mcp:\(name)", kind: .mcp, name: name, detail: "Codex MCP 服务器", path: configURL.path)
        }
    }

    private func configSections(prefix: String) -> [String] {
        guard let data = try? Data(contentsOf: configURL, options: [.mappedIfSafe]), data.count <= 1 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let marker = "[\(prefix)"
        return text.split(separator: "\n").compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix(marker), value.hasSuffix("]") else { return nil }
            return cleanMetadataValue(String(value.dropFirst(marker.count).dropLast()))
        }
        .filter { !$0.contains(".") }
        .sorted()
    }

    private func files(in root: URL, named name: String) -> [URL] {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == name }
    }

    private func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= 64 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func frontmatter(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024),
              let text = String(data: data, encoding: .utf8), text.hasPrefix("---\n") else { return [:] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        var values: [String: String] = [:]
        for line in lines {
            if line == "---" { break }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { values[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces) }
        }
        return values
    }

    private func cleanMetadataValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              (first == "\"" || first == "'"),
              trimmed.last == first else { return trimmed }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
