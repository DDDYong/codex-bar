import AppKit
import SwiftUI

struct CodexBarIcon: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "128x128", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "chart.pie.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.19)
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ProviderMenuBarIcon: View {
    let providerType: ProviderType
    let activity: SessionActivity

    var body: some View {
        if let image = Self.images[IconKey(providerType: providerType, activity: activity)] {
            Image(nsImage: image)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "chart.pie")
                .font(.system(size: 16, weight: .medium))
        }
    }

    private struct IconKey: Hashable {
        let providerType: ProviderType
        let activity: SessionActivity
    }

    private static let images: [IconKey: NSImage] = {
        let providerTypes: [ProviderType] = [.officialCodex] + ProviderID.allCases.map(\.providerType)
        let activities: [SessionActivity] = [.running, .waiting, .completed, .failed, .unknown]
        return Dictionary(uniqueKeysWithValues: providerTypes.flatMap { providerType in
            activities.compactMap { activity in
                guard let source = ProviderIconHelper.icon(for: providerType) else { return nil }
                return (
                    IconKey(providerType: providerType, activity: activity),
                    MenuBarStatusIconComposer.composedImage(from: source, activity: activity)
                )
            }
        })
    }()
}

enum MenuBarStatusIconComposer {
    static func composedImage(from source: NSImage, activity: SessionActivity) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        source.draw(
            in: NSRect(x: 0, y: 1, width: 18.5, height: 18.5),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        let indicatorRect = NSRect(x: 13.5, y: 0, width: 6, height: 6)
        statusColor(for: activity).setFill()
        NSBezierPath(ovalIn: indicatorRect).fill()
        image.unlockFocus()
        return image
    }

    private static func statusColor(for activity: SessionActivity) -> NSColor {
        switch activity.indicatorStyle {
        case .active: .systemGreen
        case .attention: .systemOrange
        case .failure: .systemRed
        case .idle: .secondaryLabelColor
        }
    }
}

@main
struct CodexBarApp: App {
    @StateObject private var appState: AppState

    init() {
        let ccSwitchSource = CCSwitchConfigSource()
        let settingsStore = SettingsStore()
        let credentialStore = KeychainProviderCredentialStore()
        let credentialSource = DeepSeekCredentialSource(
            ccSwitchSource: ccSwitchSource,
            providerCredentialStore: credentialStore
        )
        let deepSeekBalanceSource = DeepSeekBalanceSource { try credentialSource.readAPIKey() }
        var providerSources: [any ProviderMetricsSource] = [
            DeepSeekMetricsSource(
                balanceSource: deepSeekBalanceSource,
                platformUsageSource: DeepSeekPlatformUsageSource(),
                platformUsageEnabled: { settingsStore.load().deepSeekPlatformUsageEnabled },
                configured: { credentialSource.isConfigured }
            ),
            OpenRouterMetricsSource(credentialStore: credentialStore),
            SiliconFlowMetricsSource(credentialStore: credentialStore)
        ]
        if let miniMaxSource = MiniMaxCLIMetricsSource.locate() {
            providerSources.append(miniMaxSource)
        }
        let proxyUsageSource = ccSwitchSource.isLocalProxyEnabled()
            ? ProxyUsageSource()
            : nil
        let state = AppState(
            settingsStore: settingsStore,
            providerMetricsSources: providerSources,
            providerCredentialStore: credentialStore,
            proxyUsageSource: proxyUsageSource,
            launchAtLoginManager: LaunchAtLoginManagerFactory.make()
        )
        _appState = StateObject(wrappedValue: state)
        state.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(
                item: appState.menuBarProviderItem,
                layoutItems: appState.menuBarProviderItems
            )
        }
        .menuBarExtraStyle(.window)

        Window("Codex Dashboard", id: AppConfiguration.dashboardWindowID) {
            DashboardShellView()
                .environmentObject(appState)
                .preferredColorScheme(appState.theme.colorScheme)
                .task { appState.start() }
        }
        .defaultSize(
            width: AppConfiguration.defaultWindowSize.width,
            height: AppConfiguration.defaultWindowSize.height
        )
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

private struct MenuBarContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @State private var measuredContentHeight = MenuBarPanelLayout.initialHeight

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
            // Summary line + reset expiry
            let summarySnapshot = appState.currentUsage ?? appState.lastSuccessfulUsage ?? appState.officialUsageSnapshot
            MenuBarPanelInfoText(
                text: summarySnapshot.map { "ChatGPT: \(MenuBarPresentation.summary($0))" }
                    ?? "ChatGPT: Week -- · -- · --"
            )

            if let snapshot = summarySnapshot {
                showResetExpiry(snapshot)
            } else {
                MenuBarPanelInfoText(text: "No reset expiry")
            }

