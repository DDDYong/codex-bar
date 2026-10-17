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

private enum ProviderMenuBarIcon {
    private struct IconKey: Hashable {
        let providerType: ProviderType
    }

    private static let images: [IconKey: NSImage] = {
        let providerTypes: [ProviderType] = [.officialCodex] + ProviderID.allCases.map(\.providerType)
        return Dictionary(uniqueKeysWithValues: providerTypes.compactMap { providerType -> (IconKey, NSImage)? in
            guard let source = ProviderIconHelper.icon(for: providerType) else { return nil }
            return (
                IconKey(providerType: providerType),
                MenuBarStatusIconComposer.composedImage(
                    from: source,
                    removesInternalCodexGlyph: providerType == .officialCodex
                )
            )
        })
    }()

    static func image(for providerType: ProviderType) -> NSImage? {
        images[IconKey(providerType: providerType)]
    }
}

enum MenuBarStatusIconComposer {
    static func composedImage(
        from source: NSImage,
        removesInternalCodexGlyph: Bool = false
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let monochromeSource = monochromeImage(
            from: source,
            removesInternalCodexGlyph: removesInternalCodexGlyph
        )
        let bodySize: CGFloat = 18.5
        image.lockFocus()
        monochromeSource.draw(
            in: NSRect(
                x: (image.size.width - bodySize) / 2,
                y: (image.size.height - bodySize) / 2,
                width: bodySize,
                height: bodySize
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func monochromeImage(
        from source: NSImage,
        removesInternalCodexGlyph: Bool
    ) -> NSImage {
        let image = NSImage(size: source.size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: source.size)).fill()
        source.draw(
            in: NSRect(origin: .zero, size: source.size),
            from: .zero,
            operation: .destinationIn,
            fraction: 1
        )
        if removesInternalCodexGlyph {
            clearInternalCodexGlyph(in: source.size)
        }
        image.unlockFocus()
        return image
    }

    private static func clearInternalCodexGlyph(in size: NSSize) {
        let scaleX = size.width / 20
        let scaleY = size.height / 20
        let point = { (x: CGFloat, y: CGFloat) in
            NSPoint(x: x * scaleX, y: y * scaleY)
        }

        NSGraphicsContext.current?.compositingOperation = .clear

        let chevron = NSBezierPath()
        chevron.move(to: point(5.0, 13.4))
        chevron.line(to: point(7.8, 10.0))
        chevron.line(to: point(5.0, 6.6))
        chevron.lineWidth = 2.2 * min(scaleX, scaleY)
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()

        let terminalRect = NSRect(
            x: 9.4 * scaleX,
            y: 6.6 * scaleY,
            width: 5.6 * scaleX,
            height: 2.5 * scaleY
        )
        NSBezierPath(
            roundedRect: terminalRect,
            xRadius: 1.25 * scaleX,
            yRadius: 1.25 * scaleY
        ).fill()
    }
}

enum MenuBarStatusIndicatorPalette {
    static func color(for activity: SessionActivity) -> NSColor? {
        switch activity.indicatorStyle {
        case .active: .systemGreen
        case .attention: .systemOrange
        case .failure: .systemRed
        case .idle: nil
        }
    }
}

enum MenuBarStatusIndicatorLayout {
    static let diameter: CGFloat = 6
    static let iconTrailingGap: CGFloat = 4

    static func frame(for imageRect: NSRect) -> NSRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }

        let scale = min(imageRect.width / 20, imageRect.height / 20)
        let size = diameter * scale
        let iconGap = max(0, iconTrailingGap) * scale
        let centerX = imageRect.maxX + iconGap
        return NSRect(
            x: centerX - (size / 2),
            y: imageRect.midY - (size / 2),
            width: size,
            height: size
        )
    }
}

