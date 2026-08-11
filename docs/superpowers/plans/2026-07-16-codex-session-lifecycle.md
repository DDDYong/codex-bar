# Codex 会话生命周期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Codex Bar 原生会话页中支持真实会话的归档、取消归档与不可恢复删除。

**Architecture:** `SessionIndexSource` 同时读取活跃和归档根目录，向模型提供 thread ID 和状态。新的 `SessionLifecycleSource` 将归档操作委托给 Codex CLI，并校验永久删除路径；`AppState` 串联异步操作、错误状态和重新索引，SwiftUI 只负责筛选、确认与调用。

**Tech Stack:** Swift 5、SwiftUI、Foundation、XCTest、Xcode macOS 13+。

## Global Constraints

- 仅操作 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 中已验证的 JSONL 会话文件。
- 归档与取消归档必须调用本机 `codex archive <thread-id>` 和 `codex unarchive <thread-id>`。
- 删除必须二次确认，且不读取、展示、保存会话正文或认证信息。
- 不引入第三方依赖，不修改用户已有未提交文件的无关部分。

---

### Task 1: 扩展会话模型与索引

**Files:**
- Modify: `macos/CodexBar/CodexBar/Models/SessionIndexEntry.swift`
- Modify: `macos/CodexBar/CodexBar/Sources/SessionIndexSource.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`

**Interfaces:**
- Produces: `SessionIndexEntry.Storage`（`.active`、`.archived`）、`threadID: String?`、`storage: Storage`。
- Consumes: `SessionIndexSource(activeRootURL:archivedRootURL:sessionIndexURL:fileManager:)`。

- [ ] **Step 1: 写入归档会话索引的失败测试**

```swift
func testSessionIndexIncludesArchivedSessionsWithArchivedStorage() throws {
    let root = try temporaryDirectory()
    let active = root.appendingPathComponent("sessions")
    let archived = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    try Data("{\"payload\":{\"id\":\"active-id\"}}\n".utf8).write(to: active.appendingPathComponent("active.jsonl"))
    try Data("{\"payload\":{\"id\":\"archived-id\"}}\n".utf8).write(to: archived.appendingPathComponent("archived.jsonl"))
    let entries = SessionIndexSource(activeRootURL: active, archivedRootURL: archived).scan()
    XCTAssertEqual(entries.first { $0.threadID == "active-id" }?.storage, .active)
    XCTAssertEqual(entries.first { $0.threadID == "archived-id" }?.storage, .archived)
}
```

- [ ] **Step 2: 运行测试，确认新初始化器或属性不存在**

Run: `xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' -only-testing:CodexBarTests/CodexBarTests/testSessionIndexIncludesArchivedSessionsWithArchivedStorage test`

Expected: FAIL，指出 `activeRootURL`、`archivedRootURL`、`threadID` 或 `storage` 尚未定义。

- [ ] **Step 3: 最小实现模型和双根扫描**

```swift
enum Storage: String, Equatable { case active, archived }
let threadID: String?
let storage: Storage

func scan() -> [SessionIndexEntry] {
    scan(rootURL: activeRootURL, storage: .active)
        + scan(rootURL: archivedRootURL, storage: .archived)
}
```

保留既有 `init(rootURL:sessionIndexURL:fileManager:)` 兼容测试；新初始化器接收两个根目录。元数据中的 `id` 写入 `threadID`，UI 身份仍为文件绝对路径。

- [ ] **Step 4: 运行所有索引测试**

Run: `xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' -only-testing:CodexBarTests/CodexBarTests/testSessionIndexReadsOnlyVerifiedFileMetadataAndSkipsCorruptFiles -only-testing:CodexBarTests/CodexBarTests/testSessionIndexUsesCodexThreadNameFromSeparateMetadataIndex -only-testing:CodexBarTests/CodexBarTests/testSessionIndexIncludesArchivedSessionsWithArchivedStorage test`

Expected: PASS，三个索引测试通过。

- [ ] **Step 5: 提交索引能力**

Run: `git add macos/CodexBar/CodexBar/Models/SessionIndexEntry.swift macos/CodexBar/CodexBar/Sources/SessionIndexSource.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift && git commit -m 'feat: index archived codex sessions'`

### Task 2: 实现受保护的会话生命周期服务

**Files:**
- Create: `macos/CodexBar/CodexBar/Sources/SessionLifecycleSource.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`
- Modify: `macos/CodexBar/CodexBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `SessionLifecycleSource.archive(_:)`、`unarchive(_:)`、`delete(_:)`。
- Consumes: `SessionIndexEntry` 和可注入命令闭包 `(String, [String]) throws -> Void`。

- [ ] **Step 1: 写入命令参数与路径保护的失败测试**

```swift
func testLifecycleArchivePassesThreadIDToCodexCLI() throws {
    var invocation: (String, [String])?
    let source = SessionLifecycleSource { executable, arguments in
        invocation = (executable, arguments)
    }
    try source.archive(session(threadID: "thread-123", path: "/tmp/valid.jsonl", storage: .active))
    XCTAssertEqual(invocation?.0, "codex")
    XCTAssertEqual(invocation?.1, ["archive", "thread-123"])
}