            if let error = appState.usageError {
                MenuBarPanelInfoText(text: error)
            }

            // Third-party API section
            if !appState.effectiveEnabledProviderIDs.isEmpty {
                MenuBarPanelDivider()
                ForEach(ProviderID.allCases.filter { appState.effectiveEnabledProviderIDs.contains($0) }) { providerID in
                    if let snapshot = appState.providerSnapshots[providerID] {
                        ForEach(MenuBarPresentation.providerDetailLines(
                            snapshot: snapshot,
                            proxyUsage: appState.proxyUsageByProvider[providerID]
                        ), id: \.self) { line in
                            MenuBarPanelInfoText(text: line)
                        }
                    } else if appState.refreshingProviderIDs.contains(providerID) {
                        MenuBarPanelInfoText(text: "\(providerID.displayName)：指标查询中…")
                    } else if let error = appState.providerErrors[providerID] {
                        MenuBarPanelInfoText(text: "\(providerID.displayName)：\(error)")
                    } else {
                        MenuBarPanelInfoText(text: "\(providerID.displayName)：指标不可用")
                    }
                }
            }

            MenuBarPanelDivider()

            MenuBarPanelButton(
                title: "打开仪表盘",
                shortcutLabel: "⌘D",
                shortcut: "d"
            ) {
                appState.selectedRoute = .dashboard
                openWindow(id: AppConfiguration.dashboardWindowID)
                DispatchQueue.main.async {
                    appState.selectedRoute = .dashboard
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    let dashboardWindow = NSApplication.shared.windows.first {
                        $0.identifier?.rawValue == AppConfiguration.dashboardWindowID || $0.title == "Codex Dashboard"
                    }
                    dashboardWindow?.makeKeyAndOrderFront(nil)
                }
            }

            MenuBarPanelButton(title: "立即刷新", isEnabled: !appState.isRefreshing) {
                appState.refresh()
            }

            MenuBarDisplayModeRow(selection: $appState.displayMode)

            MenuBarPanelStatusRow(text: "会话状态：\(activityLabel(appState.sessionActivity))")

            MenuBarPanelToggleRow(title: "开机启动", isOn: Binding(
                get: { appState.launchAtLoginEnabled },
                set: appState.setLaunchAtLoginEnabled
            ))

            if let startupError = appState.launchAtLoginError {
                MenuBarPanelInfoText(text: startupError, color: .orange)
                if appState.launchAtLoginStatus == .requiresApproval {
                    MenuBarPanelButton(title: "打开登录项设置") {
                        appState.openLoginItemsSettings()
                    }
                }
            }

            MenuBarPanelDivider()

            MenuBarPanelButton(
                title: "退出 Codex Bar",
                shortcutLabel: "⌘Q",
                shortcut: "q"
            ) {
                NSApplication.shared.terminate(nil)
            }
            }
            .padding(.vertical, 6)
            .frame(width: MenuBarPanelLayout.width, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MenuBarPanelContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .frame(
            width: MenuBarPanelLayout.width,
            height: MenuBarPanelLayout.panelHeight(
                contentHeight: measuredContentHeight,
                visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 700
            )
        )
        .onPreferenceChange(MenuBarPanelContentHeightPreferenceKey.self) {
            let height = ceil($0)
            if height > 0, height != measuredContentHeight {
                measuredContentHeight = height
            }
        }
        .background(.regularMaterial)
    }

    private func showResetExpiry(_ snapshot: CodexUsageSnapshot) -> some View {
        Group {
            if snapshot.resetCredits.expiresAt.isEmpty {
                MenuBarPanelInfoText(text: "No reset expiry")
            } else {
                ForEach(Array(snapshot.resetCredits.expiresAt.prefix(3).enumerated()), id: \.offset) { index, value in
                    MenuBarPanelInfoText(
                        text: MenuBarPresentation.resetExpiryLine(
                            index: index,
                            formattedExpiry: MenuBarStamp.expiryString(value)
                        )
                    )
                }
            }
        }
    }

    private var effectiveOfficialSnapshot: CodexUsageSnapshot? {
        appState.officialUsageSnapshot ?? appState.currentUsage ?? appState.lastSuccessfulUsage
    }

    private func activityLabel(_ activity: SessionActivity) -> String {
        switch activity {
        case .running: "运行中"
        case .waiting: "等待输入"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "暂无活动"
        }
    }

}

private struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

enum MenuBarPanelLayout {
    static let width: CGFloat = 252
    static let horizontalPadding: CGFloat = 12
    static let actionRowHeight: CGFloat = 25
    static let initialHeight: CGFloat = 240
    static let heightCeiling: CGFloat = 620

    static func maximumHeight(forVisibleScreenHeight height: CGFloat) -> CGFloat {
        min(heightCeiling, max(1, height - 80))
    }