final class MenuBarStatusIndicatorView: NSView {
    var activity: SessionActivity = .unknown {
        didSet {
            isHidden = MenuBarStatusIndicatorPalette.color(for: activity) == nil
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color = MenuBarStatusIndicatorPalette.color(for: activity) else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

enum MenuBarPopoverClickPolicy {
    static func shouldDismiss(isInsidePopover: Bool, isInsideStatusItem: Bool) -> Bool {
        !isInsidePopover && !isInsideStatusItem
    }
}

enum MenuBarStatusTitleLayout {
    static let labelColumnWidth: CGFloat = 24
    static let valueColumnStart: CGFloat = labelColumnWidth

    static func title(for item: MenuBarProviderItem, lineMode: MenuBarLineMode) -> String {
        guard lineMode == .multiLine,
              item.providerType == .officialCodex else {
            return lineMode == .singleLine
                ? item.title
                : item.lines.joined(separator: "\n")
        }

        return item.lines
            .map(formatOfficialLine)
            .joined(separator: "\n")
    }

    static func paragraphStyle(
        for item: MenuBarProviderItem,
        lineMode: MenuBarLineMode
    ) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byClipping

        guard lineMode == .multiLine else { return paragraphStyle }

        paragraphStyle.minimumLineHeight = 10
        paragraphStyle.maximumLineHeight = 10
        paragraphStyle.lineSpacing = 0

        if item.providerType == .officialCodex {
            paragraphStyle.tabStops = [
                NSTextTab(
                    textAlignment: .center,
                    location: labelColumnWidth / 2
                ),
                NSTextTab(
                    textAlignment: .left,
                    location: valueColumnStart
                )
            ]
        }

        return paragraphStyle
    }

    private static func formatOfficialLine(_ line: String) -> String {
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return line
        }

        let label = String(line[..<separator])
        guard label == "5h" || label == "W" else { return line }

        let value = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "\t\(label)" : "\t\(label)\t\(value)"
    }
}

enum MenuBarStatusItemLayout {
    static let imageTitleGap: CGFloat = 1
    static let multiLineTitleVerticalOffset: CGFloat = 2
    static let trailingPadding: CGFloat = 4
}

final class MenuBarStatusButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        guard image != nil,
              imagePosition == .imageLeft,
              titleRect.width > 0 else {
            return titleRect
        }

        let imageRect = super.imageRect(forBounds: rect)
        let currentGap = titleRect.minX - imageRect.maxX
        let adjustment = MenuBarStatusItemLayout.imageTitleGap - currentGap
        titleRect.origin.x += adjustment
        titleRect.size.width = max(0, titleRect.width - adjustment)

        return titleRect
    }

    override func drawTitle(
        _ title: NSAttributedString,
        withFrame frame: NSRect,
        in controlView: NSView
    ) -> NSRect {
        var adjustedFrame = frame
        if title.string.contains("\n") {
            adjustedFrame.origin.y += MenuBarStatusItemLayout.multiLineTitleVerticalOffset
        }
        return super.drawTitle(title, withFrame: adjustedFrame, in: controlView)
    }
}

