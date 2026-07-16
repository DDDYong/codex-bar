import XCTest
@testable import CodexBar

final class CodexBarTests: XCTestCase {
    func testProfileCardParserExtractsLabeledChineseMetrics() throws {
        let draft = try ProfileCardRecognizer.parse(lines: [
            "17.8亿", "累计 Token", "9500.5万", "峰值日",
            "17 天", "当前连续天数", "31 天", "最长连续使用"
        ])

        XCTAssertEqual(draft.totalTokens, 1_780_000_000)
        XCTAssertEqual(draft.peakDayTokens, 95_005_000)
        XCTAssertEqual(draft.currentStreakDays, 17)
        XCTAssertEqual(draft.longestStreakDays, 31)
    }

    func testProfileCardParserReturnsOnlyRecognizedMetricsWhenFieldsAreMissing() throws {
        let draft = try ProfileCardRecognizer.parse(lines: [
            "17.8亿", "累计 Token", "17 天", "当前连续天数"
        ])

        XCTAssertEqual(draft.totalTokens, 1_780_000_000)
        XCTAssertNil(draft.peakDayTokens)
        XCTAssertEqual(draft.currentStreakDays, 17)
        XCTAssertNil(draft.longestStreakDays)
    }

    @MainActor
    func testSaveProfileSnapshotPublishesConfirmedDraft() {
        let fileURL = profileSnapshotFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let state = AppState(profileSnapshotStore: ProfileSnapshotStore(fileURL: fileURL))
        let draft = ProfileSnapshotDraft(
            totalTokens: 1_780_000_000,
            peakDayTokens: 95_005_000,
            currentStreakDays: 17,
            longestStreakDays: 31
        )

        state.saveProfileSnapshot(draft)

        XCTAssertEqual(state.profileSnapshot?.totalTokens, 1_780_000_000)
        XCTAssertEqual(state.profileSnapshot?.peakDayTokens, 95_005_000)
        XCTAssertEqual(state.profileSnapshot?.currentStreakDays, 17)
        XCTAssertEqual(state.profileSnapshot?.longestStreakDays, 31)
    }

    @MainActor
    func testRecognizeProfileSnapshotFailureDoesNotPersistOrPublishSnapshot() async {
        let fileURL = profileSnapshotFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = ProfileSnapshotStore(fileURL: fileURL)
        let state = AppState(profileSnapshotStore: store)

        let draft = await state.recognizeProfileSnapshot(imageData: Data("not an image".utf8))

        XCTAssertNil(draft)
        XCTAssertNotNil(state.profileSnapshotError)
        XCTAssertNil(store.load())
        XCTAssertNil(state.profileSnapshot)
    }