    static func panelHeight(contentHeight: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        let resolvedContentHeight = contentHeight > 0 ? ceil(contentHeight) : initialHeight
        return min(
            maximumHeight(forVisibleScreenHeight: visibleScreenHeight),
            max(1, resolvedContentHeight)
        )
    }
}

private struct MenuBarPanelContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarPanelInfoText: View {
    let text: String
    var fontSize: CGFloat = 12
    var rowHeight: CGFloat = 23
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .padding(.horizontal, MenuBarPanelLayout.horizontalPadding)
    }
}

private struct MenuBarPanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuBarPanelLayout.horizontalPadding)
            .padding(.vertical, 5)
    }
}

private struct MenuBarPanelButton: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var isEnabled = true
    var shortcutLabel: String?
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var isHovering = false

    @ViewBuilder
    var body: some View {
        if let shortcut {
            rowButton
                .keyboardShortcut(shortcut, modifiers: [.command])
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            dismiss()
            action()
        } label: {
            MenuBarPanelRowLabel(title: title, shortcutLabel: shortcutLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering && isEnabled ? Color.white : Color.primary)
        .background(
            isHovering && isEnabled ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 4)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }
}

private struct MenuBarDisplayModeRow: View {
    @Binding var selection: MenuBarDisplayMode
    @State private var isHovering = false
    @State private var isShowingOptions = false

    var body: some View {
        Button {
            isShowingOptions.toggle()
        } label: {
            MenuBarPanelRowLabel(title: "显示方式", showsChevron: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background(
            isHovering ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 4)
        .onHover { isHovering = $0 }
        .accessibilityLabel("显示方式")
        .popover(isPresented: $isShowingOptions, arrowEdge: .trailing) {
            MenuBarDisplayModeOptions(
                selection: $selection,
                isPresented: $isShowingOptions
            )
        }
    }
}

private struct MenuBarDisplayModeOptions: View {
    @Binding var selection: MenuBarDisplayMode
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(MenuBarDisplayMode.allCases) { mode in
                MenuBarDisplayModeOptionRow(
                    title: mode.title,
                    isSelected: selection == mode
                ) {
                    selection = mode
                    isPresented = false
                }
            }
        }
        .padding(5)
        .frame(width: 112)
    }
}

private struct MenuBarDisplayModeOptionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 13))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background(
            isHovering ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onHover { isHovering = $0 }
    }
}

private struct MenuBarPanelToggleRow: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
            dismiss()
        } label: {
            MenuBarPanelRowLabel(
                title: title,
                reservesLeadingCheckmark: isOn,
                showsCheckmark: isOn
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background(
            isHovering ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 4)
        .onHover { isHovering = $0 }
    }
}

private struct MenuBarPanelStatusRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MenuBarPanelLayout.actionRowHeight)
            .padding(.horizontal, MenuBarPanelLayout.horizontalPadding)
    }
}

private struct MenuBarPanelRowLabel: View {
    let title: String
    var shortcutLabel: String?
    var reservesLeadingCheckmark = false
    var showsCheckmark = false
    var showsChevron = false

    var body: some View {
        HStack(spacing: 0) {
            if reservesLeadingCheckmark {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(showsCheckmark ? 1 : 0)
                    .frame(width: 14)
                    .padding(.trailing, 7)
            }

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 8)

            if let shortcutLabel {
                Text(shortcutLabel)
                    .font(.system(size: 12))
                    .opacity(0.62)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.78)
                    .frame(width: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuBarPanelLayout.actionRowHeight)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

enum MenuBarStamp {
    static func string(_ value: String) -> String {
        if let date = date(from: value) {
            return display.string(from: date)
        }
        return value
    }

    static func expiryString(_ value: String) -> String {
        guard let date = date(from: value) else { return value }
        return expiry.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let expiry: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct MenuBarLabel: View {
    let item: MenuBarProviderItem
    let layoutItems: [MenuBarProviderItem]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(layoutItems.enumerated()), id: \.offset) { _, candidate in
                providerLabel(candidate)
                    .opacity(candidate.providerType == item.providerType ? 1 : 0)
                    .accessibilityHidden(candidate.providerType != item.providerType)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex Bar，\(item.providerType.displayName)，\(item.title)，\(activityLabel(item.activity))")
    }

    private func providerLabel(_ candidate: MenuBarProviderItem) -> some View {
        HStack(spacing: 4) {
            ProviderMenuBarIcon(
                providerType: candidate.providerType,
                activity: candidate.activity
            )
            if !candidate.title.isEmpty {
                Text(candidate.title)
            }
        }
    }

    private func activityLabel(_ activity: SessionActivity) -> String {
        switch activity {
        case .running: "运行中"
        case .waiting: "等待输入"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "暂无活动"
        }
    }
}