final class CodexBarApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarApplicationDelegate.self) private var applicationDelegate
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
        // The dashboard is owned by DashboardWindowController below. Keeping
        // a second SwiftUI Window scene would create another dashboard window
        // that becomes visible after the first one is closed.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class MenuBarController: NSObject, ObservableObject {
    private let appState: AppState
    private let isEnabled: Bool
    private var statusItem: NSStatusItem?
    private weak var statusButton: NSStatusBarButton?
    private var statusIndicatorView: MenuBarStatusIndicatorView?
    private let popover = NSPopover()
    private var dashboardWindowController: DashboardWindowController?
    private var stateCancellable: AnyCancellable?
    private var outsideClickMonitors: [Any] = []

    init(appState: AppState, isEnabled: Bool) {
        self.appState = appState
        self.isEnabled = isEnabled
        super.init()
    }

    func start() {
        guard isEnabled, statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.cell = MenuBarStatusButtonCell(textCell: "")
        statusItem = item
        statusButton = button
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
        button.isBordered = false
        button.focusRingType = .none
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        let indicatorView = MenuBarStatusIndicatorView(frame: .zero)
        button.addSubview(indicatorView)
        statusIndicatorView = indicatorView

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
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
        guard let statusItem, let button = statusButton else { return }
        let item = appState.menuBarProviderItem
        let title = nativeStatusTitle(for: item)
        let image = nativeStatusIcon(for: item)
        let hasText = !title.string.isEmpty
        let lineMode = appState.menuBarLineMode

        button.attributedTitle = title
        button.image = image
        button.imagePosition = image == nil ? .noImage : (hasText ? .imageLeft : .imageOnly)
        button.imageScaling = .scaleNone
        button.imageHugsTitle = true

        if let cell = button.cell {
            cell.alignment = .left
            cell.font = nativeStatusFont(for: lineMode)
            cell.usesSingleLineMode = !hasText || lineMode == .singleLine
            cell.wraps = hasText && lineMode == .multiLine
            cell.isScrollable = false
            cell.lineBreakMode = .byClipping
        }

        let bounds = title.boundingRect(
            with: NSSize(width: 4096, height: 4096),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textWidth = hasText ? ceil(bounds.width) : 0
        let imageWidth = image == nil ? 0 : 20
        let imageGap = image != nil && hasText ? MenuBarStatusItemLayout.imageTitleGap : 0
        let width = max(
            24,
            ceil(textWidth + CGFloat(imageWidth) + imageGap + MenuBarStatusItemLayout.trailingPadding)
        )
        statusItem.length = width
        updateStatusIndicator(for: item.activity)
    }

    private func nativeStatusTitle(for item: MenuBarProviderItem) -> NSAttributedString {
        guard !item.lines.isEmpty else { return NSAttributedString(string: "") }

        let lineMode = appState.menuBarLineMode
        let title = MenuBarStatusTitleLayout.title(for: item, lineMode: lineMode)
        let paragraphStyle = MenuBarStatusTitleLayout.paragraphStyle(
            for: item,
            lineMode: lineMode
        )

        return NSAttributedString(
            string: title,
            attributes: [
                .font: nativeStatusFont(for: lineMode),
                .foregroundColor: NSColor.controlTextColor,
                .paragraphStyle: paragraphStyle,
                .baselineOffset: 0
            ]
        )
    }

    private func nativeStatusIcon(for item: MenuBarProviderItem) -> NSImage? {
        let image = ProviderMenuBarIcon.image(
            for: item.providerType
        ) ?? NSImage(
            systemSymbolName: "chart.pie",
            accessibilityDescription: "Codex Bar"
        )
        image?.isTemplate = true
        return image
    }

    private func updateStatusIndicator(for activity: SessionActivity) {
        guard let indicatorView = statusIndicatorView else { return }
        indicatorView.activity = activity
        guard let button = statusButton,
              let imageRect = button.cell?.imageRect(forBounds: button.bounds),
              imageRect.width > 0,
              imageRect.height > 0 else {
            indicatorView.isHidden = true
            return
        }

        indicatorView.frame = MenuBarStatusIndicatorLayout.frame(
            for: imageRect
        )
    }

    private func nativeStatusFont(for lineMode: MenuBarLineMode) -> NSFont {
        NSFont.systemFont(ofSize: lineMode == .singleLine ? 13 : 11)
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        togglePopover()
    }

    private func togglePopover() {
        guard let statusButton else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(
                relativeTo: statusButton.bounds,
                of: statusButton,
                preferredEdge: .minY
            )
            beginOutsideClickMonitoring()
        }
    }

    private func closePopover() {
        stopOutsideClickMonitoring()
        popover.performClose(nil)
    }

    private func beginOutsideClickMonitoring() {
        guard outsideClickMonitors.isEmpty else { return }

        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseDownEvents,
            handler: { [weak self] event in
                self?.dismissPopoverIfNeeded(for: event)
                return event
            }
        ) {
            outsideClickMonitors.append(localMonitor)
        }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseDownEvents,
            handler: { [weak self] event in
                self?.dismissPopoverIfNeeded(for: event)
            }
        ) {
            outsideClickMonitors.append(globalMonitor)
        }
    }

    private func stopOutsideClickMonitoring() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    private func dismissPopoverIfNeeded(for event: NSEvent) {
        guard popover.isShown else { return }

        let location = screenLocation(for: event)
        let isInsidePopover = popover.contentViewController?.view.window?.frame.contains(location) == true
        let isInsideStatusItem = statusButton.flatMap(screenFrame(for:))?.contains(location) == true
        guard MenuBarPopoverClickPolicy.shouldDismiss(
            isInsidePopover: isInsidePopover,
            isInsideStatusItem: isInsideStatusItem
        ) else { return }

        closePopover()
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        let windowPoint = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        return window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
    }

    private func screenFrame(for view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
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

extension MenuBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
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
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.contentMinSize = AppConfiguration.minimumWindowSize
        window.center()
        window.contentViewController = NSHostingController(
            rootView: DashboardWindowRoot(
                appState: appState,
                onClose: { [weak window] in window?.performClose(nil) }
            )
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
    let onClose: () -> Void

    var body: some View {
        DashboardShellView(onClose: onClose)
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
                lineMode: $appState.menuBarLineMode
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
                isPresented: $isShowingOptions
            )
        }
    }
}

private struct MenuBarDisplayModeOptions: View {
    @Binding var selection: MenuBarDisplayMode
    @Binding var lineMode: MenuBarLineMode
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