    func testProfileSnapshotStoreRoundTripsConfirmedValues() throws {
        let fileURL = profileSnapshotFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let record = ProfileSnapshot(
            totalTokens: 1_780_000_000,
            peakDayTokens: 95_005_000,
            currentStreakDays: 17,
            longestStreakDays: 31,
            importedAt: Date(timeIntervalSince1970: 1_784_000_000),
            sourceLabel: "Codex Profile 分享卡片"
        )

        try ProfileSnapshotStore(fileURL: fileURL).save(record)

        let loaded = ProfileSnapshotStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded?.totalTokens, record.totalTokens)
        XCTAssertEqual(loaded?.peakDayTokens, record.peakDayTokens)
        XCTAssertEqual(loaded?.currentStreakDays, record.currentStreakDays)
        XCTAssertEqual(loaded?.longestStreakDays, record.longestStreakDays)
        XCTAssertEqual(loaded?.importedAt, record.importedAt)
        XCTAssertEqual(loaded?.sourceLabel, record.sourceLabel)
    }

    func testProfileSnapshotStoreReturnsNilWhenFileIsMissing() {
        let fileURL = profileSnapshotFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        XCTAssertNil(ProfileSnapshotStore(fileURL: fileURL).load())
    }

    func testProfileSnapshotStoreClearRemovesSavedSnapshot() throws {
        let fileURL = profileSnapshotFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let record = ProfileSnapshot(
            totalTokens: 1,
            peakDayTokens: 2,
            currentStreakDays: 3,
            longestStreakDays: 4,
            importedAt: Date(timeIntervalSince1970: 0),
            sourceLabel: "Test"
        )
        let store = ProfileSnapshotStore(fileURL: fileURL)

        try store.save(record)
        try store.clear()

        XCTAssertNil(store.load())
    }

    func testDashboardContainsSevenStaticRoutes() {
        XCTAssertEqual(DashboardRoute.allCases.count, 7)
    }

    func testDashboardDefaultWindowSizeMatchesMinimumWindowSize() {
        XCTAssertEqual(AppConfiguration.defaultWindowSize, AppConfiguration.minimumWindowSize)
    }

    func testUsageParserSupportsSnakeCaseAndCamelCaseWindows() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "rateLimit": [
                "windows": [
                    ["name": "primary", "used_percent": 26, "reset_at": 1_738_300_000, "limit_window_seconds": 18_000],
                    ["name": "weekly", "utilization": 0.4, "resetsAt": "2026-07-07T00:00:00Z", "windowSeconds": 604_800]
                ]
            ],
            "planType": "plus"
        ])

        let snapshot = try CodexUsageSource.parseSnapshot(from: payload, updatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snapshot.plan, "PLUS")
        XCTAssertEqual(snapshot.shortWindow?.remainingPercent, 74)
        XCTAssertEqual(snapshot.weeklyWindow?.remainingPercent, 60)
        XCTAssertEqual(snapshot.weeklyWindow?.resetsAt, "2026-07-07T00:00:00Z")
    }

    func testResetCreditParserCollectsNestedExpirationsWithoutDuplicates() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "availableCount": 3,
            "credits": [
                ["expires_at": "2026-07-09T00:00:00Z"],
                ["grants": [["expirationTime": "2026-07-08T00:00:00Z"], ["expires_at": "2026-07-09T00:00:00Z"]]]
            ]
        ])

        let credits = try CodexUsageSource.parseResetCredits(from: payload)

        XCTAssertEqual(credits.availableCount, 3)
        XCTAssertEqual(credits.expiresAt, ["2026-07-08T00:00:00Z", "2026-07-09T00:00:00Z"])
    }

    func testUsageParserFallsBackToShortWindowWhenWeeklyWindowIsUnavailable() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "rate_limit": ["primary_window": ["remainingPercent": 42, "windowSeconds": 18_000]]
        ])

        let snapshot = try CodexUsageSource.parseSnapshot(from: payload)

        XCTAssertEqual(snapshot.shortWindow?.remainingPercent, 42)
        XCTAssertEqual(snapshot.weeklyWindow?.remainingPercent, 42)
    }

    func testAuthResolverDerivesAccountIdentifierFromJwtPayload() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": "header.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0X3Rlc3QifQ.signature"
            ]
        ])

        let auth = try CodexUsageSource.parseAuth(from: payload)

        XCTAssertEqual(auth.accountID, "acct_test")
    }

    func testAuthResolverExtractsSafeAccountPresentationFromWhitelistedClaims() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": "header.eyJlbWFpbCI6ImFsaWNlQGV4YW1wbGUuY29tIiwibmFtZSI6IkFsaWNlIENvZGV4In0.signature"
            ]
        ])

        let auth = try CodexUsageSource.parseAuth(from: payload)

        XCTAssertEqual(auth.account.displayName, "Alice Codex")
        XCTAssertEqual(auth.account.email, "alice@example.com")
    }

    func testMenuBarDisplayModesExcludeSessionStatusFromTitle() {
        let snapshot = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(remainingPercent: 68, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: 2, expiresAt: []),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(MenuBarPresentation.title(for: .detailed, snapshot: snapshot), "week 68% · -- · 2次")
        XCTAssertEqual(MenuBarPresentation.title(for: .compact, snapshot: snapshot), "week 68%")
        XCTAssertEqual(MenuBarPresentation.title(for: .iconOnly, snapshot: snapshot), "")
    }

    func testSessionActivityPrioritizesRunningThenWaitingThenFailure() {
        XCTAssertEqual(SessionActivity.aggregate([.completed, .running]), .running)
        XCTAssertEqual(SessionActivity.aggregate([.completed, .waiting]), .waiting)
        XCTAssertEqual(SessionActivity.aggregate([.completed, .failed]), .failed)
    }

    func testSessionActivityMapsRecentEventTypesWithoutReadingPayloads() {
        XCTAssertEqual(SessionActivity.from(eventTypes: ["task_complete"]), .completed)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["reasoning", "custom_tool_call"]), .running)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["permission_request"]), .waiting)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["error"]), .failed)
    }

    func testSnapshotStoreKeepsChangedShortWindowAndPersistsIt() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage-snapshots.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = SnapshotStore(fileURL: fileURL)
        let capturedAt = Date(timeIntervalSince1970: 1_783_000_000)
        let first = snapshotRecord(capturedAt: capturedAt, weekly: 70, short: 90)
        let changedShortWindow = snapshotRecord(capturedAt: capturedAt.addingTimeInterval(60), weekly: 70, short: 89)

        try store.append(first)
        try store.append(changedShortWindow)

        XCTAssertEqual(SnapshotStore(fileURL: fileURL).load(), [first, changedShortWindow])
    }

    func testSettingsStoreRestoresSavedAppSettings() {
        let suiteName = "CodexBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let settings = AppSettings(
            displayMode: .compact,
            theme: .dark,
            snapshotRetentionDays: 30,
            sessionIndexEnabled: false,
            pluginSkillIndexEnabled: true
        )

        store.save(settings)

        XCTAssertEqual(SettingsStore(defaults: defaults).load(), settings)
    }

    func testSessionIndexReadsOnlyVerifiedFileMetadataAndSkipsCorruptFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("thread-123.jsonl")
        try Data("{\"cwd\":\"/tmp/project\",\"timestamp\":\"2026-07-15T12:00:00Z\",\"payload\":{\"content\":\"do not expose\"}}\n".utf8).write(to: valid)
        try Data("not-json\n".utf8).write(to: root.appendingPathComponent("broken.jsonl"))

        let entries = SessionIndexSource(rootURL: root).scan()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "thread-123")
        XCTAssertEqual(entries[0].projectPath, "/tmp/project")
        XCTAssertNil(entries[0].body)
    }

    func testSessionIndexUsesCodexThreadNameFromSeparateMetadataIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("rollout.jsonl")
        let index = root.appendingPathComponent("session_index.jsonl")
        try Data("{\"payload\":{\"id\":\"thread-123\",\"cwd\":\"/tmp/project\"}}\n".utf8).write(to: session)
        try Data("{\"id\":\"thread-123\",\"thread_name\":\"我的自定义任务名\",\"updated_at\":\"2026-07-15T12:00:00Z\"}\n".utf8).write(to: index)

        let entries = SessionIndexSource(rootURL: root, sessionIndexURL: index).scan()

        XCTAssertEqual(entries.first?.title, "我的自定义任务名")
    }

    func testSessionIndexScansActiveAndArchivedSessionsWithStorageAndThreadID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let activeRoot = root.appendingPathComponent("sessions")
        let archivedRoot = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        try Data("{\"payload\":{\"id\":\"active-id\",\"cwd\":\"/tmp/active\"}}\n".utf8)
            .write(to: activeRoot.appendingPathComponent("active.jsonl"))
        try Data("{\"payload\":{\"id\":\"archived-id\",\"cwd\":\"/tmp/archived\"}}\n".utf8)
            .write(to: archivedRoot.appendingPathComponent("archived.jsonl"))

        let entries = SessionIndexSource(
            activeRootURL: activeRoot,
            archivedRootURL: archivedRoot,
            sessionIndexURL: root.appendingPathComponent("session_index.jsonl")
        ).scan()

        XCTAssertEqual(entries.first { $0.threadID == "active-id" }?.storage, .active)
        XCTAssertEqual(entries.first { $0.threadID == "archived-id" }?.storage, .archived)
    }

    func testArchivePassesExactCodexCommandAndThreadID() throws {
        let runner = RecordingSessionCommandRunner()
        let source = SessionLifecycleSource(commandRunner: runner)

        try source.archive(sessionEntry(threadID: "thread-123"))

        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands.first?.0, "/usr/bin/env")
        XCTAssertEqual(runner.commands.first?.1, ["codex", "archive", "thread-123"])
    }

    func testUnarchiveAcceptsCLIErrorWhenSessionFileWasRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let activeRoot = root.appendingPathComponent("sessions")
        let archivedRoot = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        let archivedFile = archivedRoot.appendingPathComponent("rollout-thread-123.jsonl")
        try Data("metadata only".utf8).write(to: archivedFile)

        let runner = ClosureSessionCommandRunner {
            let restoredDirectory = activeRoot.appendingPathComponent("2026/07/16")
            try FileManager.default.createDirectory(at: restoredDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: archivedFile, to: restoredDirectory.appendingPathComponent(archivedFile.lastPathComponent))
            return SessionCommandResult(status: 1, standardError: "Error: failed to unarchive session")
        }
        let source = SessionLifecycleSource(
            activeRootURL: activeRoot,
            archivedRootURL: archivedRoot,
            commandRunner: runner
        )
        let entry = SessionIndexEntry(
            id: archivedFile.path,
            threadID: "thread-123",
            title: "thread",
            filePath: archivedFile.path,
            projectPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 0,
            storage: .archived
        )

        XCTAssertNoThrow(try source.unarchive(entry))
    }

    func testDeleteRemovesJSONLFileWithinActiveRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activeRoot = root.appendingPathComponent("sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        let sessionFile = activeRoot.appendingPathComponent("thread.jsonl")
        try Data("metadata only".utf8).write(to: sessionFile)
        let source = SessionLifecycleSource(activeRootURL: activeRoot, archivedRootURL: root.appendingPathComponent("archived_sessions"))

        try source.delete(sessionEntry(fileURL: sessionFile))

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    func testDeleteRejectsPathOutsideConfiguredRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activeRoot = root.appendingPathComponent("sessions")
        let outside = root.appendingPathComponent("outside.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try Data("metadata only".utf8).write(to: outside)
        let source = SessionLifecycleSource(activeRootURL: activeRoot, archivedRootURL: root.appendingPathComponent("archived_sessions"))

        XCTAssertThrowsError(try source.delete(sessionEntry(fileURL: outside)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testDeleteRejectsNonJSONLFileWithinConfiguredRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activeRoot = root.appendingPathComponent("sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        let nonSessionFile = activeRoot.appendingPathComponent("notes.txt")
        try Data("metadata only".utf8).write(to: nonSessionFile)
        let source = SessionLifecycleSource(activeRootURL: activeRoot, archivedRootURL: root.appendingPathComponent("archived_sessions"))

        XCTAssertThrowsError(try source.delete(sessionEntry(fileURL: nonSessionFile)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonSessionFile.path))
    }

    @MainActor
    func testArchiveSessionRefreshesIndexAfterLifecycleOperation() async {
        let lifecycle = RecordingLifecycleSource()
        let state = AppState(sessionLifecycleSource: lifecycle)
        let entry = sessionEntry(threadID: "thread-123")

        await state.archiveSession(entry)

        XCTAssertEqual(lifecycle.archivedThreadIDs, ["thread-123"])
        XCTAssertFalse(state.isOperatingOnSession)
        XCTAssertNil(state.sessionOperationError)
    }

    @MainActor
    func testDeleteSessionSurfacesLifecycleError() async {
        let lifecycle = RecordingLifecycleSource(error: TestLifecycleError.failed)
        let state = AppState(sessionLifecycleSource: lifecycle)

        await state.deleteSession(sessionEntry())

        XCTAssertEqual(state.sessionOperationError, TestLifecycleError.failed.localizedDescription)
        XCTAssertFalse(state.isOperatingOnSession)
    }

    @MainActor
    func testUninstallSkillRefreshesIndexAfterSuccessfulLifecycleOperation() async {
        let lifecycle = RecordingSkillLifecycleSource()
        let state = AppState(skillLifecycleSource: lifecycle)
        let entry = skillEntry(fileURL: URL(fileURLWithPath: "/tmp/review/SKILL.md"))

        await state.uninstallSkill(entry)

        XCTAssertEqual(lifecycle.uninstalledEntryIDs, [entry.id])
        XCTAssertFalse(state.isOperatingOnSkill)
        XCTAssertNil(state.skillOperationError)
    }

    @MainActor
    func testUninstallSkillSurfacesLifecycleError() async {
        let lifecycle = RecordingSkillLifecycleSource(error: TestLifecycleError.failed)
        let state = AppState(skillLifecycleSource: lifecycle)
        let entry = skillEntry(fileURL: URL(fileURLWithPath: "/tmp/review/SKILL.md"))

        await state.uninstallSkill(entry)

        XCTAssertEqual(state.skillOperationError, TestLifecycleError.failed.localizedDescription)
        XCTAssertEqual(state.skillOperationFailureEntryID, entry.id)
        XCTAssertFalse(state.isOperatingOnSkill)
    }

    @MainActor
    func testUninstallSkillClearsFailureAssociationWhenNextOperationSucceeds() async {
        let lifecycle = FailOnceSkillLifecycleSource()
        let state = AppState(skillLifecycleSource: lifecycle)
        let failedEntry = skillEntry(fileURL: URL(fileURLWithPath: "/tmp/failed/SKILL.md"))
        let succeedingEntry = skillEntry(fileURL: URL(fileURLWithPath: "/tmp/succeeding/SKILL.md"))

        await state.uninstallSkill(failedEntry)

        XCTAssertEqual(state.skillOperationFailureEntryID, failedEntry.id)

        await state.uninstallSkill(succeedingEntry)

        XCTAssertNil(state.skillOperationError)
        XCTAssertNil(state.skillOperationFailureEntryID)
        XCTAssertEqual(lifecycle.uninstalledEntryIDs, [succeedingEntry.id])
    }

    func testUninstallSkillRemovesVerifiedSkillDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillRoot = root.appendingPathComponent("skills")
        let skillFile = skillRoot.appendingPathComponent("review/SKILL.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("skill body".utf8).write(to: skillFile)

        try SkillLifecycleSource(skillRootURL: skillRoot).uninstall(skillEntry(fileURL: skillFile))

        XCTAssertFalse(FileManager.default.fileExists(atPath: skillFile.deletingLastPathComponent().path))
    }

    func testUninstallSkillRejectsPluginEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillRoot = root.appendingPathComponent("skills")
        let skillFile = skillRoot.appendingPathComponent("review/SKILL.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("skill body".utf8).write(to: skillFile)
        let entry = PluginSkillEntry(id: skillFile.path, kind: .plugin, name: "review", detail: nil, path: skillFile.path)

        XCTAssertThrowsError(try SkillLifecycleSource(skillRootURL: skillRoot).uninstall(entry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))
    }

    func testUninstallSkillRejectsSkillFileOutsideConfiguredRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillRoot = root.appendingPathComponent("skills")
        let skillFile = root.appendingPathComponent("outside/review/SKILL.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("skill body".utf8).write(to: skillFile)

        XCTAssertThrowsError(try SkillLifecycleSource(skillRootURL: skillRoot).uninstall(skillEntry(fileURL: skillFile)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))
    }

    func testUninstallSkillRejectsReadmeInsideConfiguredRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillRoot = root.appendingPathComponent("skills")
        let readme = skillRoot.appendingPathComponent("review/README.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: readme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("readme body".utf8).write(to: readme)

        XCTAssertThrowsError(try SkillLifecycleSource(skillRootURL: skillRoot).uninstall(skillEntry(fileURL: readme)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readme.path))
    }

    func testUninstallSkillRejectsMissingSkillFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillRoot = root.appendingPathComponent("skills")
        let skillDirectory = skillRoot.appendingPathComponent("review")
        let missingSkillFile = skillDirectory.appendingPathComponent("SKILL.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SkillLifecycleSource(skillRootURL: skillRoot).uninstall(skillEntry(fileURL: missingSkillFile)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDirectory.path))
    }

    func testPluginSkillSourceRecognizesOnlyCodexManifestAndSkillMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("plugins")
        let skills = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent("sample"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skills.appendingPathComponent("review"), withIntermediateDirectories: true)
        try Data("{\"name\":\"sample-plugin\",\"version\":\"1.0\",\"codex\":{}}".utf8).write(to: plugins.appendingPathComponent("sample/package.json"))
        try Data("---\nname: \"review-skill\"\ndescription: \"Read-only review helper\"\n---\nbody is not indexed\n".utf8).write(to: skills.appendingPathComponent("review/SKILL.md"))
        try Data("{\"name\":\"ordinary\"}".utf8).write(to: plugins.appendingPathComponent("ordinary.json"))

        let entries = PluginSkillSource(pluginRoot: plugins, skillRoot: skills, configURL: root.appendingPathComponent("missing.toml")).scan()

        XCTAssertEqual(entries.map(\.name).sorted(), ["review-skill", "sample-plugin"])
        XCTAssertEqual(entries.first { $0.name == "review-skill" }?.detail, "Read-only review helper")
        XCTAssertEqual(entries.filter { $0.kind == .plugin }.count, 1)
        XCTAssertEqual(entries.filter { $0.kind == .skill }.count, 1)
    }

    func testPluginSkillSourceReadsEnabledPluginsAndMCPServersFromCodexConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        try Data("[plugins.\"documents@openai-primary-runtime\"]\nenabled = true\n\n[mcp_servers.playwright]\ncommand = \"npx\"\n".utf8).write(to: config)

        let entries = PluginSkillSource(pluginRoot: root, skillRoot: root, configURL: config).scan()

        XCTAssertEqual(entries.map(\.kind), [.plugin, .mcp])
        XCTAssertEqual(entries.map(\.name), ["documents@openai-primary-runtime", "playwright"])
    }

    func testTokenActivitySourceAggregatesOnlyTimestampedUsageMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let events = [
            "{\"timestamp\":\"2026-07-14T10:00:00Z\",\"payload\":{\"info\":{\"last_token_usage\":{\"total_tokens\":120}}}}",
            "{\"timestamp\":\"2026-07-14T10:05:00Z\",\"payload\":{\"info\":{\"last_token_usage\":{\"total_tokens\":80}}}}",
            "{\"timestamp\":\"2026-07-15T11:00:00Z\",\"payload\":{\"info\":{\"last_token_usage\":{\"total_tokens\":240}}}}"
        ].joined(separator: "\n")
        try Data(events.utf8).write(to: root.appendingPathComponent("thread.jsonl"))

        let stats = TokenActivitySource(rootURL: root).scan()

        XCTAssertEqual(stats.totalTokens, 440)
        XCTAssertEqual(stats.peakTokens, 240)
        XCTAssertEqual(stats.daily.count, 2)
        XCTAssertEqual(stats.longestSessionDuration, 5 * 60)
    }

    private func snapshotRecord(capturedAt: Date, weekly: Double, short: Double) -> UsageSnapshotRecord {
        UsageSnapshotRecord(snapshot: CodexUsageSnapshot(
            plan: nil,
            shortWindow: CodexUsageWindow(remainingPercent: short, resetsAt: nil, windowSeconds: 18_000),
            weeklyWindow: CodexUsageWindow(remainingPercent: weekly, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: 1, expiresAt: []),
            updatedAt: capturedAt
        ))
    }

    private func sessionEntry(threadID: String? = "thread-id", fileURL: URL = URL(fileURLWithPath: "/tmp/thread.jsonl")) -> SessionIndexEntry {
        SessionIndexEntry(
            id: fileURL.path,
            threadID: threadID,
            title: "thread",
            filePath: fileURL.path,
            projectPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 0,
            storage: .active
        )
    }

    private func skillEntry(fileURL: URL) -> PluginSkillEntry {
        PluginSkillEntry(id: fileURL.path, kind: .skill, name: "review", detail: nil, path: fileURL.path)
    }

    private func profileSnapshotFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("profile-snapshot.json")
    }
}

