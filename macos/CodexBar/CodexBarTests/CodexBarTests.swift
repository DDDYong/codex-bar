import AppKit
import SQLite3
import XCTest
@testable import CodexBar

final class CodexBarTests: XCTestCase {
    func testMenuBarStatusIndicatorHasNoOpaqueBackingRing() throws {
        let source = NSImage(size: NSSize(width: 20, height: 20))
        let image = MenuBarStatusIconComposer.composedImage(from: source, activity: .running)
        let representation = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))

        let visibleColors = (0..<representation.pixelsHigh).flatMap { y in
            (0..<representation.pixelsWide).compactMap { x in
                representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            }
        }.filter { $0.alphaComponent > 0.25 }

        XCTAssertFalse(visibleColors.isEmpty)
        XCTAssertTrue(visibleColors.allSatisfy { color in
            color.greenComponent > color.redComponent * 1.2
                && color.greenComponent > color.blueComponent * 1.2
        })
    }

    func testCodexActivityParserReadsAllDeviceSummary() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "summary": [
                "lifetimeTokens": 1_780_000_000,
                "peakDailyTokens": 95_005_000,
                "longestRunningTurnSec": 3_900,
                "currentStreakDays": 17,
                "longestStreakDays": 31
            ],
            "dailyUsageBuckets": [["startDate": "2026-07-13", "tokens": 51_902_000]]
        ])

        let summary = try CodexActivitySource.parseSummary(from: payload)

        XCTAssertEqual(summary.lifetimeTokens, 1_780_000_000)
        XCTAssertEqual(summary.peakDailyTokens, 95_005_000)
        XCTAssertEqual(summary.longestRunningTurnSeconds, 3_900)
        XCTAssertEqual(summary.currentStreakDays, 17)
        XCTAssertEqual(summary.longestStreakDays, 31)
        XCTAssertEqual(summary.dailyUsageBuckets, [TokenActivityDay(startDate: "2026-07-13", tokens: 51_902_000)])
    }

    func testProfileCardParserExtractsLabeledChineseMetrics() throws {
        let draft = try ProfileCardRecognizer.parse(lines: [
            "17.8亿", "累计 Token", "9500.5万", "峰值日",
            "17 天", "当前连续天数", "31 天", "最长连续使用"
        ])

        XCTAssertEqual(draft.totalTokens, 1_780_000_000)
        XCTAssertEqual(draft.peakDayTokens, 95_005_000)
        XCTAssertNil(draft.longestTaskDurationSeconds)
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

    func testProfileCardParserMatchesMetricsByCardPosition() throws {
        let draft = ProfileCardRecognizer.parse(recognizedLines: [
            RecognizedLine(text: "17.8亿", x: 0.15, y: 0.81),
            RecognizedLine(text: "9500.5万", x: 0.32, y: 0.81),
            RecognizedLine(text: "1小时5分", x: 0.49, y: 0.81),
            RecognizedLine(text: "17天", x: 0.66, y: 0.81),
            RecognizedLine(text: "31天", x: 0.83, y: 0.81),
            RecognizedLine(text: "累计 Token 数", x: 0.15, y: 0.75),
            RecognizedLine(text: "峰值 Token 数", x: 0.32, y: 0.75),
            RecognizedLine(text: "最长任务时长", x: 0.49, y: 0.75),
            RecognizedLine(text: "当前连续天数", x: 0.66, y: 0.75),
            RecognizedLine(text: "最长连续天数", x: 0.83, y: 0.75)
        ])

        XCTAssertEqual(draft.totalTokens, 1_780_000_000)
        XCTAssertEqual(draft.peakDayTokens, 95_005_000)
        XCTAssertEqual(draft.longestTaskDurationSeconds, 3_900)
        XCTAssertEqual(draft.currentStreakDays, 17)
        XCTAssertEqual(draft.longestStreakDays, 31)
    }

    @MainActor
    func testSaveProfileSnapshotPreservesExactConfirmedDraftValues() {
        let fileURL = profileSnapshotFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let state = AppState(profileSnapshotStore: ProfileSnapshotStore(fileURL: fileURL))
        let draft = ProfileSnapshotDraft(
            totalTokens: 12_345_678,
            peakDayTokens: 12_345_678,
            currentStreakDays: 17,
            longestStreakDays: 31
        )

        XCTAssertTrue(state.saveProfileSnapshot(draft))

        XCTAssertEqual(state.profileSnapshot?.totalTokens, 12_345_678)
        XCTAssertEqual(state.profileSnapshot?.peakDayTokens, 12_345_678)
        XCTAssertEqual(state.profileSnapshot?.currentStreakDays, 17)
        XCTAssertEqual(state.profileSnapshot?.longestStreakDays, 31)
    }

    func testProfileSnapshotDraftRequiresFourNonnegativeValuesBeforeSaving() {
        XCTAssertTrue(ProfileSnapshotDraft(
            totalTokens: 1,
            peakDayTokens: 2,
            currentStreakDays: 3,
            longestStreakDays: 4
        ).isReadyToSave)
        XCTAssertFalse(ProfileSnapshotDraft(
            totalTokens: 1,
            peakDayTokens: nil,
            currentStreakDays: 3,
            longestStreakDays: 4
        ).isReadyToSave)
        XCTAssertFalse(ProfileSnapshotDraft(
            totalTokens: -1,
            peakDayTokens: 2,
            currentStreakDays: 3,
            longestStreakDays: 4
        ).isReadyToSave)
    }

    @MainActor
    func testSaveProfileSnapshotFailureKeepsDraftAvailableForReview() throws {
        let blockingFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockingFileURL) }
        try Data().write(to: blockingFileURL)
        let draft = ProfileSnapshotDraft(
            totalTokens: 12_345_678,
            peakDayTokens: 12_345_678,
            currentStreakDays: 17,
            longestStreakDays: 31
        )
        let state = AppState(profileSnapshotStore: ProfileSnapshotStore(
            fileURL: blockingFileURL.appendingPathComponent("profile-snapshot.json")
        ))

        XCTAssertFalse(state.saveProfileSnapshot(draft))
        XCTAssertNil(state.profileSnapshot)
        XCTAssertNotNil(state.profileSnapshotError)
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
            longestTaskDurationSeconds: nil,
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
            longestTaskDurationSeconds: nil,
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

    func testProviderEnableToggleAllowsDisablingButBlocksEnablingDuringCredentialTest() {
        XCTAssertFalse(ProviderSettingsInteraction.isEnableToggleDisabled(isTesting: true, isEnabled: true))
        XCTAssertTrue(ProviderSettingsInteraction.isEnableToggleDisabled(isTesting: true, isEnabled: false))
        XCTAssertFalse(ProviderSettingsInteraction.isEnableToggleDisabled(isTesting: false, isEnabled: false))
    }

    func testDashboardDefaultWindowSizeMatchesMinimumWindowSize() {
        XCTAssertEqual(AppConfiguration.defaultWindowSize, AppConfiguration.minimumWindowSize)
    }

    func testDashboardTopCardsFitThreeColumnsAtMinimumWindowWidth() {
        let contentWidth = AppConfiguration.minimumWindowSize.width - 220
        let cardWidth = DashboardHomeLayout.topCardWidth(containerWidth: contentWidth)

        XCTAssertEqual(cardWidth, 232, accuracy: 0.001)
        XCTAssertEqual(
            (cardWidth * 3) + (DashboardHomeLayout.topCardSpacing * 2) + (DashboardHomeLayout.contentPadding * 2),
            contentWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(DashboardHomeLayout.metricCircleDiameter, 64)
        XCTAssertEqual(DashboardHomeLayout.usageMetricCircleDiameter, 106)
        XCTAssertGreaterThan(
            DashboardHomeLayout.usageProviderArtworkDiameter,
            DashboardHomeLayout.usageMetricCircleDiameter
        )
        XCTAssertEqual(MenuBarPanelLayout.width, 252)
        XCTAssertEqual(
            MenuBarPanelLayout.width - (MenuBarPanelLayout.horizontalPadding * 2),
            228
        )
        XCTAssertEqual(MenuBarPanelLayout.actionRowHeight, 25)
        XCTAssertEqual(MenuBarPanelLayout.maximumHeight(forVisibleScreenHeight: 500), 420)
        XCTAssertEqual(MenuBarPanelLayout.maximumHeight(forVisibleScreenHeight: 900), 620)
    }

    func testMenuBarPanelHeightUsesFallbackThenShrinksToContentAndClampsToScreen() {
        XCTAssertEqual(
            MenuBarPanelLayout.panelHeight(contentHeight: 0, visibleScreenHeight: 900),
            240
        )
        XCTAssertEqual(
            MenuBarPanelLayout.panelHeight(contentHeight: 228.2, visibleScreenHeight: 900),
            229
        )
        XCTAssertEqual(
            MenuBarPanelLayout.panelHeight(contentHeight: 480, visibleScreenHeight: 900),
            480
        )
        XCTAssertEqual(
            MenuBarPanelLayout.panelHeight(contentHeight: 800, visibleScreenHeight: 900),
            620
        )
        XCTAssertEqual(
            MenuBarPanelLayout.panelHeight(contentHeight: 800, visibleScreenHeight: 500),
            420
        )
    }

    func testUsagePageReflowsResetCardForAvailableProviders() {
        XCTAssertEqual(
            UsagePageLayout.resetPlacement(enabledProviderIDs: [], hasDeepSeekSnapshot: false),
            .besideChatGPT
        )
        XCTAssertEqual(
            UsagePageLayout.resetPlacement(enabledProviderIDs: [.deepseek], hasDeepSeekSnapshot: false),
            .besideAPITrend
        )
        XCTAssertEqual(
            UsagePageLayout.resetPlacement(enabledProviderIDs: [], hasDeepSeekSnapshot: true),
            .besideChatGPT
        )
        XCTAssertEqual(
            UsagePageLayout.resetPlacement(enabledProviderIDs: [.openRouter], hasDeepSeekSnapshot: false),
            .fullWidth
        )
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

    func testResetCreditParserReadsSupportedAppServerResponse() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [[
                    "status": "available",
                    "expiresAt": 1_786_555_834
                ]]
            ]
        ])

        let credits = try CodexUsageSource.parseResetCredits(from: payload)

        XCTAssertEqual(credits.availableCount, 1)
        XCTAssertEqual(credits.expiresAt, ["2026-08-12T17:30:34Z"])
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

        XCTAssertEqual(MenuBarPresentation.title(for: .detailed, snapshot: snapshot), "Week 68% · -- · 2 Resets")
        XCTAssertEqual(MenuBarPresentation.title(for: .compact, snapshot: snapshot), "Week 68%")
        XCTAssertEqual(MenuBarPresentation.title(for: .iconOnly, snapshot: snapshot), "")
    }

    func testMenuBarOfficialSummaryUsesEnglishWeekdayAndResetLabels() {
        let snapshot = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(
                remainingPercent: 19,
                resetsAt: "2099-01-04T12:00:00Z",
                windowSeconds: 604_800
            ),
            resetCredits: CodexResetCredits(availableCount: 1, expiresAt: []),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(MenuBarPresentation.summary(snapshot), "Week 19% · Sun · 1 Reset")
        XCTAssertEqual(
            MenuBarPresentation.resetExpiryLine(index: 0, formattedExpiry: "2099-01-04 20:00"),
            "Reset #1 · Expires 2099-01-04 20:00"
        )
        XCTAssertEqual(
            MenuBarStamp.expiryString("2026-08-12T17:30:00Z"),
            "2026-08-13 01:30"
        )
    }

    func testMenuBarShowsUnknownWhenResetCountIsUnavailable() {
        let snapshot = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(remainingPercent: 97, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: nil, expiresAt: []),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(MenuBarPresentation.summary(snapshot), "Week 97% · -- · --")
        XCTAssertEqual(MenuBarPresentation.title(for: .detailed, snapshot: snapshot), "Week 97% · -- · --")
    }

    func testResetCacheUsesOnlyFreshValuesAndFiltersExpiredGrants() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(remainingPercent: 90, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(
                availableCount: 2,
                expiresAt: [
                    ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
                    ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
                ]
            ),
            updatedAt: now.addingTimeInterval(-ResetCreditsCachePolicy.maximumAge + 1)
        )

        let merged = ResetCreditsCachePolicy.merged(
            fetched: CodexResetCredits(availableCount: nil, expiresAt: []),
            previous: previous,
            storedRecords: [],
            now: now
        )

        XCTAssertEqual(merged.availableCount, 2)
        XCTAssertEqual(merged.expiresAt, [
            ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        ])
    }

    @MainActor
    func testResetCacheRejectsStaleOrFullyExpiredValues() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(remainingPercent: 90, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: 4, expiresAt: []),
            updatedAt: now.addingTimeInterval(-ResetCreditsCachePolicy.maximumAge - 1)
        )
        let expired = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: stale.weeklyWindow,
            resetCredits: CodexResetCredits(
                availableCount: 1,
                expiresAt: [ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))]
            ),
            updatedAt: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(
            ResetCreditsCachePolicy.merged(
                fetched: CodexResetCredits(availableCount: nil, expiresAt: []),
                previous: stale,
                storedRecords: [],
                now: now
            ),
            CodexResetCredits(availableCount: nil, expiresAt: [])
        )
        XCTAssertFalse(AppState.resetDataIsAvailable(in: expired, now: now))
        XCTAssertTrue(AppState.resetDataIsAvailable(in: CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: stale.weeklyWindow,
            resetCredits: CodexResetCredits(availableCount: 0, expiresAt: []),
            updatedAt: now
        ), now: now))
    }

    func testResetNormalizationDropsCountWhenAllExpirationsArePastAndCannotRecacheIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        let expired = CodexResetCredits(
            availableCount: 2,
            expiresAt: [
                formatter.string(from: now.addingTimeInterval(-60)),
                formatter.string(from: now)
            ]
        )

        let normalized = ResetCreditsCachePolicy.currentValue(expired, now: now)

        XCTAssertEqual(normalized, CodexResetCredits(availableCount: nil, expiresAt: []))
        XCTAssertNil(ResetCreditsCachePolicy.cachedValue(
            normalized,
            capturedAt: now,
            now: now.addingTimeInterval(1)
        ))
    }

    func testMenuBarDisplayModesExplainThirdPartyContent() {
        XCTAssertEqual(MenuBarDisplayMode.detailed.thirdPartySummary, "图标 + 可用/预算/配额 + Provider 可核验明细")
        XCTAssertEqual(MenuBarDisplayMode.compact.thirdPartySummary, "图标 + 可用余额、Key 预算或配额")
        XCTAssertEqual(MenuBarDisplayMode.iconOnly.thirdPartySummary, "仅显示图标")
    }

    func testMenuBarProviderItemsKeepProviderIconAndTitlePaired() {
        let snapshot = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(remainingPercent: 68, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: 2, expiresAt: []),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let balance = ProviderBalance(
            provider: "deepseek",
            totalBalance: 11.61,
            toppedUpBalance: 11.61,
            grantedBalance: 0,
            currency: "CNY",
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let items = MenuBarPresentation.providerItems(
            for: .detailed,
            snapshot: snapshot,
            deepSeekBalance: balance,
            deepSeekConfigured: true,
            isRefreshingDeepSeek: false
        )

        XCTAssertEqual(items, [
            MenuBarProviderItem(providerType: .officialCodex, title: "Week 68% · -- · 2 Resets"),
            MenuBarProviderItem(providerType: .deepseek, title: "¥11.61 · 充值¥11.61 · 赠送¥0.00")
        ])
    }

    func testMenuBarOnlyRotatesWhenOfficialAndDeepSeekAreBothConsuming() {
        let candidates = [
            MenuBarProviderItem(providerType: .officialCodex, title: "week 80%", activity: .running),
            MenuBarProviderItem(providerType: .deepseek, title: "¥7.16", activity: .completed)
        ]

        XCTAssertEqual(
            MenuBarPresentation.visibleProviderItems(from: candidates),
            [candidates[0]]
        )

        let simultaneous = [
            candidates[0],
            MenuBarProviderItem(providerType: .deepseek, title: "¥7.16", activity: .running)
        ]
        XCTAssertEqual(MenuBarPresentation.visibleProviderItems(from: simultaneous), simultaneous)
    }

    func testMenuBarShowsOnlyDeepSeekWhenItIsTheOnlyConsumingProvider() {
        let candidates = [
            MenuBarProviderItem(providerType: .officialCodex, title: "week 80%", activity: .completed),
            MenuBarProviderItem(providerType: .deepseek, title: "¥7.16", activity: .running)
        ]

        XCTAssertEqual(
            MenuBarPresentation.visibleProviderItems(from: candidates),
            [candidates[1]]
        )
    }

    func testDeepSeekDetailsExposeOnlyVerifiableBalanceAndProxyMetrics() {
        let balance = ProviderBalance(
            provider: "deepseek",
            totalBalance: 7.16,
            toppedUpBalance: 7.00,
            grantedBalance: 0.16,
            currency: "CNY",
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(MenuBarPresentation.deepSeekDetailLines(balance: balance, proxyUsage: nil), [
            "DeepSeek: 可用余额 ¥7.16",
            "充值余额 ¥7.00 · 赠送余额 ¥0.16",
            "今日消费 / Token：当前直连链路无可核验统计"
        ])

        let usage = ProxyDailyUsage(requestCount: 3, inputTokens: 1_200, outputTokens: 300, totalCostUSD: 0.02)
        XCTAssertEqual(MenuBarPresentation.deepSeekDetailLines(balance: balance, proxyUsage: usage), [
            "DeepSeek: 可用余额 ¥7.16",
            "充值余额 ¥7.00 · 赠送余额 ¥0.16",
            "今日代理 3 次 · $0.02",
            "今日 Token 1,500（输入 1,200 · 输出 300）"
        ])
    }

    func testMenuBarProviderItemsNeverPairDeepSeekIconWithOfficialQuotaDuringBalanceRefresh() {
        let snapshot = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(remainingPercent: 99, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: 1, expiresAt: []),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let items = MenuBarPresentation.providerItems(
            for: .compact,
            snapshot: snapshot,
            deepSeekBalance: nil,
            deepSeekConfigured: true,
            isRefreshingDeepSeek: true
        )

        XCTAssertEqual(items[0], MenuBarProviderItem(providerType: .officialCodex, title: "Week 99%"))
        XCTAssertEqual(items[1], MenuBarProviderItem(providerType: .deepseek, title: "指标查询中"))
    }

    func testDeepSeekBalanceParserReadsOfficialSnakeCaseResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "is_available": true,
            "balance_infos": [[
                "currency": "CNY",
                "total_balance": "2.10",
                "topped_up_balance": "2.00",
                "granted_balance": "0.10"
            ]]
        ])
        let updatedAt = Date(timeIntervalSince1970: 123)

        let balance = try DeepSeekBalanceSource.parseBalance(from: data, updatedAt: updatedAt)

        XCTAssertEqual(balance.totalBalance, 2.10)
        XCTAssertEqual(balance.toppedUpBalance, 2.00)
        XCTAssertEqual(balance.grantedBalance, 0.10)
        XCTAssertEqual(balance.currency, "CNY")
        XCTAssertEqual(balance.updatedAt, updatedAt)
    }

    func testDeepSeekBalanceParserRejectsMalformedMoneyValues() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "is_available": true,
            "balance_infos": [[
                "currency": "CNY",
                "total_balance": "not-a-number",
                "topped_up_balance": "2.00",
                "granted_balance": "0.10"
            ]]
        ])

        XCTAssertThrowsError(try DeepSeekBalanceSource.parseBalance(from: data)) { error in
            XCTAssertEqual(error as? DeepSeekBalanceError, .invalidResponse)
        }
    }

    func testOfficialAndDeepSeekNetworkPoliciesRejectUnsafeHostsAndCrossHostRedirects() {
        let officialPolicy = FixedHostHTTPSPolicy(
            allowedHosts: ["chatgpt.com"],
            maximumResponseBytes: 1024 * 1024
        )
        let deepSeekPolicy = FixedHostHTTPSPolicy(
            allowedHosts: ["api.deepseek.com"],
            maximumResponseBytes: 64 * 1024
        )

        XCTAssertTrue(officialPolicy.allows(URL(string: "https://chatgpt.com/backend-api/api/codex/usage")))
        XCTAssertFalse(officialPolicy.allows(URL(string: "http://chatgpt.com/backend-api/api/codex/usage")))
        XCTAssertFalse(officialPolicy.allows(URL(string: "https://example.com/backend-api/api/codex/usage")))
        XCTAssertTrue(deepSeekPolicy.allows(URL(string: "https://api.deepseek.com/user/balance")))
        XCTAssertFalse(deepSeekPolicy.allows(URL(string: "https://deepseek.com/user/balance")))

        let redirectGuard = FixedHostRedirectGuard(policy: officialPolicy)
        XCTAssertNotNil(redirectGuard.allowedRedirectRequest(
            URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        ))
        XCTAssertNil(redirectGuard.allowedRedirectRequest(
            URLRequest(url: URL(string: "https://attacker.example/collect")!)
        ))
    }

    func testDeepSeekBalanceRejectsOversizedResponseAndDoesNotLeakServerBody() async {
        let oversizedSource = DeepSeekBalanceSource(
            apiKey: { "test-key" },
            session: .stubbed { _ in
                (200, Data(repeating: 0x20, count: (64 * 1024) + 1))
            }
        )

        do {
            _ = try await oversizedSource.fetchBalance()
            XCTFail("期望超大响应被拒绝")
        } catch {
            XCTAssertEqual(error as? DeepSeekBalanceError, .invalidResponse)
        }

        let body = "server-secret-body"
        let failingSource = DeepSeekBalanceSource(
            apiKey: { "test-key" },
            session: .stubbed { _ in (500, Data(body.utf8)) }
        )
        do {
            _ = try await failingSource.fetchBalance()
            XCTFail("期望服务端错误被安全映射")
        } catch {
            XCTAssertEqual(error as? DeepSeekBalanceError, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains(body))
        }
    }

    func testOfficialUsageHTTPErrorDoesNotLeakServerBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"test-access-token"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        let body = "official-server-secret-body"
        let source = CodexUsageSource(
            session: .stubbed { _ in (500, Data(body.utf8)) },
            environment: ["CODEX_HOME": root.path]
        )

        do {
            _ = try await source.fetchDashboardData()
            XCTFail("期望官方 Usage HTTP 错误被安全映射")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains(body))
        }
    }

    func testOpenRouterParserCombinesAccountCreditsKeyUsageAndBudget() throws {
        let credits = try JSONSerialization.data(withJSONObject: [
            "data": ["total_credits": 100.5, "total_usage": 25.75]
        ])
        let key = try JSONSerialization.data(withJSONObject: [
            "data": [
                "limit": 100.0,
                "limit_remaining": 74.5,
                "limit_reset": "monthly",
                "usage": 25.5,
                "usage_daily": 1.5,
                "usage_weekly": 7.5,
                "usage_monthly": 25.5
            ]
        ])
        let updatedAt = Date(timeIntervalSince1970: 123)

        let snapshot = try OpenRouterMetricsSource.parseSnapshot(
            creditsData: credits,
            keyData: key,
            updatedAt: updatedAt
        )

        XCTAssertEqual(snapshot.providerID, .openRouter)
        XCTAssertEqual(snapshot.balance?.available, 74.75)
        XCTAssertEqual(snapshot.balance?.purchased, 100.5)
        XCTAssertEqual(snapshot.spending.first { $0.period == .lifetime }?.amount, 25.75)
        XCTAssertEqual(snapshot.spending.first { $0.period == .today }?.amount, 1.5)
        XCTAssertEqual(snapshot.spending.first { $0.period == .week }?.amount, 7.5)
        XCTAssertEqual(snapshot.spending.first { $0.period == .month }?.amount, 25.5)
        XCTAssertEqual(snapshot.budget?.limit, 100)
        XCTAssertEqual(snapshot.budget?.remaining, 74.5)
        XCTAssertEqual(snapshot.budget?.resetPeriod, .monthly)
        XCTAssertEqual(snapshot.source, .providerOfficialAPI)
        XCTAssertEqual(snapshot.coverage, .accountAndAPIKey)
        XCTAssertEqual(snapshot.updatedAt, updatedAt)
    }

    func testOpenRouterParserSupportsCreditsOnlyWithoutInventingKeyMetrics() throws {
        let credits = try JSONSerialization.data(withJSONObject: [
            "data": ["total_credits": 10.0, "total_usage": 2.25]
        ])

        let snapshot = try OpenRouterMetricsSource.parseSnapshot(
            creditsData: credits,
            keyData: nil
        )

        XCTAssertEqual(snapshot.balance?.available, 7.75)
        XCTAssertEqual(snapshot.spending, [
            SpendingSnapshot(amount: 2.25, currency: "USD", period: .lifetime, isProviderReported: true)
        ])
        XCTAssertNil(snapshot.budget)
        XCTAssertEqual(snapshot.coverage, .account)
    }

    func testOpenRouterParserRejectsNonFiniteMoney() throws {
        let credits = Data(#"{"data":{"total_credits":1e999,"total_usage":1}}"#.utf8)

        XCTAssertThrowsError(
            try OpenRouterMetricsSource.parseSnapshot(creditsData: credits, keyData: nil)
        ) { error in
            XCTAssertEqual(error as? ProviderMetricsError, .invalidResponse("OpenRouter"))
        }
    }

    func testSiliconFlowParserReadsOfficialBalanceWithoutInventingSpending() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "code": 20000,
            "message": "OK",
            "status": true,
            "data": ["balance": "18.88"]
        ])
        let updatedAt = Date(timeIntervalSince1970: 456)

        let snapshot = try SiliconFlowMetricsSource.parseSnapshot(from: data, updatedAt: updatedAt)

        XCTAssertEqual(snapshot.providerID, .siliconFlow)
        XCTAssertEqual(snapshot.balance?.available, 18.88)
        XCTAssertEqual(snapshot.balance?.currency, "CNY")
        XCTAssertTrue(snapshot.spending.isEmpty)
        XCTAssertNil(snapshot.tokens)
        XCTAssertNil(snapshot.budget)
        XCTAssertEqual(snapshot.coverage, .account)
        XCTAssertEqual(snapshot.updatedAt, updatedAt)
    }

    func testOpenRouterSourceMapsRateLimitWithoutLeakingServerBody() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("test-management-key", providerID: .openRouter, kind: .managementKey)
        let session = URLSession.stubbed { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-management-key")
            return (429, Data(#"{"error":"body-must-not-surface"}"#.utf8))
        }
        let source = OpenRouterMetricsSource(credentialStore: credentialStore, session: session)

        do {
            _ = try await source.fetchSnapshot()
            XCTFail("期望 429 映射为 rateLimited")
        } catch {
            XCTAssertEqual(error as? ProviderMetricsError, .rateLimited("OpenRouter"))
            XCTAssertFalse(error.localizedDescription.contains("body-must-not-surface"))
        }
    }

    func testOpenRouterSourceKeepsKeyMetricsWhenAccountEndpointIsRateLimited() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("test-management-key", providerID: .openRouter, kind: .managementKey)
        try credentialStore.save("test-api-key", providerID: .openRouter, kind: .apiKey)
        let session = URLSession.stubbed { request in
            if request.url?.path == "/api/v1/credits" {
                return (429, Data())
            }
            return (200, Data(#"{"data":{"limit":10,"limit_remaining":8,"limit_reset":"monthly","usage":2,"usage_daily":0.5,"usage_weekly":1,"usage_monthly":2}}"#.utf8))
        }
        let source = OpenRouterMetricsSource(credentialStore: credentialStore, session: session)

        let snapshot = try await source.fetchSnapshot()

        XCTAssertNil(snapshot.balance)
        XCTAssertEqual(snapshot.budget?.remaining, 8)
        XCTAssertEqual(snapshot.coverage, .apiKey)
        XCTAssertEqual(snapshot.issues, ["账户 credits 暂不可用"])
        XCTAssertTrue(MenuBarPresentation.providerDetailLines(snapshot: snapshot).contains("状态：部分降级 · 账户 credits 暂不可用"))
    }

    @MainActor
    func testInvalidOpenRouterAPIKeyRollsBackEvenWhenManagementKeyIsValid() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("valid-management", providerID: .openRouter, kind: .managementKey)
        try credentialStore.save("previous-api", providerID: .openRouter, kind: .apiKey)
        let session = URLSession.stubbed { request in
            if request.url?.path == "/api/v1/key" {
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer invalid-api"
                    ? (401, Data())
                    : (200, Data(#"{"data":{"usage":1}}"#.utf8))
            }
            return (200, Data(#"{"data":{"total_credits":10,"total_usage":1}}"#.utf8))
        }
        let source = OpenRouterMetricsSource(credentialStore: credentialStore, session: session)
        let state = AppState(
            providerMetricsSources: [source],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )

        await state.saveAndTestProviderCredential("invalid-api", providerID: .openRouter, kind: .apiKey)

        XCTAssertEqual(try credentialStore.read(providerID: .openRouter, kind: .apiKey), "previous-api")
        XCTAssertEqual(try credentialStore.read(providerID: .openRouter, kind: .managementKey), "valid-management")
        guard case .failed(let message) = state.providerConnectionStates[.openRouter] else {
            return XCTFail("无效 API Key 应报告失败")
        }
        XCTAssertTrue(message.contains("已恢复原凭据"))
    }

    @MainActor
    func testOverlappingCredentialSavesKeepNewestSuccessfulCredential() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("stable-api", providerID: .openRouter, kind: .apiKey)
        let snapshot = providerSnapshot(
            providerID: .openRouter,
            available: 7,
            updatedAt: Date(timeIntervalSince1970: 7)
        )
        let source = ControlledCredentialProviderMetricsSource(
            providerID: .openRouter,
            credentialStore: credentialStore,
            snapshot: snapshot
        )
        let state = AppState(
            providerMetricsSources: [source],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )

        let first = Task {
            await state.saveAndTestProviderCredential("older-candidate", providerID: .openRouter, kind: .apiKey)
        }
        await source.waitForValidationCalls(1)
        let second = Task {
            await state.saveAndTestProviderCredential("newest-candidate", providerID: .openRouter, kind: .apiKey)
        }
        await source.waitForValidationCalls(2)

        XCTAssertEqual(source.validationCall(1)?.credential, "older-candidate")
        XCTAssertEqual(source.validationCall(1)?.kind, .apiKey)
        XCTAssertEqual(source.validationCall(2)?.credential, "newest-candidate")
        XCTAssertEqual(source.validationCall(2)?.kind, .apiKey)

        source.resumeValidation(call: 2, with: .success(()))
        _ = await second.value
        source.resumeValidation(call: 1, with: .failure(ProviderMetricsError.unauthorized("OpenRouter")))
        _ = await first.value

        XCTAssertEqual(try credentialStore.read(providerID: .openRouter, kind: .apiKey), "newest-candidate")
        XCTAssertEqual(state.providerSnapshots[.openRouter], snapshot)
        XCTAssertEqual(state.providerConnectionStates[.openRouter], .succeeded("连接成功，已读取官方指标。"))
    }

    @MainActor
    func testDeletingCredentialInvalidatesOlderFailedSaveWithoutRestoringSecret() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("stable-api", providerID: .openRouter, kind: .apiKey)
        let source = ControlledCredentialProviderMetricsSource(
            providerID: .openRouter,
            credentialStore: credentialStore,
            snapshot: providerSnapshot(
                providerID: .openRouter,
                available: 7,
                updatedAt: Date(timeIntervalSince1970: 7)
            )
        )
        let state = AppState(
            providerMetricsSources: [source],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )

        let save = Task {
            await state.saveAndTestProviderCredential("candidate", providerID: .openRouter, kind: .apiKey)
        }
        await source.waitForValidationCalls(1)
        state.deleteProviderCredential(providerID: .openRouter, kind: .apiKey)
        source.resumeValidation(call: 1, with: .failure(ProviderMetricsError.unauthorized("OpenRouter")))
        _ = await save.value

        XCTAssertFalse(credentialStore.contains(providerID: .openRouter, kind: .apiKey))
        XCTAssertFalse(state.isCredentialOperationActive(providerID: .openRouter, kind: .apiKey))
        XCTAssertNil(state.providerSnapshots[.openRouter])
    }

    @MainActor
    func testDisablingProviderDuringCredentialValidationRestoresVerifiedBaseline() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("verified-api", providerID: .openRouter, kind: .apiKey)
        let source = ControlledCredentialProviderMetricsSource(
            providerID: .openRouter,
            credentialStore: credentialStore,
            snapshot: providerSnapshot(
                providerID: .openRouter,
                available: 7,
                updatedAt: Date(timeIntervalSince1970: 7)
            )
        )
        let state = AppState(
            providerMetricsSources: [source],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )

        let save = Task {
            await state.saveAndTestProviderCredential("unverified-api", providerID: .openRouter, kind: .apiKey)
        }
        await source.waitForValidationCalls(1)
        state.setProviderEnabled(.openRouter, enabled: false)
        source.resumeValidation(call: 1, with: .failure(ProviderMetricsError.unauthorized("OpenRouter")))
        _ = await save.value

        XCTAssertEqual(try credentialStore.read(providerID: .openRouter, kind: .apiKey), "verified-api")
        XCTAssertFalse(state.enabledProviderIDs.contains(.openRouter))
        XCTAssertFalse(state.isCredentialOperationActive(providerID: .openRouter, kind: .apiKey))
        XCTAssertNil(state.providerSnapshots[.openRouter])
    }

    @MainActor
    func testDeletingCredentialDuringOverlappingValidationsLeavesNoCandidateSecret() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("verified-api", providerID: .openRouter, kind: .apiKey)
        let source = ControlledCredentialProviderMetricsSource(
            providerID: .openRouter,
            credentialStore: credentialStore,
            snapshot: providerSnapshot(
                providerID: .openRouter,
                available: 7,
                updatedAt: Date(timeIntervalSince1970: 7)
            )
        )
        let state = AppState(
            providerMetricsSources: [source],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )

        let first = Task {
            await state.saveAndTestProviderCredential("candidate-b", providerID: .openRouter, kind: .apiKey)
        }
        await source.waitForValidationCalls(1)
        let second = Task {
            await state.saveAndTestProviderCredential("candidate-c", providerID: .openRouter, kind: .apiKey)
        }
        await source.waitForValidationCalls(2)
        state.deleteProviderCredential(providerID: .openRouter, kind: .apiKey)
        source.resumeValidation(call: 2, with: .failure(ProviderMetricsError.unauthorized("OpenRouter")))
        source.resumeValidation(call: 1, with: .failure(ProviderMetricsError.unauthorized("OpenRouter")))
        _ = await second.value
        _ = await first.value

        XCTAssertFalse(credentialStore.contains(providerID: .openRouter, kind: .apiKey))
        XCTAssertFalse(state.isCredentialOperationActive(providerID: .openRouter, kind: .apiKey))
        XCTAssertNil(state.providerSnapshots[.openRouter])
    }

    func testSiliconFlowSourceRejectsOversizedResponse() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("test-api-key", providerID: .siliconFlow, kind: .apiKey)
        let session = URLSession.stubbed { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.siliconflow.cn/v1/user/info")
            return (200, Data(repeating: 0x20, count: (64 * 1024) + 1))
        }
        let source = SiliconFlowMetricsSource(credentialStore: credentialStore, session: session)

        do {
            _ = try await source.fetchSnapshot()
            XCTFail("期望超大响应被拒绝")
        } catch {
            XCTAssertEqual(error as? ProviderMetricsError, .invalidResponse("SiliconFlow"))
        }
    }

    func testGenericMenuBarExposesOpenRouterVerifiableMetricsWithoutSourceExplanation() {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .openRouter,
            capabilities: ProviderID.openRouter.capabilities,
            balance: MoneySnapshot(available: 74.75, purchased: 100.5, currency: "USD"),
            spending: [
                SpendingSnapshot(amount: 25.75, currency: "USD", period: .lifetime, isProviderReported: true),
                SpendingSnapshot(amount: 1.5, currency: "USD", period: .today, isProviderReported: true)
            ],
            tokens: nil,
            budget: BudgetSnapshot(limit: 100, remaining: 74.5, currency: "USD", resetPeriod: .monthly),
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .accountAndAPIKey,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        let items = MenuBarPresentation.providerItems(
            for: .detailed,
            snapshot: nil,
            providerSnapshots: [.openRouter: snapshot],
            enabledProviderIDs: [.openRouter],
            refreshingProviderIDs: []
        )

        XCTAssertEqual(items[1].providerType, .openRouter)
        XCTAssertEqual(items[1].title, "$74.75 · 今日$1.50 · Key余$74.50")
        XCTAssertEqual(MenuBarPresentation.providerDetailLines(snapshot: snapshot), [
            "OpenRouter 可用：$74.75",
            "累计已用：$25.75",
            "总充值/购买：$100.50",
            "今日消费：$1.50",
            "Key预算：$74.50 / $100.00",
            "今日 Token：当前链路无统计"
        ])
    }

    func testDeepSeekMenuBarHidesUnsupportedPlaceholdersWhenOnlyBalanceIsAvailable() {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .deepseek,
            capabilities: ProviderID.deepseek.capabilities,
            balance: MoneySnapshot(
                available: 6.84,
                toppedUp: 6.84,
                granted: 0,
                currency: "CNY"
            ),
            spending: [],
            tokens: nil,
            budget: nil,
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .account,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(MenuBarPresentation.providerDetailLines(snapshot: snapshot), [
            "DeepSeek: Today -- · Tokens --",
            "Avail ¥6.84 · Used -- · Total --"
        ])
    }

    func testDeepSeekMenuBarShowsPlatformReportedTodayAndMonthUsage() {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .deepseek,
            capabilities: ProviderID.deepseek.capabilities,
            balance: MoneySnapshot(
                available: 6.84,
                toppedUp: 6.84,
                granted: 0,
                currency: "CNY"
            ),
            spending: [
                SpendingSnapshot(amount: 3.3264104, currency: "CNY", period: .today, isProviderReported: true),
                SpendingSnapshot(amount: 4.6318424, currency: "CNY", period: .month, isProviderReported: true),
                SpendingSnapshot(amount: 13.15946292, currency: "CNY", period: .lifetime, isProviderReported: true)
            ],
            tokens: TokenUsageSnapshot(
                input: 101_992_152,
                output: 656_338,
                cached: 100_686_720,
                reasoning: nil,
                period: .today,
                coverage: .account
            ),
            budget: nil,
            source: .providerDashboard,
            confidence: .reported,
            coverage: .account,
            updatedAt: Date(timeIntervalSince1970: 123),
            todayRequestCount: 1_212
        )

        XCTAssertEqual(MenuBarPresentation.providerDetailLines(snapshot: snapshot), [
            "DeepSeek: Today ¥3.33 · Tokens 102.65M",
            "Avail ¥6.84 · Used ¥13.16 · Total ¥20.00"
        ])

        XCTAssertEqual(
            DashboardProviderPresentation.deepSeekUsageSummary(snapshot),
            "已用 ¥13.16 · 累计 ¥20.00"
        )
    }

    func testDeepSeekMenuBarAddsCumulativeSpendOnlyWhenProviderReportsIt() {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .deepseek,
            capabilities: ProviderID.deepseek.capabilities,
            balance: MoneySnapshot(available: 6.84, currency: "CNY"),
            spending: [
                SpendingSnapshot(amount: 0.32, currency: "CNY", period: .today, isProviderReported: true),
                SpendingSnapshot(amount: 11.52, currency: "CNY", period: .month, isProviderReported: true),
                SpendingSnapshot(amount: 45.67, currency: "CNY", period: .lifetime, isProviderReported: true)
            ],
            tokens: TokenUsageSnapshot(
                input: 4_313_654,
                output: 31_690,
                cached: nil,
                reasoning: nil,
                period: .today,
                coverage: .account
            ),
            budget: nil,
            source: .providerDashboard,
            confidence: .reported,
            coverage: .account,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(MenuBarPresentation.providerDetailLines(snapshot: snapshot), [
            "DeepSeek: Today ¥0.32 · Tokens 4.35M",
            "Avail ¥6.84 · Used ¥45.67 · Total ¥52.51"
        ])
    }

    func testDeepSeekPlatformUsageParserReadsReportedCostTokenAndRequestBuckets() throws {
        let amountData = Data(Self.deepSeekPlatformAmountJSON.utf8)
        let costData = Data(Self.deepSeekPlatformCostJSON.utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12))!

        let usage = try DeepSeekPlatformUsageParser.parse(
            amountData: amountData,
            costData: costData,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(usage.todayInputTokens, 101_992_152)
        XCTAssertEqual(usage.todayOutputTokens, 656_338)
        XCTAssertEqual(usage.todayCachedTokens, 100_686_720)
        XCTAssertEqual(usage.todayRequestCount, 1_212)
        XCTAssertEqual(usage.currentMonthTokens, 102_648_690)
        XCTAssertEqual(usage.currentMonthRequestCount, 1_214)
        XCTAssertEqual(usage.todayCost ?? 0, 3.3264104, accuracy: 0.000_001)
        XCTAssertEqual(usage.currentMonthCost ?? 0, 4.6318424, accuracy: 0.000_001)
        XCTAssertEqual(usage.currency, "CNY")
        XCTAssertEqual(usage.dailyUsage.count, 2)
        XCTAssertEqual(usage.dailyUsage[0].date, "2026-08-08")
        XCTAssertEqual(usage.dailyUsage[0].cost ?? 0, 1.305432, accuracy: 0.000_001)
        XCTAssertEqual(usage.dailyUsage[0].tokenCount, 200)
        XCTAssertEqual(usage.dailyUsage[0].requestCount, 2)
        XCTAssertEqual(usage.dailyUsage[1].date, "2026-08-09")
        XCTAssertEqual(usage.dailyUsage[1].cost ?? 0, 3.3264104, accuracy: 0.000_001)
    }

    func testDeepSeekPlatformUsageParserRejectsExpiredSessionEnvelope() {
        let expired = Data(#"{"code":40003,"msg":"unauthorized"}"#.utf8)

        XCTAssertThrowsError(
            try DeepSeekPlatformUsageParser.parse(amountData: expired, costData: expired)
        ) { error in
            XCTAssertEqual(error as? DeepSeekPlatformUsageError, .sessionExpired)
        }
    }

    func testDeepSeekPlatformUsageSourceAggregatesAndCachesLifetimeCostWithoutPersistingToken() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deepseek-history.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let session = URLSession.stubbed { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let month = Int(components.queryItems?.first { $0.name == "month" }?.value ?? "")!
            let date = String(format: "2024-%02d-09", month)
            if request.url?.path == "/api/v0/usage/amount" {
                return (200, Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"days":[{"date":"2024-03-09","data":[{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_MISS_TOKEN","amount":"100"},{"type":"RESPONSE_TOKEN","amount":"20"},{"type":"REQUEST","amount":"1"}]}]}],"total":[]}}}"#.utf8))
            }
            let payload = """
            {"code":0,"data":{"biz_code":0,"biz_data":[{"currency":"CNY","days":[{"date":"\(date)","data":[{"model":"deepseek-chat","usage":[{"type":"RESPONSE_TOKEN","amount":"\(month).00"}]}]}],"total":[]}]}}
            """
            return (200, Data(payload.utf8))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 9, hour: 12))!
        let source = DeepSeekPlatformUsageSource(
            session: session,
            historyCacheURL: cacheURL,
            historyStart: DateComponents(year: 2024, month: 1),
            tokenImporter: { ["test-platform-token-with-safe-length"] }
        )

        let initialUsage = try await source.fetchUsage(now: now)

        XCTAssertEqual(initialUsage.todayCost ?? 0, 3, accuracy: 0.000_001)
        XCTAssertNil(initialUsage.lifetimeCost)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: cacheURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let refreshedUsage = try await source.fetchUsage(now: now)
        XCTAssertEqual(refreshedUsage.lifetimeCost ?? 0, 6, accuracy: 0.000_001)
        let persisted = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("test-platform-token"))
    }

    func testDeepSeekMetricsSourceCombinesOfficialBalanceWithPlatformUsage() async throws {
        let balanceData = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"6.84","topped_up_balance":"6.84","granted_balance":"0.00"}]}"#.utf8)
        let balanceSource = DeepSeekBalanceSource(
            apiKey: { "test-api-key" },
            session: .stubbed { request in
                XCTAssertEqual(request.url?.host, "api.deepseek.com")
                return (200, balanceData)
            }
        )
        let platformUpdatedAt = Date().addingTimeInterval(3_600)
        let usage = DeepSeekPlatformUsage(
            todayInputTokens: 1_000,
            todayOutputTokens: 200,
            todayCachedTokens: 800,
            todayRequestCount: 3,
            currentMonthTokens: 9_000,
            currentMonthRequestCount: 20,
            todayCost: 0.12,
            currentMonthCost: 0.98,
            lifetimeCost: 3.14,
            currency: "CNY",
            updatedAt: platformUpdatedAt,
            dailyUsage: [
                DeepSeekDailyUsage(
                    date: "2026-08-09",
                    cost: 0.12,
                    tokenCount: 1_200,
                    requestCount: 3
                )
            ]
        )
        let source = DeepSeekMetricsSource(
            balanceSource: balanceSource,
            platformUsageSource: StubDeepSeekPlatformUsageSource(result: .success(usage)),
            platformUsageEnabled: { true },
            configured: { true }
        )

        let snapshot = try await source.fetchSnapshot()

        XCTAssertEqual(snapshot.balance?.available, 6.84)
        XCTAssertEqual(snapshot.spending.first { $0.period == .today }?.amount, 0.12)
        XCTAssertEqual(snapshot.spending.first { $0.period == .month }?.amount, 0.98)
        XCTAssertEqual(snapshot.spending.first { $0.period == .lifetime }?.amount, 3.14)
        XCTAssertEqual(snapshot.tokens?.input, 1_000)
        XCTAssertEqual(snapshot.tokens?.output, 200)
        XCTAssertEqual(snapshot.todayRequestCount, 3)
        XCTAssertEqual(snapshot.dailyUsage.first?.date, "2026-08-09")
        XCTAssertEqual(snapshot.dailyUsage.first?.cost, 0.12)
        XCTAssertEqual(snapshot.dailyUsage.first?.tokenCount, 1_200)
        XCTAssertEqual(snapshot.source, .providerDashboard)
        XCTAssertEqual(snapshot.confidence, .reported)
        XCTAssertEqual(snapshot.updatedAt, platformUpdatedAt)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    @MainActor
    func testDeepSeekPlatformUsageOptInPersistsWithoutStoringBrowserToken() {
        let suiteName = "CodexBarTests.DeepSeekPlatformOptIn.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        let state = AppState(settingsStore: settingsStore)

        state.setDeepSeekPlatformUsageEnabled(true)

        XCTAssertTrue(state.deepSeekPlatformUsageEnabled)
        XCTAssertTrue(settingsStore.load().deepSeekPlatformUsageEnabled)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().description.contains("userToken")
        )
    }

    func testProviderIDRecognizesSupportedCCSwitchProvidersWithoutTreatingOpenAIAsThirdParty() {
        XCTAssertEqual(ProviderID.fromCCSwitch(name: "DeepSeek", providerType: "deepseek"), .deepseek)
        XCTAssertEqual(ProviderID.fromCCSwitch(name: "MiniMax CN", providerType: "minimax"), .miniMax)
        XCTAssertEqual(ProviderID.fromCCSwitch(name: "Moonshot Kimi", providerType: "custom"), .kimi)
        XCTAssertEqual(ProviderID.fromCCSwitch(name: "智谱 GLM", providerType: "custom"), .glm)
        XCTAssertEqual(ProviderID.fromCCSwitch(name: "火山方舟", providerType: "ark"), .volcengine)
        XCTAssertEqual(ProviderID.fromCCSwitch(name: "通义千问", providerType: "dashscope"), .qwen)
        XCTAssertNil(ProviderID.fromCCSwitch(name: "OpenAI Official", providerType: "openai"))
    }

    func testCCSwitchConfigReadsOnlyTheUniqueCurrentExactDeepSeekProvider() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("cc-switch.db")
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createCCSwitchConfigDatabase(at: databaseURL, rows: [
            (
                id: "stale-deepseek",
                appType: "codex",
                name: "DeepSeek",
                providerType: "deepseek",
                settingsConfig: #"{"api_key":"stale-key"}"#,
                isCurrent: false
            ),
            (
                id: "current-deepseek",
                appType: "codex",
                name: "DeepSeek",
                providerType: "deepseek",
                settingsConfig: #"{"auth":{"OPENAI_API_KEY":"current-key"}}"#,
                isCurrent: true
            ),
            (
                id: "other-app",
                appType: "claude",
                name: "DeepSeek",
                providerType: "deepseek",
                settingsConfig: #"{"api_key":"wrong-app-key"}"#,
                isCurrent: true
            )
        ])

        let source = CCSwitchConfigSource(dbPath: databaseURL.path)

        XCTAssertEqual(source.deepSeekProviderID(), "current-deepseek")
        XCTAssertEqual(try source.readAPIKeyForDeepSeekProvider(), "current-key")
    }

    func testCCSwitchConfigRejectsLookalikeOrAmbiguousCurrentProviders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lookalikeURL = root.appendingPathComponent("lookalike.db")
        try createCCSwitchConfigDatabase(at: lookalikeURL, rows: [
            (
                id: "lookalike",
                appType: "codex",
                name: "DeepSeek Proxy",
                providerType: "custom",
                settingsConfig: #"{"api_key":"wrong-key"}"#,
                isCurrent: true
            ),
            (
                id: "inactive-exact",
                appType: "codex",
                name: "DeepSeek",
                providerType: "deepseek",
                settingsConfig: #"{"api_key":"inactive-key"}"#,
                isCurrent: false
            )
        ])
        let lookalikeSource = CCSwitchConfigSource(dbPath: lookalikeURL.path)
        XCTAssertNil(lookalikeSource.deepSeekProviderID())
        XCTAssertThrowsError(try lookalikeSource.readAPIKeyForDeepSeekProvider()) { error in
            XCTAssertEqual(error as? CCSwitchError, .noProviders)
        }

        let ambiguousURL = root.appendingPathComponent("ambiguous.db")
        try createCCSwitchConfigDatabase(at: ambiguousURL, rows: [
            (
                id: "deepseek",
                appType: "codex",
                name: "DeepSeek",
                providerType: "deepseek",
                settingsConfig: #"{"api_key":"deepseek-key"}"#,
                isCurrent: true
            ),
            (
                id: "openai",
                appType: "codex",
                name: "OpenAI",
                providerType: "openai",
                settingsConfig: #"{"api_key":"openai-key"}"#,
                isCurrent: true
            )
        ])
        let ambiguousSource = CCSwitchConfigSource(dbPath: ambiguousURL.path)
        XCTAssertNil(ambiguousSource.deepSeekProviderID())
        XCTAssertThrowsError(try ambiguousSource.readAPIKeyForDeepSeekProvider()) { error in
            XCTAssertEqual(error as? CCSwitchError, .noProviders)
        }
    }

    func testProxyUsageSourceAggregatesRecognizedProvidersAndExcludesPromptContent() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("cc-switch.db")
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_786_260_000)
        try createProxyFixtureDatabase(at: databaseURL, createdAt: Int(now.timeIntervalSince1970))

        let report = try ProxyUsageSource(dbPath: databaseURL.path).todayReport(appType: "codex", now: now)

        XCTAssertEqual(report.schemaVersion, 16)
        XCTAssertEqual(report.detectedProviderIDs, [.deepseek, .miniMax])
        XCTAssertEqual(report.usageByProvider[.deepseek], ProxyDailyUsage(
            requestCount: 2,
            successfulRequestCount: 1,
            failedRequestCount: 1,
            inputTokens: 1_200,
            outputTokens: 300,
            cacheReadTokens: 100,
            cacheCreationTokens: 20,
            totalCostUSD: 0.02,
            models: ["deepseek-chat"],
            updatedAt: now
        ))
        XCTAssertEqual(report.usageByProvider[.miniMax]?.requestCount, 1)
        XCTAssertNil(report.usageByProvider[.openRouter])
    }

    func testMiniMaxCLIParserReadsOfficialTokenPlanQuotaWithoutInventingBalance() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "model_remains": [[
                "model_name": "MiniMax-M2.1",
                "current_interval_total_count": 1_000,
                "current_interval_usage_count": 250,
                "current_weekly_total_count": 5_000,
                "current_weekly_usage_count": 1_000,
                "weekly_end_time": 1_786_864_800_000,
                "status": 1
            ]]
        ])
        let updatedAt = Date(timeIntervalSince1970: 1_786_260_000)

        let snapshot = try MiniMaxCLIMetricsSource.parseSnapshot(
            from: payload,
            version: "1.0.19",
            updatedAt: updatedAt
        )

        XCTAssertEqual(snapshot.providerID, .miniMax)
        XCTAssertNil(snapshot.balance)
        XCTAssertEqual(snapshot.quotaWindows.count, 2)
        XCTAssertEqual(snapshot.quotaWindows[0].name, "MiniMax-M2.1 · 5 小时")
        XCTAssertEqual(snapshot.quotaWindows[0].remainingPercent, 75)
        XCTAssertEqual(snapshot.quotaWindows[1].name, "MiniMax-M2.1 · 本周")
        XCTAssertEqual(snapshot.quotaWindows[1].remainingPercent, 80)
        XCTAssertEqual(snapshot.source, .localCLI)
        XCTAssertEqual(snapshot.sourceVersion, "1.0.19")
        XCTAssertEqual(snapshot.coverage, .apiKey)
    }

    func testGenericMenuBarDisplaysProxyMetricsForNonDeepSeekProvider() {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .miniMax,
            capabilities: ProviderID.miniMax.capabilities,
            balance: nil,
            spending: [],
            tokens: nil,
            budget: nil,
            quotaWindows: [],
            source: .localProxy,
            confidence: .estimated,
            coverage: .proxiedRequests,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let usage = ProxyDailyUsage(
            requestCount: 4,
            inputTokens: 2_000,
            outputTokens: 500,
            totalCostUSD: 0.03
        )

        XCTAssertEqual(MenuBarPresentation.providerDetailLines(snapshot: snapshot, proxyUsage: usage), [
            "累计已用：官方接口未提供",
            "总充值：官方接口未提供",
            "今日消费：$0.03（代理）",
            "今日 Token：2,500（代理）",
            "输入 2,000 · 输出 500",
            "今日代理请求：4次"
        ])
    }

    @MainActor
    func testExperimentalProviderRequiresMasterOptInBeforeProxySnapshotIsPublished() {
        let suiteName = "CodexBarTests.ExperimentalGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let usage = ProxyDailyUsage(
            requestCount: 1,
            inputTokens: 100,
            outputTokens: 20,
            totalCostUSD: 0.01,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let source = StubProxyUsageReader(result: .success(ProxyUsageReport(
            schemaVersion: 16,
            usageByProvider: [.miniMax: usage],
            detectedProviderIDs: [.miniMax],
            updatedAt: Date(timeIntervalSince1970: 100)
        )))
        let state = AppState(
            settingsStore: SettingsStore(defaults: defaults),
            enabledProviderIDs: [.miniMax],
            proxyUsageSource: source
        )

        state.refreshProxyUsage()
        XCTAssertFalse(state.effectiveEnabledProviderIDs.contains(.miniMax))
        XCTAssertNil(state.providerSnapshots[.miniMax])

        state.setExperimentalProvidersEnabled(true)
        XCTAssertTrue(state.effectiveEnabledProviderIDs.contains(.miniMax))
        XCTAssertEqual(state.providerSnapshots[.miniMax]?.source, .localProxy)
        XCTAssertTrue(SettingsStore(defaults: defaults).load().experimentalProvidersEnabled)
    }

    @MainActor
    func testProxyRefreshFailureKeepsLastSuccessfulTelemetryAndSurfacesSafeError() {
        let usage = ProxyDailyUsage(
            requestCount: 2,
            inputTokens: 200,
            outputTokens: 40,
            totalCostUSD: 0.02,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let source = StubProxyUsageReader(result: .success(ProxyUsageReport(
            schemaVersion: 16,
            usageByProvider: [.deepseek: usage],
            detectedProviderIDs: [.deepseek],
            updatedAt: Date(timeIntervalSince1970: 100)
        )))
        let state = AppState(
            deepSeekConfigured: true,
            enabledProviderIDs: [.deepseek],
            proxyUsageSource: source
        )

        state.refreshProxyUsage()
        source.result = .failure(ProxyUsageError.queryFailed)
        state.refreshProxyUsage()

        XCTAssertEqual(state.proxyDailyUsage, usage)
        XCTAssertEqual(state.providerSnapshots[.deepseek]?.updatedAt, usage.updatedAt)
        XCTAssertEqual(state.proxyUsageError, "cc-switch 代理日志查询失败。")
    }

    func testProviderCredentialNamespaceSeparatesProviderAndCredentialKind() {
        XCTAssertEqual(
            KeychainProviderCredentialStore.accountName(providerID: .deepseek, kind: .apiKey),
            "deepseek.api-key"
        )
        XCTAssertEqual(
            KeychainProviderCredentialStore.accountName(providerID: .openRouter, kind: .managementKey),
            "openrouter.management-key"
        )
        XCTAssertNotEqual(
            KeychainProviderCredentialStore.accountName(providerID: .openRouter, kind: .apiKey),
            KeychainProviderCredentialStore.accountName(providerID: .openRouter, kind: .managementKey)
        )
    }

    @MainActor
    func testSavingProviderCredentialUsesCredentialStoreAndNeverPersistsSecretInSettings() async throws {
        let suiteName = "CodexBarTests.ProviderCredentials.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secret = "stage1-secret-not-persisted"
        let credentialStore = InMemoryProviderCredentialStore()
        let snapshot = ProviderFinancialSnapshot(
            providerID: .openRouter,
            capabilities: ProviderID.openRouter.capabilities,
            balance: MoneySnapshot(available: 1, currency: "USD"),
            spending: [],
            tokens: nil,
            budget: nil,
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .account,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let state = AppState(
            settingsStore: SettingsStore(defaults: defaults),
            providerMetricsSources: [StubProviderMetricsSource(providerID: .openRouter, result: .success(snapshot))],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )

        await state.saveAndTestProviderCredential(secret, providerID: .openRouter, kind: .managementKey)

        XCTAssertEqual(try credentialStore.read(providerID: .openRouter, kind: .managementKey), secret)
        XCTAssertEqual(state.providerConnectionStates[.openRouter], .succeeded("连接成功，已读取官方指标。"))
        let persistedSettings = defaults.dictionaryRepresentation().values
            .compactMap { $0 as? Data }
            .reduce(into: Data()) { $0.append($1) }
        XCTAssertFalse(String(decoding: persistedSettings, as: UTF8.self).contains(secret))
    }

    @MainActor
    func testConnectionTestFetchesConfiguredProviderEvenWhenDisplayIsDisabled() async {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .siliconFlow,
            capabilities: ProviderID.siliconFlow.capabilities,
            balance: MoneySnapshot(available: 2, currency: "CNY"),
            spending: [],
            tokens: nil,
            budget: nil,
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .account,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let source = StubProviderMetricsSource(providerID: .siliconFlow, result: .success(snapshot))
        let state = AppState(providerMetricsSources: [source], enabledProviderIDs: [])

        await state.testProviderConnection(.siliconFlow)

        XCTAssertEqual(source.fetchCallCount, 1)
        XCTAssertEqual(state.providerConnectionStates[.siliconFlow], .succeeded("连接成功，已读取官方指标。"))
    }

    @MainActor
    func testAppStateRefreshesGenericProviderAndKeepsLastSuccessAfterFailure() async {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .openRouter,
            capabilities: [.accountBalance, .usageCost, .requestBudget],
            balance: MoneySnapshot(available: 7.75, purchased: 10, currency: "USD"),
            spending: [SpendingSnapshot(amount: 2.25, currency: "USD", period: .lifetime, isProviderReported: true)],
            tokens: nil,
            budget: BudgetSnapshot(limit: 5, remaining: 2.75, currency: "USD", resetPeriod: .monthly),
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .accountAndAPIKey,
            updatedAt: Date(timeIntervalSince1970: 789)
        )
        let source = StubProviderMetricsSource(providerID: .openRouter, result: .success(snapshot))
        let state = AppState(
            providerMetricsSources: [source],
            enabledProviderIDs: [.openRouter]
        )

        await state.refreshProviderMetrics()
        XCTAssertEqual(state.providerSnapshots[.openRouter], snapshot)
        XCTAssertNil(state.providerErrors[.openRouter])

        source.result = .failure(ProviderMetricsError.rateLimited("OpenRouter"))
        await state.refreshProviderMetrics()

        XCTAssertEqual(state.providerSnapshots[.openRouter], snapshot)
        XCTAssertEqual(state.providerErrors[.openRouter], "OpenRouter 请求过于频繁，请稍后重试。")
    }

    @MainActor
    func testOverlappingProviderRefreshKeepsNewestResponseAndRefreshingUntilBothFinish() async {
        let source = ControlledProviderMetricsSource(providerID: .openRouter)
        let state = AppState(providerMetricsSources: [source], enabledProviderIDs: [.openRouter])
        let old = providerSnapshot(providerID: .openRouter, available: 1, updatedAt: Date(timeIntervalSince1970: 1))
        let newest = providerSnapshot(providerID: .openRouter, available: 2, updatedAt: Date(timeIntervalSince1970: 2))

        let first = Task { await state.refreshProviderMetrics(providerID: .openRouter) }
        await source.waitForCalls(1)
        let second = Task { await state.refreshProviderMetrics(providerID: .openRouter) }
        await source.waitForCalls(2)
        source.resume(call: 2, with: .success(newest))
        _ = await second.value

        XCTAssertEqual(state.providerSnapshots[.openRouter], newest)
        XCTAssertTrue(state.refreshingProviderIDs.contains(.openRouter))

        source.resume(call: 1, with: .success(old))
        _ = await first.value
        XCTAssertEqual(state.providerSnapshots[.openRouter], newest)
        XCTAssertFalse(state.refreshingProviderIDs.contains(.openRouter))
    }

    @MainActor
    func testDisablingProviderInvalidatesInFlightRefreshResult() async {
        let source = ControlledProviderMetricsSource(providerID: .openRouter)
        let state = AppState(providerMetricsSources: [source], enabledProviderIDs: [.openRouter])
        let snapshot = providerSnapshot(
            providerID: .openRouter,
            available: 3,
            updatedAt: Date(timeIntervalSince1970: 3)
        )

        let refresh = Task { await state.refreshProviderMetrics(providerID: .openRouter) }
        await source.waitForCalls(1)
        state.setProviderEnabled(.openRouter, enabled: false)
        source.resume(call: 1, with: .success(snapshot))
        let refreshed = await refresh.value

        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertNil(state.providerSnapshots[.openRouter])
        XCTAssertNil(state.providerErrors[.openRouter])
        XCTAssertFalse(state.enabledProviderIDs.contains(.openRouter))
    }

    @MainActor
    func testDeletingLastCredentialInvalidatesInFlightRefreshResult() async throws {
        let credentialStore = InMemoryProviderCredentialStore()
        try credentialStore.save("api-key", providerID: .openRouter, kind: .apiKey)
        let source = ControlledProviderMetricsSource(
            providerID: .openRouter,
            isConfigured: {
                credentialStore.contains(providerID: .openRouter, kind: .apiKey)
            }
        )
        let state = AppState(
            providerMetricsSources: [source],
            providerCredentialStore: credentialStore,
            enabledProviderIDs: [.openRouter]
        )
        let snapshot = providerSnapshot(
            providerID: .openRouter,
            available: 3,
            updatedAt: Date(timeIntervalSince1970: 3)
        )

        let refresh = Task { await state.refreshProviderMetrics(providerID: .openRouter) }
        await source.waitForCalls(1)
        state.deleteProviderCredential(providerID: .openRouter, kind: .apiKey)
        source.resume(call: 1, with: .success(snapshot))
        let refreshed = await refresh.value

        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertNil(state.providerSnapshots[.openRouter])
        XCTAssertEqual(state.providerErrors[.openRouter], "OpenRouter API Key 未配置。")
    }

    @MainActor
    func testDataSourceListOnlyIncludesReadOnlyProxyTelemetryWhenProxyIsConfigured() {
        let balanceOnlyState = AppState(
            deepSeekConfigured: true,
            enabledProviderIDs: [.deepseek]
        )
        let proxyState = AppState(
            deepSeekConfigured: true,
            enabledProviderIDs: [.deepseek],
            proxyUsageSource: ProxyUsageSource(dbPath: "/tmp/missing-cc-switch.db"),
            deepSeekProviderID: "deepseek-test"
        )

        XCTAssertEqual(balanceOnlyState.totalDataSourceCount, 6)
        XCTAssertTrue(balanceOnlyState.dataSourceStatuses.contains { $0.name == "DeepSeek 余额" })
        XCTAssertFalse(balanceOnlyState.dataSourceStatuses.contains { $0.name == "cc-switch 代理遥测" })
        XCTAssertEqual(proxyState.totalDataSourceCount, 7)
        XCTAssertTrue(proxyState.dataSourceStatuses.contains { $0.name == "cc-switch 代理遥测" })
    }

    @MainActor
    func testMenuBarRotationSwitchesProviderAndPresentationAsOneItem() {
        let source = StubSessionActivitySource(activities: ProviderActivitySnapshot(
            officialCodex: .running,
            deepSeek: .running
        ))
        let state = AppState(
            sessionSource: source,
            deepSeekConfigured: true,
            enabledProviderIDs: [.deepseek]
        )
        state.refreshSessionActivity()

        XCTAssertEqual(state.menuBarProviderItem.providerType, .officialCodex)

        state.advanceMenuBarProvider()

        XCTAssertEqual(state.menuBarProviderItem.providerType, .deepseek)
        XCTAssertNotEqual(state.menuBarProviderItem.title, "week --")
    }

    func testProviderActivitySourceClassifiesNativeDeepSeekChildWithoutReadingMessageText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let official = root.appendingPathComponent("official.jsonl")
        let deepSeek = root.appendingPathComponent("deepseek.jsonl")
        let now = Date(timeIntervalSince1970: 1_786_260_000)

        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "custom", "agent_role": "explorer"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning"]]
        ], to: official, modifiedAt: now)
        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "custom", "agent_role": "DeepSeek"]],
            ["type": "turn_context", "payload": ["model": "deepseek-v4-flash"]],
            ["type": "event_msg", "payload": ["type": "task_started"]],
            ["type": "event_msg", "payload": ["type": "agent_message"]]
        ], to: deepSeek, modifiedAt: now)

        let activities = SessionActivitySource(
            roots: [.init(url: root, providerHint: nil)],
            now: { now }
        ).liveActivities()

        XCTAssertEqual(activities.officialCodex, .running)
        XCTAssertEqual(activities.deepSeek, .running)
        XCTAssertTrue(activities.isSimultaneouslyConsuming)
    }

    func testProviderActivitySourceClassifiesOpenRouterAndSiliconFlowSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let openRouter = root.appendingPathComponent("openrouter.jsonl")
        let siliconFlow = root.appendingPathComponent("siliconflow.jsonl")
        let now = Date(timeIntervalSince1970: 1_786_260_000)

        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "openrouter"]],
            ["type": "event_msg", "payload": ["type": "task_started"]]
        ], to: openRouter, modifiedAt: now)
        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "siliconflow"]],
            ["type": "event_msg", "payload": ["type": "task_started"]]
        ], to: siliconFlow, modifiedAt: now)

        let activities = SessionActivitySource(
            roots: [.init(url: root, providerHint: nil)],
            now: { now }
        ).liveActivities()

        XCTAssertEqual(activities.activity(for: .openRouter), .running)
        XCTAssertEqual(activities.activity(for: .siliconFlow), .running)
    }

    func testProviderActivitySourceClassifiesExperimentalProviderSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("minimax.jsonl")
        let now = Date(timeIntervalSince1970: 1_786_260_000)
        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "custom", "agent_role": "MiniMax"]],
            ["type": "turn_context", "payload": ["model": "MiniMax-M2.1"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning"]]
        ], to: session, modifiedAt: now)

        let activities = SessionActivitySource(
            roots: [.init(url: root, providerHint: nil)],
            now: { now }
        ).liveActivities()

        XCTAssertEqual(activities.activity(for: ProviderID.miniMax.providerType), .running)
    }

    func testProviderActivitySourceDoesNotTreatStaleRunningEventAsLiveConsumption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("stale.jsonl")
        let now = Date(timeIntervalSince1970: 1_786_260_000)
        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "deepseek"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning"]]
        ], to: session, modifiedAt: now.addingTimeInterval(-181))

        let activities = SessionActivitySource(
            roots: [.init(url: root, providerHint: nil)],
            now: { now },
            liveEventWindow: 180
        ).liveActivities()

        XCTAssertEqual(activities.deepSeek, .unknown)
        XCTAssertFalse(activities.isSimultaneouslyConsuming)
    }

    func testProviderActivitySourceScansCurrentDateDirectoryWithoutRecursingUnrelatedTrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_786_260_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let today = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "openai"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning"]]
        ], to: today.appendingPathComponent("official.jsonl"), modifiedAt: now)
        try writeSessionEvents([
            ["type": "session_meta", "payload": ["model_provider": "deepseek"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning"]]
        ], to: unrelated.appendingPathComponent("ignored.jsonl"), modifiedAt: now)

        let activities = SessionActivitySource(
            roots: [.init(url: root, providerHint: nil)],
            now: { now }
        ).liveActivities()

        XCTAssertEqual(activities.officialCodex, .running)
        XCTAssertEqual(activities.deepSeek, .unknown)
    }

    func testProviderActivitySourceParsesCompleteJSONLAfterChineseUTF8TailBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("utf8-boundary.jsonl")
        let now = Date(timeIntervalSince1970: 1_786_260_000)
        let metadata = #"{"type":"session_meta","payload":{"model_provider":"deepseek"}}"# + "\n"
        let terminalEvent = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
        var boundaryData: Data?

        for padding in 0..<3 {
            let oversizedLine = #"{"type":"event_msg","payload":{"type":"message","text":""#
                + String(repeating: "中", count: 100_000)
                + String(repeating: "x", count: padding)
                + #""}}"#
                + "\n"
            let candidate = Data((metadata + oversizedLine + terminalEvent).utf8)
            let tailStart = candidate.count - (256 * 1024)
            if candidate[tailStart] & 0xC0 == 0x80 {
                boundaryData = candidate
                break
            }
        }
        let data = try XCTUnwrap(boundaryData)
        try data.write(to: session)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: session.path)

        let activities = SessionActivitySource(
            roots: [.init(url: root, providerHint: nil)],
            now: { now }
        ).liveActivities()

        XCTAssertEqual(activities.deepSeek, .running)
    }

    func testSessionActivityIndicatorSemanticsMatchUserVisibleState() {
        XCTAssertEqual(SessionActivity.running.indicatorStyle, .active)
        XCTAssertEqual(SessionActivity.waiting.indicatorStyle, .attention)
        XCTAssertEqual(SessionActivity.failed.indicatorStyle, .failure)
        XCTAssertEqual(SessionActivity.completed.indicatorStyle, .idle)
        XCTAssertEqual(SessionActivity.unknown.indicatorStyle, .idle)
    }

    func testSessionActivityPrioritizesRunningThenWaitingThenFailure() {
        XCTAssertEqual(SessionActivity.aggregate([.completed, .running]), .running)
        XCTAssertEqual(SessionActivity.aggregate([.completed, .waiting]), .waiting)
        XCTAssertEqual(SessionActivity.aggregate([.completed, .failed]), .failed)
    }

    func testSessionActivityMapsRecentEventTypesWithoutReadingPayloads() {
        XCTAssertEqual(SessionActivity.from(eventTypes: ["task_complete"]), .completed)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["reasoning", "custom_tool_call"]), .running)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["task_started", "agent_message"]), .running)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["task_started", "message"]), .running)
        XCTAssertEqual(SessionActivity.from(eventTypes: ["agent_message", "task_complete"]), .completed)
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

    func testSnapshotStorePersistsResetCreditExpirations() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage-snapshots.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = SnapshotStore(fileURL: fileURL)
        let record = UsageSnapshotRecord(snapshot: CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(
                remainingPercent: 93,
                resetsAt: "2026-08-18T01:36:00Z",
                windowSeconds: 604_800
            ),
            resetCredits: CodexResetCredits(
                availableCount: 1,
                expiresAt: ["2026-08-12T17:30:34Z"]
            ),
            updatedAt: Date(timeIntervalSince1970: 1_786_555_834)
        ))

        try store.append(record)

        let loaded = try XCTUnwrap(SnapshotStore(fileURL: fileURL).load().last)
        XCTAssertEqual(loaded.resetCredits, 1)
        XCTAssertEqual(loaded.resetCreditExpirations, ["2026-08-12T17:30:34Z"])
    }

    func testProviderSnapshotRecordKeepsOwnFreshnessAndDecodesLegacyRecordsAsStale() throws {
        let cycleStart = Date(timeIntervalSince1970: 200)
        let snapshot = providerSnapshot(
            providerID: .deepseek,
            available: 6.84,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let record = ProviderUsageSnapshotRecord(snapshot: snapshot, cycleStartedAt: cycleStart)

        XCTAssertEqual(record.updatedAt, snapshot.updatedAt)
        XCTAssertEqual(record.source, .providerOfficialAPI)
        XCTAssertTrue(record.isStale)

        let legacy = Data(#"{"providerID":"deepseek","available":6.84,"currency":"CNY"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderUsageSnapshotRecord.self, from: legacy)
        XCTAssertNil(decoded.updatedAt)
        XCTAssertNil(decoded.source)
        XCTAssertTrue(decoded.isStale)
    }

    func testManualSnapshotUsesNewCaptureTimeWithoutReplacingOfficialRecord() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage-snapshots.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = SnapshotStore(fileURL: fileURL)
        let officialUpdatedAt = Date(timeIntervalSince1970: 1_786_000_000)
        let manualCapturedAt = officialUpdatedAt.addingTimeInterval(30)
        let snapshot = CodexUsageSnapshot(
            plan: nil,
            shortWindow: nil,
            weeklyWindow: CodexUsageWindow(
                remainingPercent: 80,
                resetsAt: nil,
                windowSeconds: 604_800
            ),
            resetCredits: CodexResetCredits(availableCount: nil, expiresAt: []),
            updatedAt: officialUpdatedAt
        )
        let officialRecord = UsageSnapshotRecord(snapshot: snapshot)
        let manualRecord = UsageSnapshotRecord(snapshot: snapshot, capturedAt: manualCapturedAt)

        try store.append(officialRecord)
        try store.append(manualRecord, deduplicate: false)

        let records = store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.capturedAt), [officialUpdatedAt, manualCapturedAt])
        XCTAssertEqual(records.first?.id, officialRecord.id)
    }

    func testUsageHistoryPresentationLabelsStaleProviderWithoutShowingAmountsOrTokens() {
        let snapshot = ProviderFinancialSnapshot(
            providerID: .deepseek,
            capabilities: ProviderID.deepseek.capabilities,
            balance: MoneySnapshot(available: 6.84, currency: "CNY"),
            spending: [SpendingSnapshot(amount: 0.12, currency: "CNY", period: .today, isProviderReported: true)],
            tokens: TokenUsageSnapshot(
                input: 1_000,
                output: 200,
                cached: nil,
                reasoning: nil,
                period: .today,
                coverage: .account
            ),
            budget: nil,
            source: .providerDashboard,
            confidence: .reported,
            coverage: .account,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let stale = ProviderUsageSnapshotRecord(
            snapshot: snapshot,
            cycleStartedAt: Date(timeIntervalSince1970: 200)
        )
        let fresh = ProviderUsageSnapshotRecord(
            snapshot: snapshot,
            cycleStartedAt: Date(timeIntervalSince1970: 50)
        )

        XCTAssertEqual(
            UsageHistoryPresentation.providerValues(stale),
            UsageHistoryProviderValues(available: "陈旧", todaySpend: "--", todayTokens: "--")
        )
        XCTAssertNotEqual(UsageHistoryPresentation.providerValues(fresh).available, "陈旧")
        XCTAssertNotEqual(UsageHistoryPresentation.providerValues(fresh).todaySpend, "--")
        XCTAssertEqual(UsageHistoryPresentation.providerValues(fresh).todayTokens, "1200")
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
            pluginSkillIndexEnabled: true,
            tokenHeatmapPeriod: .threeMonths
        )

        store.save(settings)

        XCTAssertEqual(SettingsStore(defaults: defaults).load(), settings)
    }

    func testSettingsStoreRoundTripsEnabledProviderIDs() {
        let suiteName = "CodexBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = AppSettings.default
        settings.enabledProviderIDs = [.deepseek, .openRouter]

        let store = SettingsStore(defaults: defaults)
        store.save(settings)

        XCTAssertEqual(store.load().enabledProviderIDs, [.deepseek, .openRouter])
    }

    func testSettingsStoreDefaultsExperimentalProvidersOffAndPersistsOptIn() {
        let suiteName = "CodexBarTests.ExperimentalProviders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.load().experimentalProvidersEnabled)

        var settings = AppSettings.default
        settings.experimentalProvidersEnabled = true
        settings.enabledProviderIDs = [.miniMax, .kimi]
        store.save(settings)

        XCTAssertTrue(store.load().experimentalProvidersEnabled)
        XCTAssertEqual(store.load().enabledProviderIDs, [.miniMax, .kimi])
    }

    @MainActor
    func testSettingsPageUpdateDoesNotOverwriteProviderFeatureSwitchesFromStaleCopy() {
        let suiteName = "CodexBarTests.SettingsMerge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let state = AppState(settingsStore: store)
        var staleSettingsPageCopy = state.settings()

        state.setExperimentalProvidersEnabled(true)
        state.setDeepSeekPlatformUsageEnabled(true)
        staleSettingsPageCopy.theme = .dark
        state.updateSettings(staleSettingsPageCopy)

        let persisted = store.load()
        XCTAssertEqual(persisted.theme, .dark)
        XCTAssertTrue(persisted.experimentalProvidersEnabled)
        XCTAssertTrue(persisted.deepSeekPlatformUsageEnabled)
    }

    @MainActor
    func testSettingsPageStaleCopyDoesNotOverwriteLaunchAtLoginIntent() {
        let suiteName = "CodexBarTests.SettingsLaunchMerge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let manager = RecordingLaunchAtLoginManager(status: .notRegistered)
        let state = AppState(settingsStore: store, launchAtLoginManager: manager)
        var staleSettingsPageCopy = state.settings()

        state.setLaunchAtLoginEnabled(true)
        staleSettingsPageCopy.theme = .dark
        state.updateSettings(staleSettingsPageCopy)

        XCTAssertEqual(store.load().theme, .dark)
        XCTAssertEqual(store.load().launchAtLoginRequested, true)
        XCTAssertEqual(manager.registerCallCount, 1)
        XCTAssertEqual(manager.unregisterCallCount, 0)
    }

    @MainActor
    func testLaunchAtLoginIntentSurvivesAppReplacementAndReregisters() {
        let suiteName = "CodexBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        var settings = AppSettings.default
        settings.launchAtLoginRequested = true
        settingsStore.save(settings)
        let manager = RecordingLaunchAtLoginManager(status: .notRegistered)
        let state = AppState(settingsStore: settingsStore, launchAtLoginManager: manager)

        state.reconcileLaunchAtLogin()

        XCTAssertEqual(manager.registerCallCount, 1)
        XCTAssertTrue(state.launchAtLoginEnabled)
        XCTAssertNil(state.launchAtLoginError)
    }

    @MainActor
    func testLaunchAtLoginMigrationPreservesAnExistingSystemRegistration() {
        let suiteName = "CodexBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let manager = RecordingLaunchAtLoginManager(status: .enabled)

        let state = AppState(settingsStore: store, launchAtLoginManager: manager)

        XCTAssertTrue(state.launchAtLoginEnabled)
        XCTAssertEqual(store.load().launchAtLoginRequested, true)
    }

    func testLaunchAtLoginFactoryDisablesServiceManagementInsideXCTestHost() {
        let manager = LaunchAtLoginManagerFactory.make(environment: [
            "XCTestConfigurationFilePath": "/tmp/CodexBarTests.xctestconfiguration"
        ])

        XCTAssertTrue(manager is DisabledLaunchAtLoginManager)
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

    private func snapshotRecord(capturedAt: Date, weekly: Double, short: Double) -> UsageSnapshotRecord {
        UsageSnapshotRecord(snapshot: CodexUsageSnapshot(
            plan: nil,
            shortWindow: CodexUsageWindow(remainingPercent: short, resetsAt: nil, windowSeconds: 18_000),
            weeklyWindow: CodexUsageWindow(remainingPercent: weekly, resetsAt: nil, windowSeconds: 604_800),
            resetCredits: CodexResetCredits(availableCount: 1, expiresAt: []),
            updatedAt: capturedAt
        ))
    }

    private func providerSnapshot(
        providerID: ProviderID,
        available: Double,
        updatedAt: Date
    ) -> ProviderFinancialSnapshot {
        ProviderFinancialSnapshot(
            providerID: providerID,
            capabilities: providerID.capabilities,
            balance: MoneySnapshot(available: available, currency: providerID == .openRouter ? "USD" : "CNY"),
            spending: [],
            tokens: nil,
            budget: nil,
            source: .providerOfficialAPI,
            confidence: .verified,
            coverage: .account,
            updatedAt: updatedAt
        )
    }

    private static let deepSeekPlatformAmountJSON = #"""
    {
      "code": 0,
      "data": {
        "biz_code": 0,
        "biz_data": {
          "total": [],
          "days": [
            {
              "date": "2026-08-08",
              "data": [{
                "model": "deepseek-v4-flash",
                "usage": [
                  {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "100"},
                  {"type": "RESPONSE_TOKEN", "amount": "100"},
                  {"type": "REQUEST", "amount": "2"}
                ]
              }]
            },
            {
              "date": "2026-08-09",
              "data": [{
                "model": "deepseek-v4-flash",
                "usage": [
                  {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                  {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1305432"},
                  {"type": "RESPONSE_TOKEN", "amount": "656338"},
                  {"type": "REQUEST", "amount": "1212"}
                ]
              }]
            }
          ]
        }
      }
    }
    """#

    private static let deepSeekPlatformCostJSON = #"""
    {
      "code": 0,
      "data": {
        "biz_code": 0,
        "biz_data": [{
          "currency": "CNY",
          "total": [],
          "days": [
            {
              "date": "2026-08-08",
              "data": [{
                "model": "deepseek-v4-flash",
                "usage": [
                  {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1.0000000"},
                  {"type": "RESPONSE_TOKEN", "amount": "0.3054320"}
                ]
              }]
            },
            {
              "date": "2026-08-09",
              "data": [{
                "model": "deepseek-v4-flash",
                "usage": [
                  {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344"},
                  {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0"},
                  {"type": "RESPONSE_TOKEN", "amount": "1.3126760"}
                ]
              }]
            }
          ]
        }]
      }
    }
    """#

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

    private func writeSessionEvents(
        _ events: [[String: Any]],
        to fileURL: URL,
        modifiedAt: Date
    ) throws {
        let lines = try events.map { event in
            String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)
    }

    private func profileSnapshotFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("profile-snapshot.json")
    }

    private func createProxyFixtureDatabase(at url: URL, createdAt: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CodexBarTests.SQLite", code: 1)
        }
        defer { sqlite3_close(database) }

        let statements = [
            "PRAGMA user_version = 16",
            "CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT NOT NULL, provider_type TEXT, PRIMARY KEY (id, app_type))",
            "CREATE TABLE proxy_request_logs (provider_id TEXT, app_type TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, total_cost_usd TEXT, status_code INTEGER, created_at INTEGER)",
            "INSERT INTO providers VALUES ('ds', 'codex', 'DeepSeek', 'deepseek')",
            "INSERT INTO providers VALUES ('mm', 'codex', 'MiniMax CN', 'minimax')",
            "INSERT INTO providers VALUES ('official', 'codex', 'OpenAI Official', 'openai')",
            "INSERT INTO proxy_request_logs VALUES ('ds', 'codex', 'deepseek-chat', 1000, 200, 100, 20, '0.01', 200, \(createdAt))",
            "INSERT INTO proxy_request_logs VALUES ('ds', 'codex', 'deepseek-chat', 200, 100, 0, 0, '0.01', 500, \(createdAt))",
            "INSERT INTO proxy_request_logs VALUES ('mm', 'codex', 'MiniMax-M2.1', 400, 50, 0, 0, '0.005', 200, \(createdAt))",
            "INSERT INTO proxy_request_logs VALUES ('official', 'codex', 'gpt-5', 999, 999, 0, 0, '9.99', 200, \(createdAt))"
        ]
        for statement in statements {
            var errorMessage: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(database, statement, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
                sqlite3_free(errorMessage)
                throw NSError(domain: "CodexBarTests.SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    private func createCCSwitchConfigDatabase(
        at url: URL,
        rows: [(
            id: String,
            appType: String,
            name: String,
            providerType: String,
            settingsConfig: String,
            isCurrent: Bool
        )]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CodexBarTests.SQLite", code: 3)
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let createSQL = """
        CREATE TABLE providers (
            id TEXT,
            app_type TEXT,
            name TEXT,
            provider_type TEXT,
            settings_config TEXT,
            is_current INTEGER
        )
        """
        guard sqlite3_exec(database, createSQL, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "CodexBarTests.SQLite",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let insertSQL = """
        INSERT INTO providers (id, app_type, name, provider_type, settings_config, is_current)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        for row in rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw NSError(domain: "CodexBarTests.SQLite", code: 5)
            }
            defer { sqlite3_finalize(statement) }
            let values = [row.id, row.appType, row.name, row.providerType, row.settingsConfig]
            for (index, value) in values.enumerated() {
                let result = value.withCString {
                    sqlite3_bind_text(
                        statement,
                        Int32(index + 1),
                        $0,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
                guard result == SQLITE_OK else {
                    throw NSError(domain: "CodexBarTests.SQLite", code: 6)
                }
            }
            sqlite3_bind_int(statement, 6, row.isCurrent ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "CodexBarTests.SQLite", code: 7)
            }
        }
    }
}

private struct StubSessionActivitySource: SessionActivityReading {
    let activities: ProviderActivitySnapshot

    func liveActivities() -> ProviderActivitySnapshot { activities }
}

private final class InMemoryProviderCredentialStore: ProviderCredentialStoring {
    private var values: [String: String] = [:]

    func contains(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool {
        values[KeychainProviderCredentialStore.accountName(providerID: providerID, kind: kind)] != nil
    }

    func read(providerID: ProviderID, kind: ProviderCredentialKind) throws -> String {
        guard let value = values[KeychainProviderCredentialStore.accountName(providerID: providerID, kind: kind)] else {
            throw ProviderCredentialStoreError.notFound
        }
        return value
    }

    func save(_ credential: String, providerID: ProviderID, kind: ProviderCredentialKind) throws {
        values[KeychainProviderCredentialStore.accountName(providerID: providerID, kind: kind)] = credential
    }

    func delete(providerID: ProviderID, kind: ProviderCredentialKind) throws {
        values[KeychainProviderCredentialStore.accountName(providerID: providerID, kind: kind)] = nil
    }
}

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (statusCode: Int, data: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLSession {
    static func stubbed(
        handler: @escaping (URLRequest) throws -> (statusCode: Int, data: Data)
    ) -> URLSession {
        StubURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubProviderMetricsSource: ProviderMetricsSource, ProviderCredentialValidating {
    let providerID: ProviderID
    let capabilities: ProviderCapabilities
    var result: Result<ProviderFinancialSnapshot, Error>
    var isConfigured: Bool
    private(set) var fetchCallCount = 0

    init(
        providerID: ProviderID,
        capabilities: ProviderCapabilities = [.accountBalance, .usageCost, .requestBudget],
        isConfigured: Bool = true,
        result: Result<ProviderFinancialSnapshot, Error>
    ) {
        self.providerID = providerID
        self.capabilities = capabilities
        self.isConfigured = isConfigured
        self.result = result
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot {
        fetchCallCount += 1
        return try result.get()
    }

    func validateCredential(kind: ProviderCredentialKind) async throws {}
}

private final class ControlledProviderMetricsSource: ProviderMetricsSource {
    let providerID: ProviderID
    let capabilities: ProviderCapabilities
    private let configured: () -> Bool
    var isConfigured: Bool { configured() }
    private let lock = NSLock()
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<ProviderFinancialSnapshot, Error>] = [:]

    init(providerID: ProviderID, isConfigured: @escaping () -> Bool = { true }) {
        self.providerID = providerID
        capabilities = providerID.capabilities
        configured = isConfigured
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            callCount += 1
            continuations[callCount] = continuation
            lock.unlock()
        }
    }

    func waitForCalls(_ expected: Int) async {
        for _ in 0..<200 {
            if hasReachedCallCount(expected) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func hasReachedCallCount(_ expected: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return callCount >= expected
    }

    func resume(call: Int, with result: Result<ProviderFinancialSnapshot, Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: call)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class ControlledCredentialProviderMetricsSource: ProviderMetricsSource, ProviderCredentialValidating {
    struct ValidationCall {
        let kind: ProviderCredentialKind
        let credential: String
    }

    let providerID: ProviderID
    let capabilities: ProviderCapabilities
    private let credentialStore: ProviderCredentialStoring
    private let snapshot: ProviderFinancialSnapshot
    private let lock = NSLock()
    private var callCount = 0
    private var calls: [Int: ValidationCall] = [:]
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]

    init(
        providerID: ProviderID,
        credentialStore: ProviderCredentialStoring,
        snapshot: ProviderFinancialSnapshot
    ) {
        self.providerID = providerID
        capabilities = providerID.capabilities
        self.credentialStore = credentialStore
        self.snapshot = snapshot
    }

    var isConfigured: Bool {
        providerID.credentialKinds.contains {
            credentialStore.contains(providerID: providerID, kind: $0)
        }
    }

    func fetchSnapshot() async throws -> ProviderFinancialSnapshot { snapshot }

    func validateCredential(kind: ProviderCredentialKind) async throws {
        let credential = try credentialStore.read(providerID: providerID, kind: kind)
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            callCount += 1
            calls[callCount] = ValidationCall(kind: kind, credential: credential)
            continuations[callCount] = continuation
            lock.unlock()
        }
    }

    func waitForValidationCalls(_ expected: Int) async {
        for _ in 0..<200 {
            if hasReachedValidationCallCount(expected) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func hasReachedValidationCallCount(_ expected: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return callCount >= expected
    }

    func validationCall(_ call: Int) -> ValidationCall? {
        lock.lock()
        defer { lock.unlock() }
        return calls[call]
    }

    func resumeValidation(call: Int, with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: call)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class StubDeepSeekPlatformUsageSource: DeepSeekPlatformUsageReading {
    let result: Result<DeepSeekPlatformUsage, Error>

    init(result: Result<DeepSeekPlatformUsage, Error>) {
        self.result = result
    }

    func fetchUsage(now: Date) async throws -> DeepSeekPlatformUsage {
        try result.get()
    }
}

private final class StubProxyUsageReader: ProxyUsageReading {
    var result: Result<ProxyUsageReport, Error>

    init(result: Result<ProxyUsageReport, Error>) {
        self.result = result
    }

    func todayReport(appType: String, now: Date) throws -> ProxyUsageReport {
        try result.get()
    }
}

private final class RecordingLaunchAtLoginManager: LaunchAtLoginManaging {
    private(set) var status: LaunchAtLoginStatus
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }

    func openSystemSettings() {}
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
