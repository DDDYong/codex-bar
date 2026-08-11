# Profile Snapshot and Local Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display a user-confirmed, cross-device Codex Profile snapshot while keeping Mac-local session evidence visibly separate and non-comparable.

**Architecture:** Persist only four structured numbers confirmed from a selected Profile share-card image; perform image recognition in memory and never retain the image. Replace the current local Token totals with a clearly labeled Mac-local activity view that does not claim to equal Profile metrics.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Vision, UniformTypeIdentifiers, Foundation, XCTest, macOS 13.

## Global Constraints

- The Profile snapshot stores only total tokens, peak-day tokens, current streak days, longest streak days, import time, and a fixed source label.
- Do not save the image, avatar, name, username, account identifier, session text, tool arguments, or authentication data.
- Recognition happens only after a user selects or drops a local image; candidate values must remain editable and require explicit confirmation before persistence.
- Fields absent from the card display “官方快照未提供”; never infer longest-task duration or daily totals.
- Mac-local activity must be visibly labeled “仅此 Mac” and must not populate, add to, or compare against official snapshot fields.
- Remove the existing local estimated total/peak/streak/duration metrics because they cannot be represented as Profile-accurate Token data.
- No third-party dependencies; keep the macOS 13 native SwiftUI target.

---

## File Structure

- `macos/CodexBar/CodexBar/Models/ProfileSnapshot.swift` — Codable official snapshot and editable import draft.
- `macos/CodexBar/CodexBar/Persistence/ProfileSnapshotStore.swift` — dedicated JSON persistence for the confirmed snapshot.
- `macos/CodexBar/CodexBar/Sources/ProfileCardRecognizer.swift` — in-memory Vision OCR and label-based number extraction.
- `macos/CodexBar/CodexBar/App/AppState.swift` — snapshot state, import confirmation, persistence and error ownership.
- `macos/CodexBar/CodexBar/Models/TokenActivityStats.swift` — removes Profile-like calculated metrics and retains only Mac-local record dates.
- `macos/CodexBar/CodexBar/Sources/TokenActivitySource.swift` — emits only verified local record dates, with no Token total, peak, streak, or duration claims.
- `macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift` — official snapshot card, image picker/drop target, editable confirmation dialog, and separate Mac-local activity section.
- `macos/CodexBar/CodexBarTests/CodexBarTests.swift` — persistence, OCR parsing, confirmation and source-boundary tests.
- `macos/CodexBar/CodexBar.xcodeproj/project.pbxproj` — registers the three new Swift source files.

### Task 1: Add the confirmed snapshot model and persistence boundary

**Files:**
- Create: `macos/CodexBar/CodexBar/Models/ProfileSnapshot.swift`
- Create: `macos/CodexBar/CodexBar/Persistence/ProfileSnapshotStore.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`
- Modify: `macos/CodexBar/CodexBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces `struct ProfileSnapshot: Codable, Equatable` with `totalTokens`, `peakDayTokens`, `currentStreakDays`, `longestStreakDays`, `importedAt`, and `sourceLabel`.
- Produces `struct ProfileSnapshotDraft: Equatable` with optional integer fields used before confirmation.
- Produces `ProfileSnapshotStore.load() -> ProfileSnapshot?`, `save(_:) throws`, and `clear() throws`.

- [ ] **Step 1: Write failing persistence tests**

Add a round-trip test that saves and reloads this exact record to a temporary file:

```swift
let record = ProfileSnapshot(
    totalTokens: 1_780_000_000,
    peakDayTokens: 95_005_000,
    currentStreakDays: 17,
    longestStreakDays: 31,
    importedAt: Date(timeIntervalSince1970: 1_784_000_000),
    sourceLabel: "Codex Profile 分享卡片"
)
```

Assert every field survives. Add a second test that a missing file returns `nil`, and a third that `clear()` removes a saved snapshot.

- [ ] **Step 2: Verify the new tests fail**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testProfileSnapshotStoreRoundTripsConfirmedValues
```

Expected: build failure because `ProfileSnapshot` and `ProfileSnapshotStore` do not exist.

- [ ] **Step 3: Implement model and store**

Create the model with no identity or image fields:

```swift
struct ProfileSnapshot: Codable, Equatable {
    let totalTokens: Int
    let peakDayTokens: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let importedAt: Date
    let sourceLabel: String
}

struct ProfileSnapshotDraft: Equatable {
    var totalTokens: Int?
    var peakDayTokens: Int?
    var currentStreakDays: Int?
    var longestStreakDays: Int?
}
```

Implement `ProfileSnapshotStore` with an injected `fileURL`, ISO-8601 JSON encoding, atomic writes, and a default path of `~/Library/Application Support/Codex Bar/profile-snapshot.json`. It must encode one `ProfileSnapshot`, not an image or an array of cards.

Register both files in the Models/Persistence groups and application Sources build phase using the existing `TokenActivityStats.swift` and `SnapshotStore.swift` project-file patterns.

- [ ] **Step 4: Run the focused persistence tests**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testProfileSnapshotStoreRoundTripsConfirmedValues
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit the persistence boundary**

```sh
git add macos/CodexBar/CodexBar/Models/ProfileSnapshot.swift macos/CodexBar/CodexBar/Persistence/ProfileSnapshotStore.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift macos/CodexBar/CodexBar.xcodeproj/project.pbxproj
git commit -m "feat: persist confirmed profile snapshots"
```

### Task 2: Recognize only Profile-card metrics and require confirmation

**Files:**
- Create: `macos/CodexBar/CodexBar/Sources/ProfileCardRecognizer.swift`
- Modify: `macos/CodexBar/CodexBar/App/AppState.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`
- Modify: `macos/CodexBar/CodexBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces `protocol ProfileCardRecognizing { func recognize(imageData: Data) throws -> ProfileSnapshotDraft }`.
- `AppState` produces `profileSnapshot`, `profileSnapshotError`, `saveProfileSnapshot(_ draft: ProfileSnapshotDraft)`, and `clearProfileSnapshot()`.
- Recognition parses labels, not fixed image coordinates: `累计 Token`, `峰值日`, `当前连续天数`, `最长连续`.

- [ ] **Step 1: Write failing parser and confirmation tests**

Expose a package-internal `ProfileCardRecognizer.parse(lines:)` and test it with these OCR lines:

```swift
let draft = try ProfileCardRecognizer.parse(lines: [
    "17.8亿", "累计 Token", "9500.5万", "峰值日",
    "17 天", "当前连续天数", "31 天", "最长连续使用"
])
XCTAssertEqual(draft.totalTokens, 1_780_000_000)
XCTAssertEqual(draft.peakDayTokens, 95_005_000)
XCTAssertEqual(draft.currentStreakDays, 17)
XCTAssertEqual(draft.longestStreakDays, 31)
```

Add a missing-field test that returns a draft with only recognized optional values. Add an `@MainActor` AppState test that constructs a draft, calls `saveProfileSnapshot`, and asserts the in-memory state is non-nil; do not call the recognizer in this test.

- [ ] **Step 2: Verify the parser test fails**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testProfileCardParserExtractsLabeledChineseMetrics
```

Expected: build failure because `ProfileCardRecognizer` does not exist.

- [ ] **Step 3: Implement in-memory OCR and AppState persistence**

Use `VNRecognizeTextRequest` with `.accurate` recognition, operating only on the `Data` supplied by the current picker/drop action. Convert recognized strings to a `ProfileSnapshotDraft`; parse Chinese units with this exact multiplier behavior:

```swift
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
```

`AppState.saveProfileSnapshot(_:)` must guard that all four values are present and non-negative, create a record with `Date()` and `"Codex Profile 分享卡片"`, save it through `ProfileSnapshotStore`, then publish it. Recognition failure must set `profileSnapshotError` without writing the store. The View, not AppState, owns temporary image bytes; after recognition returns or fails, it releases them.