func testLifecycleDeleteRejectsPathOutsideCodexSessionRoots() throws {
    let source = SessionLifecycleSource(activeRootURL: URL(fileURLWithPath: "/tmp/sessions"), archivedRootURL: URL(fileURLWithPath: "/tmp/archived"))
    XCTAssertThrowsError(try source.delete(session(threadID: "thread-123", path: "/tmp/elsewhere/item.jsonl", storage: .active)))
}
```

- [ ] **Step 2: 运行测试，确认服务尚不存在**

Run: `xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' -only-testing:CodexBarTests/CodexBarTests/testLifecycleArchivePassesThreadIDToCodexCLI -only-testing:CodexBarTests/CodexBarTests/testLifecycleDeleteRejectsPathOutsideCodexSessionRoots test`

Expected: FAIL，指出 `SessionLifecycleSource` 尚未定义。

- [ ] **Step 3: 最小实现服务与文件保护**

```swift
func archive(_ entry: SessionIndexEntry) throws {
    try runCodex("archive", threadID: try requireThreadID(entry))
}

func delete(_ entry: SessionIndexEntry) throws {
    try fileManager.removeItem(at: try validatedSessionURL(for: entry))
}

private func validatedSessionURL(for entry: SessionIndexEntry) throws -> URL {
    let url = URL(fileURLWithPath: entry.filePath).standardizedFileURL
    guard url.pathExtension == "jsonl", allowedRoots.contains(where: { url.path.hasPrefix($0.path + "/") }) else {
        throw SessionLifecycleError.invalidSessionPath
    }
    return url
}
```

默认命令执行器以 `Process` 调用 `/usr/bin/env codex <command> <thread-id>`，非零退出码抛出包含 stderr 的错误。将服务文件纳入 app target。

- [ ] **Step 4: 运行生命周期测试**

Run: `xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' -only-testing:CodexBarTests/CodexBarTests/testLifecycleArchivePassesThreadIDToCodexCLI -only-testing:CodexBarTests/CodexBarTests/testLifecycleDeleteRejectsPathOutsideCodexSessionRoots test`

Expected: PASS，命令参数匹配且越界路径被拒绝。

- [ ] **Step 5: 提交生命周期服务**

Run: `git add macos/CodexBar/CodexBar/Sources/SessionLifecycleSource.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift macos/CodexBar/CodexBar.xcodeproj/project.pbxproj && git commit -m 'feat: manage codex session lifecycle'`

### Task 3: 串联状态与会话页交互

**Files:**
- Modify: `macos/CodexBar/CodexBar/App/AppState.swift`
- Modify: `macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`

**Interfaces:**
- Consumes: `SessionLifecycleSource.archive(_:)`、`unarchive(_:)`、`delete(_:)`。
- Produces: `AppState.archiveSession(_:)`、`unarchiveSession(_:)`、`deleteSession(_:)`、`sessionOperationError`、`sessionOperationEntryID`。

- [ ] **Step 1: 写入 AppState 操作完成后重新索引的失败测试**

```swift
func testArchiveSessionRefreshesIndexAfterLifecycleOperation() async {
    let lifecycle = RecordingLifecycleSource()
    let state = AppState(sessionIndexSource: fixtureIndexSource(), sessionLifecycleSource: lifecycle)
    await state.archiveSession(fixtureSession(storage: .active))
    XCTAssertEqual(lifecycle.archivedThreadIDs, ["thread-123"])
    XCTAssertFalse(state.isOperatingOnSession)
    XCTAssertNil(state.sessionOperationError)
}
```

以 `SessionLifecycleManaging` 协议将生产服务与记录型测试替身分离，测试不运行真实 CLI。

- [ ] **Step 2: 运行测试，确认 AppState API 缺失**

Run: `xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' -only-testing:CodexBarTests/CodexBarTests/testArchiveSessionRefreshesIndexAfterLifecycleOperation test`

Expected: FAIL，指出 `sessionLifecycleSource` 或 `archiveSession` 尚未定义。

- [ ] **Step 3: 最小实现 AppState 和 UI**

```swift
func archiveSession(_ entry: SessionIndexEntry) {
    performSessionOperation(entry) { try sessionLifecycleSource.archive($0) }
}

private func performSessionOperation(_ entry: SessionIndexEntry, operation: @escaping (SessionIndexEntry) throws -> Void) {
    sessionOperationEntryID = entry.id
    sessionOperationError = nil
    Task { [weak self] in
        do { try operation(entry); self?.refreshSessionIndex() }
        catch { self?.sessionOperationError = error.localizedDescription }
        self?.sessionOperationEntryID = nil
    }
}
```

在 `SessionsView` 增加“全部 / 活跃 / 已归档”筛选。活跃卡片显示“归档”，归档卡片显示“取消归档”；两类均显示红色“彻底删除”。删除使用 `.alert("彻底删除会话？", isPresented:)`，提示“此操作不可恢复”；操作中禁用该卡片全部按钮，页面顶部显示错误。

- [ ] **Step 4: 运行完整测试和构建**

Run: `xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test && xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -configuration Debug -destination 'platform=macOS' build`

Expected: 分别以 `** TEST SUCCEEDED **`、`** BUILD SUCCEEDED **` 结束。

- [ ] **Step 5: 手动验收并提交**

启动应用后，在“Codex 会话”中验证状态筛选、归档/取消归档、删除确认、成功刷新和失败提示。

Run: `git add macos/CodexBar/CodexBar/App/AppState.swift macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift && git commit -m 'feat: add session archive controls'`
