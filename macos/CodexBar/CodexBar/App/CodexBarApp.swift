import AppKit
import Combine
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
    @StateObject private var menuBarController: MenuBarController

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
            GLMMetricsSource(credentialStore: credentialStore)
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
        let menuBarController = MenuBarController(
            appState: state,
            isEnabled: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        )
        _menuBarController = StateObject(wrappedValue: menuBarController)
        DispatchQueue.main.async {
            menuBarController.start()
        }
        // The test bundle is hosted inside this app target. Starting the real
        // polling loop there would read the user's Keychain during XCTest.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            state.start()
        }
    }

    var body: some Scene {
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

@MainActor
private final class MenuBarController: NSObject, ObservableObject {
    private let appState: AppState
    private let isEnabled: Bool
    private var statusItem: NSStatusItem?
    private var statusView: MenuBarStatusItemView?
    private let popover = NSPopover()
    private var dashboardWindowController: DashboardWindowController?
    private var stateCancellable: AnyCancellable?

    init(appState: AppState, isEnabled: Bool) {
        self.appState = appState
        self.isEnabled = isEnabled
        super.init()
    }

    func start() {
        guard isEnabled, statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let view = MenuBarStatusItemView(rootView: MenuBarStatusLabel(appState: appState))
        statusItem = item
        statusView = view
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.isBordered = false
            button.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        guard let statusView else { return }
        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverRoot(
                appState: appState,
                onOpenDashboard: { [weak self] in self?.openDashboard() },
                onDismiss: { [weak self] in self?.closePopover() }
            )
        )
        popover.contentSize = NSSize(
            width: MenuBarPanelLayout.width,
            height: MenuBarPanelLayout.initialHeight
        )

        stateCancellable = appState.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemSize()
                }
            }
        updateStatusItemSize()
    }

    private func updateStatusItemSize() {
        guard let statusItem, let statusView else { return }
        statusView.invalidateIntrinsicContentSize()
        let width = max(24, ceil(statusView.fittingSize.width))
        let height = NSStatusBar.system.thickness
        statusView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        statusItem.length = width
    }

    private func togglePopover() {
        guard let statusView else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(
                relativeTo: statusView.bounds,
                of: statusView,
                preferredEdge: .minY
            )
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func openDashboard() {
        closePopover()
        appState.selectedRoute = .dashboard
        if dashboardWindowController == nil {
            dashboardWindowController = DashboardWindowController(appState: appState)
        }
        dashboardWindowController?.showDashboard()
    }
}