private final class RecordingSessionCommandRunner: SessionCommandRunning {
    private(set) var commands: [(String, [String])] = []

    func run(executable: String, arguments: [String]) throws -> SessionCommandResult {
        commands.append((executable, arguments))
        return SessionCommandResult(status: 0, standardError: "")
    }
}

private final class ClosureSessionCommandRunner: SessionCommandRunning {
    private let operation: () throws -> SessionCommandResult

    init(operation: @escaping () throws -> SessionCommandResult) {
        self.operation = operation
    }

    func run(executable: String, arguments: [String]) throws -> SessionCommandResult {
        try operation()
    }
}

private enum TestLifecycleError: LocalizedError {
    case failed

    var errorDescription: String? { "测试生命周期操作失败" }
}

private final class RecordingLifecycleSource: SessionLifecycleManaging {
    private(set) var archivedThreadIDs: [String] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func archive(_ entry: SessionIndexEntry) throws {
        if let error { throw error }
        archivedThreadIDs.append(entry.threadID ?? "")
    }

    func unarchive(_ entry: SessionIndexEntry) throws {
        if let error { throw error }
    }

    func delete(_ entry: SessionIndexEntry) throws {
        if let error { throw error }
    }
}

private final class RecordingSkillLifecycleSource: SkillLifecycleManaging {
    private(set) var uninstalledEntryIDs: [String] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func uninstall(_ entry: PluginSkillEntry) throws {
        if let error { throw error }
        uninstalledEntryIDs.append(entry.id)
    }
}

private final class FailOnceSkillLifecycleSource: SkillLifecycleManaging {
    private(set) var uninstalledEntryIDs: [String] = []
    private var shouldFail = true

    func uninstall(_ entry: PluginSkillEntry) throws {
        if shouldFail {
            shouldFail = false
            throw TestLifecycleError.failed
        }
        uninstalledEntryIDs.append(entry.id)
    }
}