- [ ] **Step 4: Run focused tests and full suite**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testProfileCardParserExtractsLabeledChineseMetrics
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test
```

Expected: both commands exit 0. Inspect the Application Support JSON and verify it contains only the six `ProfileSnapshot` fields and no base64 image payload.

- [ ] **Step 5: Commit recognition and state ownership**

```sh
git add macos/CodexBar/CodexBar/Sources/ProfileCardRecognizer.swift macos/CodexBar/CodexBar/App/AppState.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift macos/CodexBar/CodexBar.xcodeproj/project.pbxproj
git commit -m "feat: import confirmed profile card metrics"
```

### Task 3: Replace misleading Token metrics with separated official and Mac-local views

**Files:**
- Modify: `macos/CodexBar/CodexBar/Models/TokenActivityStats.swift`
- Modify: `macos/CodexBar/CodexBar/Sources/TokenActivitySource.swift`
- Modify: `macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift`
- Modify: `macos/CodexBar/CodexBarTests/CodexBarTests.swift`

**Interfaces:**
- `TokenActivityStats` exposes `localRecordDays: [Date]` only; it no longer exposes `totalTokens`, `peakTokens`, `longestSessionDuration`, or streak fields.
- `TokenActivitySource.scan()` records a date only when a local JSONL event has a valid timestamp; it does not read `last_token_usage` or calculate Token counts.
- `TokenActivityPanel` consumes `AppState.profileSnapshot`, `profileSnapshotError`, and `TokenActivityStats.localRecordDays`.

- [ ] **Step 1: Write failing source-boundary tests**

Replace the existing Token aggregation test with a test that creates timestamped JSONL lines, including a `payload.info.last_token_usage` object, then asserts `localRecordDays` contains the two expected dates and that the stats model has no numeric Token-total fields used by the view. The test fixture must not assert a calculated Token amount.

- [ ] **Step 2: Verify the source-boundary test fails**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests/CodexBarTests/testTokenActivitySourceReportsOnlyLocalRecordDates
```

Expected: compile/test failure because `localRecordDays` does not yet exist.

- [ ] **Step 3: Implement the honest local source and UI**

Refactor the model and source so the scan streams JSONL line-by-line, accepts only valid timestamps, and returns unique calendar days. It must not inspect `payload`, `info`, `last_token_usage`, or any Token number.

In `TokenActivityPanel`, replace the current five calculated metric cards and bar chart with:

```text
全设备官方快照
  [累计 Token] [峰值日] [当前连续] [最长连续]
  来源：Codex Profile 分享卡片 · 同步于 <timestamp>
  [更新官方快照] [清除官方快照]

本机 Mac 明细 · 仅此 Mac
  本机发现记录的日期：<count> 天
  日历式日期点阵 / 空状态
  不显示 Token 总量、峰值、连续天数或最长任务时长
```

Use `fileImporter(isPresented:allowedContentTypes:)` with `[.image]` and an `.onDrop(of: [.image])` handler. Both load a single `Data` value, call the recognizer, and open a sheet with four editable `TextField` values. The sheet must have “取消” and “确认保存”; only the latter calls `appState.saveProfileSnapshot`. The selected image is discarded on either action. Missing values show “官方快照未提供” in the sheet and cannot be saved until filled manually.

Use an empty state when `profileSnapshot == nil`:

```swift
Text("导入 Codex Profile 卡片以显示全设备官方数据")
```

Do not display a Profile image, name, username, or raw OCR text.

- [ ] **Step 4: Run automated and manual verification**

Run:

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test -only-testing:CodexBarTests
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test
```

Expected: both commands exit 0. Manually import `/Users/apple/Downloads/codex-profile-card.png`, verify the review fields show `17.8 亿`, `9500.5 万`, `17 天`, and `31 天`; save, restart the app, and verify the same four official fields restore. Confirm the Application Support folder contains no image file and that the Mac-local section never presents Token totals as Profile data.

- [ ] **Step 5: Commit the separated activity experience**

```sh
git add macos/CodexBar/CodexBar/Models/TokenActivityStats.swift macos/CodexBar/CodexBar/Sources/TokenActivitySource.swift macos/CodexBar/CodexBar/Features/Dashboard/DashboardShellView.swift macos/CodexBar/CodexBarTests/CodexBarTests.swift
git commit -m "feat: separate profile snapshot from local activity"
```

## Self-Review

- Spec coverage: Task 1 creates a privacy-bounded snapshot store; Task 2 implements local OCR plus explicit confirmation; Task 3 separates the official card from Mac-local evidence and removes all misleading Profile-like local metrics.
- Placeholder scan: no unresolved placeholders or deferred work remain.
- Type consistency: `ProfileSnapshotDraft` feeds `AppState.saveProfileSnapshot(_:)`, which creates the persisted `ProfileSnapshot`; the UI consumes only the latter after confirmation.