@MainActor
private final class DashboardWindowController: NSWindowController {
    init(appState: AppState) {
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: AppConfiguration.defaultWindowSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(AppConfiguration.dashboardWindowID)
        window.title = "Codex Dashboard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = AppConfiguration.minimumWindowSize
        window.center()
        window.contentViewController = NSHostingController(
            rootView: DashboardWindowRoot(appState: appState)
        )
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showDashboard() {
        guard let window else { return }
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct DashboardWindowRoot: View {
    @ObservedObject var appState: AppState

    var body: some View {
        DashboardShellView()
            .environmentObject(appState)
            .preferredColorScheme(appState.theme.colorScheme)
    }
}

private struct MenuBarPopoverRoot: View {
    @ObservedObject var appState: AppState
    let onOpenDashboard: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        MenuBarContent()
            .environmentObject(appState)
            .environment(\.menuBarOpenDashboard, onOpenDashboard)
            .environment(\.menuBarDismiss, onDismiss)
            .preferredColorScheme(appState.theme.colorScheme)
    }
}

private struct MenuBarContent: View {
    @Environment(\.menuBarOpenDashboard) private var openDashboard
    @EnvironmentObject private var appState: AppState
    @State private var measuredContentHeight = MenuBarPanelLayout.initialHeight

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
            // Summary line + reset expiry
            let summarySnapshot = appState.currentUsage ?? appState.lastSuccessfulUsage ?? appState.officialUsageSnapshot
            if let snapshot = summarySnapshot {
                MenuBarPanelInfoText(
                    text: MenuBarPresentation.chatGPTDropdownLine(
                        snapshot,
                        formattedExpiry: MenuBarStamp.shortExpiryString
                    )
                )
                MenuBarPanelInfoText(text: MenuBarPresentation.dropdownSummary(snapshot))
                showResetExpiry(snapshot)
            } else {
                MenuBarPanelInfoText(text: MenuBarPresentation.chatGPTDropdownLine(nil))
                MenuBarPanelInfoText(text: MenuBarPresentation.dropdownSummary(nil))
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

            MenuBarPanelButton(title: "打开仪表盘") {
                appState.selectedRoute = .dashboard
                openDashboard()
            }

            MenuBarPanelButton(title: "立即刷新", isEnabled: !appState.isRefreshing) {
                appState.refresh()
            }

            MenuBarDisplayModeRow(
                selection: $appState.displayMode,
                lineMode: $appState.menuBarLineMode,
                textAlignment: $appState.menuBarTextAlignment
            )

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

private struct MenuBarOpenDashboardKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct MenuBarDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private extension EnvironmentValues {
    var menuBarOpenDashboard: () -> Void {
        get { self[MenuBarOpenDashboardKey.self] }
        set { self[MenuBarOpenDashboardKey.self] = newValue }
    }

    var menuBarDismiss: () -> Void {
        get { self[MenuBarDismissKey.self] }
        set { self[MenuBarDismissKey.self] = newValue }
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
    @Environment(\.menuBarDismiss) private var menuBarDismiss
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
            menuBarDismiss()
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
    @Binding var lineMode: MenuBarLineMode
    @Binding var textAlignment: MenuBarTextAlignment
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
                lineMode: $lineMode,
                textAlignment: $textAlignment,
                isPresented: $isShowingOptions
            )
        }
    }
}

private struct MenuBarDisplayModeOptions: View {
    @Binding var selection: MenuBarDisplayMode
    @Binding var lineMode: MenuBarLineMode
    @Binding var textAlignment: MenuBarTextAlignment
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(MenuBarDisplayMode.allCases) { mode in
                MenuBarOptionRow(
                    title: mode.title,
                    isSelected: selection == mode
                ) {
                    selection = mode
                    isPresented = false
                }
            }

            MenuBarOptionDivider()

            ForEach(MenuBarLineMode.allCases) { mode in
                MenuBarOptionRow(
                    title: mode.title,
                    isSelected: lineMode == mode
                ) {
                    lineMode = mode
                    isPresented = false
                }
            }

            MenuBarOptionDivider()

            ForEach(MenuBarTextAlignment.allCases) { alignment in
                MenuBarOptionRow(
                    title: alignment.title,
                    isSelected: textAlignment == alignment
                ) {
                    textAlignment = alignment
                    isPresented = false
                }
            }
        }
        .padding(5)
        .frame(width: 112)
    }
}

private struct MenuBarOptionDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
    }
}

private struct MenuBarOptionRow: View {
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
    @Environment(\.menuBarDismiss) private var menuBarDismiss
    let title: String
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
            dismiss()
            menuBarDismiss()
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

    static func shortExpiryString(_ value: String) -> String {
        guard let date = date(from: value) else { return value }
        return shortExpiry.string(from: date)
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

    private static let shortExpiry: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        MenuBarLabel(
            item: appState.menuBarProviderItem,
            layoutItems: appState.menuBarProviderItems,
            lineMode: appState.menuBarLineMode,
            textAlignment: appState.menuBarTextAlignment
        )
        .frame(height: 22)
        .padding(.horizontal, 2)
    }
}

private final class MenuBarStatusItemView: NSHostingView<MenuBarStatusLabel> {
    var onClick: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width, height: NSStatusBar.system.thickness)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private struct MenuBarLabel: View {
    let item: MenuBarProviderItem
    let layoutItems: [MenuBarProviderItem]
    let lineMode: MenuBarLineMode
    let textAlignment: MenuBarTextAlignment

    var body: some View {
        HStack(spacing: 4) {
            ProviderMenuBarIcon(
                providerType: item.providerType,
                activity: item.activity
            )
            if !item.lines.isEmpty {
                ZStack(alignment: stackAlignment) {
                    ForEach(Array(layoutItems.enumerated()), id: \.offset) { _, candidate in
                        providerText(candidate)
                            .opacity(candidate.providerType == item.providerType ? 1 : 0)
                            .accessibilityHidden(candidate.providerType != item.providerType)
                    }
                }
                .fixedSize()
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Codex Bar，\(item.providerType.displayName)，\(item.title.isEmpty ? "仅图标" : item.title)，\(activityLabel(item.activity))"
        )
    }

    @ViewBuilder
    private func providerText(_ candidate: MenuBarProviderItem) -> some View {
        switch lineMode {
        case .singleLine:
            Text(candidate.title)
                .lineLimit(1)
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
        case .multiLine:
            VStack(alignment: textColumnAlignment, spacing: -3) {
                ForEach(Array(candidate.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .lineLimit(1)
                        .foregroundStyle(Color.white)
                }
            }
            .font(.system(size: 11))
        }
    }

    private var stackAlignment: Alignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textColumnAlignment: HorizontalAlignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
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
