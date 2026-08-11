# Skill Uninstall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow a user to safely uninstall an installed local Skill from its detail dialog.

**Architecture:** A small filesystem lifecycle service removes only a verified Skill directory below `~/.codex/skills`. `AppState` injects and serializes that service, then refreshes the index; the existing detail sheet supplies confirmation, progress, and error UI.

**Tech Stack:** Swift 5, SwiftUI, Foundation FileManager, XCTest, macOS 13.

## Global Constraints

- Only `PluginSkillEntry.Kind.skill` may be removed; plugin and MCP entries never show an uninstall action.
- Only a normalized `SKILL.md` file below normalized `~/.codex/skills/` may lead to deletion.
- Require explicit confirmation in the detail sheet before deleting the Skill directory.
- Do not read, display, store, log, or export Skill body content.
- Do not add third-party dependencies.
- On success refresh the Skill index; on failure leave the dialog open with its error.

---

## File Structure

- `macos/CodexBar/CodexBar/Sources/SkillLifecycleSource.swift` — protected filesystem deletion boundary.
- `macos/CodexBar/CodexBar/App/AppState.swift` — injection, operation state, errors, reindex.
- `macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift` — confirmation and operation UI.
- `macos/CodexBar/CodexBarTests/CodexBarTests.swift` — lifecycle and state tests.
- `macos/CodexBar/CodexBar.xcodeproj/project.pbxproj` — application target source registration.
- `docs/CODEX_DASHBOARD_PRODUCT_AND_IMPLEMENTATION_PLAN.md` — permanent boundary update.

### Task 1: Add protected Skill lifecycle service

**Files:**
- Create: `macos/CodexBar/CodexBar/Sources/SkillLifecycleSource.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`
- Modify: `macos/CodexBar/CodexBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces `protocol SkillLifecycleManaging { func uninstall(_ entry: PluginSkillEntry) throws }`.
- Produces `SkillLifecycleSource(skillRootURL:fileManager:)` and `SkillLifecycleError: LocalizedError`.

- [ ] **Step 1: Write failing lifecycle tests**

Add tests for: valid Skill removal; a `.plugin` entry rejection; a `SKILL.md` outside the configured root rejection; a `README.md` inside the root rejection; and a missing `SKILL.md` rejection. Use a temporary root and this helper:

```swift
private func skillEntry(fileURL: URL) -> PluginSkillEntry {
    PluginSkillEntry(id: fileURL.path, kind: .skill, name: "review", detail: nil, path: fileURL.path)
}
```

The success test creates `root/skills/review/SKILL.md`, calls `uninstall`, then asserts `root/skills/review` no longer exists. Every rejection test asserts the target file remains.

- [ ] **Step 2: Verify the tests fail before implementation**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testUninstallSkillRemovesVerifiedSkillDirectory
```

Expected: build failure because `SkillLifecycleSource` does not exist.

- [ ] **Step 3: Implement the lifecycle service and register it with Xcode**

Create this service, keeping every error user-readable:

```swift
import Foundation

protocol SkillLifecycleManaging {
    func uninstall(_ entry: PluginSkillEntry) throws
}

enum SkillLifecycleError: LocalizedError {
    case notSkill, invalidSkillFile, skillFileMissing, invalidSkillPath
    var errorDescription: String? {
        switch self {
        case .notSkill: "只能卸载 Skill。"
        case .invalidSkillFile: "只能卸载包含 SKILL.md 的 Skill 目录。"
        case .skillFileMissing: "要卸载的 Skill 文件不存在或不是普通文件。"
        case .invalidSkillPath: "只能卸载 ~/.codex/skills 目录内的 Skill。"
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
```

Use the existing `SessionLifecycleSource.swift` project-file pattern to add the new file reference, Sources-group child, build-file entry, and application Sources-phase entry.

- [ ] **Step 4: Run all lifecycle tests**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests
```

Expected: exit code 0 and all lifecycle tests pass.

- [ ] **Step 5: Commit the lifecycle boundary**

```sh
git add macos/CodexBar/CodexBar/Sources/SkillLifecycleSource.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift macos/CodexBar/CodexBar.xcodeproj/project.pbxproj
git commit -m "feat: add protected skill uninstall service"
```

### Task 2: Connect AppState and the Skill detail dialog

**Files:**
- Modify: `macos/CodexBar/CodexBar/App/AppState.swift`
- Modify: `macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`

**Interfaces:**
- Consumes `SkillLifecycleManaging.uninstall(_:)`.
- Produces `AppState.uninstallSkill(_:) async`, `skillOperationEntryID`, `skillOperationError`, and `isOperatingOnSkill`.

- [ ] **Step 1: Write failing AppState tests**

Add a `RecordingSkillLifecycleSource` fake that records entry IDs and can throw `TestLifecycleError.failed`. Add tests that call `await state.uninstallSkill(entry)` and assert, respectively, successful ID recording with nil state/error and error text with cleared state.

```swift
private final class RecordingSkillLifecycleSource: SkillLifecycleManaging {
    private(set) var uninstalledEntryIDs: [String] = []
    private let error: Error?
    init(error: Error? = nil) { self.error = error }
    func uninstall(_ entry: PluginSkillEntry) throws {
        if let error { throw error }
        uninstalledEntryIDs.append(entry.id)
    }
}
```

- [ ] **Step 2: Verify the new AppState test fails**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testUninstallSkillRefreshesIndexAfterSuccessfulLifecycleOperation
```

Expected: build failure because Skill lifecycle injection and `uninstallSkill` do not exist.

- [ ] **Step 3: Add mutually exclusive Skill operation ownership**

Inject `skillLifecycleSource: SkillLifecycleManaging = SkillLifecycleSource()` in `AppState`. Add this operation next to the existing session operation methods:

```swift
@Published private(set) var skillOperationError: String?
@Published private(set) var skillOperationEntryID: String?

var isOperatingOnSkill: Bool { skillOperationEntryID != nil }

func uninstallSkill(_ entry: PluginSkillEntry) async {
    guard skillOperationEntryID == nil else { return }
    skillOperationEntryID = entry.id
    skillOperationError = nil
    do {
        try skillLifecycleSource.uninstall(entry)
        refreshPluginSkillIndex()
    } catch {
        skillOperationError = error.localizedDescription
    }
    skillOperationEntryID = nil
}
```

- [ ] **Step 4: Add the detail-sheet confirmation and feedback UI**

In `PluginSkillDetailSheet`, add `@EnvironmentObject private var appState: AppState` and `@State private var showsUninstallConfirmation = false`. For Skills only, place this before the existing close button:

```swift
Button("卸载 Skill", role: .destructive) { showsUninstallConfirmation = true }
    .disabled(appState.isOperatingOnSkill)
    .confirmationDialog("卸载 \(entry.name)？", isPresented: $showsUninstallConfirmation, titleVisibility: .visible) {
        Button("卸载", role: .destructive) {
            Task {
                await appState.uninstallSkill(entry)
                if appState.skillOperationError == nil { dismiss() }
            }
        }
        Button("取消", role: .cancel) {}
    } message: {
        Text("将永久删除 \(entry.path.deletingLastPathComponent)。")
    }
```

When `skillOperationEntryID == entry.id`, use `ProgressView()` as the button label. Render `Text("Skill 卸载失败：\(error)")` above the sheet spacer in orange caption styling when `skillOperationError` is non-nil. Do not render any uninstall control for Plugin or MCP entries.

- [ ] **Step 5: Run automated and manual verification**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test
```

Expected: both commands exit 0. Launch from Xcode and verify: Plugin/MCP detail sheets lack the action; cancel leaves a Skill intact; confirmation removes a valid Skill and closes the sheet; invalid state displays the error without closing.

- [ ] **Step 6: Commit AppState and UI integration**

```sh
git add macos/CodexBar/CodexBar/App/AppState.swift macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift
git commit -m "feat: add skill uninstall detail action"
```

### Task 3: Document the explicit protected deletion boundary

**Files:**
- Modify: `docs/CODEX_DASHBOARD_PRODUCT_AND_IMPLEMENTATION_PLAN.md`

**Interfaces:**
- Consumes verified behavior from Tasks 1–2.
- Produces an accurate permanent local-Skill boundary.

- [ ] **Step 1: Replace the unconditional Skills restriction**

Update the permanent product boundary to include this exact policy, retaining all neighboring protections:

```markdown
- 默认只读 Codex 本地数据；仅允许用户在“插件与 Skills”详情弹窗明确确认后，卸载满足路径保护规则的本地 Skill。不得修改插件、MCP、Codex 认证、会话或内部数据库。
```

- [ ] **Step 2: Verify the documentation and diff**

Run:

```sh
rg -n "卸载|只读 Codex 本地数据|Skill" docs/CODEX_DASHBOARD_PRODUCT_AND_IMPLEMENTATION_PLAN.md macos/CodexBar/CodexBar/Sources/SkillLifecycleSource.swift macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift
git diff --check
```

Expected: output shows explicit confirmation and protected Skill-only deletion; `git diff --check` produces no output.

- [ ] **Step 3: Commit the boundary update**

```sh
git add docs/CODEX_DASHBOARD_PRODUCT_AND_IMPLEMENTATION_PLAN.md
git commit -m "docs: document protected skill uninstall boundary"
```

## Self-Review

- Spec coverage: Task 1 implements the type, file, and normalized-root guards plus deletion; Task 2 implements confirmation, locking, errors, reindexing, and Skill-only visibility; Task 3 updates the stated product boundary.
- Placeholder scan: no unresolved placeholders or deferred work remain.
- Type consistency: Tasks 1–2 use `SkillLifecycleManaging.uninstall(_ entry: PluginSkillEntry)` and `AppState.uninstallSkill(_:)` consistently.
