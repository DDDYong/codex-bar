import AppKit
import ServiceManagement
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

private struct CodexBarMenuIcon: View {
    let activity: SessionActivity

    var body: some View {
        if let image = composedImage {
            Image(nsImage: image)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "chart.pie")
                .font(.system(size: 16, weight: .medium))
        }
    }

    private var composedImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "menu-bar-icon-source", withExtension: "png"),
              let source = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        source.draw(
            in: NSRect(x: 0, y: 1, width: 18.5, height: 18.5),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        statusColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14.25, y: 0, width: 5, height: 5)).fill()
        image.unlockFocus()
        return image
    }

    private var statusColor: NSColor {
        switch activity {
        case .running: .systemYellow
        case .waiting: .systemOrange
        case .completed: .systemGreen
        case .failed: .systemRed
        case .unknown: .secondaryLabelColor
        }
    }
}

@main
struct CodexBarApp: App {
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        state.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(
                title: appState.menuBarTitle,
                activity: appState.sessionActivity
            )
        }
        .menuBarExtraStyle(.menu)

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
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @State private var startupError: String?

    var body: some View {
        Text(MenuBarPresentation.summary(appState.currentUsage ?? appState.lastSuccessfulUsage))
            .foregroundStyle(.secondary)

        if let snapshot = appState.currentUsage ?? appState.lastSuccessfulUsage {
            if snapshot.resetCredits.expiresAt.isEmpty {
                Text("暂无到期记录").foregroundStyle(.secondary)
            } else {
                ForEach(Array(snapshot.resetCredits.expiresAt.prefix(3).enumerated()), id: \.offset) { index, value in
                    Text("第 \(index + 1) 次 · \(MenuBarStamp.expiryString(value)) 到期")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let error = appState.usageError {
            Text(error)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("打开仪表盘") {
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
        .keyboardShortcut("d", modifiers: [.command])

        Button("立即刷新") {
            appState.refresh()
        }
        .disabled(appState.isRefreshing)

        Picker("显示方式", selection: $appState.displayMode) {
            ForEach(MenuBarDisplayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        Text("会话状态：\(activityLabel(appState.sessionActivity))")
            .foregroundStyle(.secondary)

        Toggle("开机启动", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: setLaunchAtLogin
        ))

        if let startupError {
            Text(startupError).font(.caption).foregroundStyle(.orange)
        }

        Divider()

        Button("退出 Codex Bar") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
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

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startupError = nil
        } catch {
            startupError = "无法更新登录启动设置"
        }
    }
}

private enum MenuBarStamp {
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
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}

private struct MenuBarLabel: View {
    let title: String
    let activity: SessionActivity

    var body: some View {
        HStack(spacing: 4) {
            CodexBarMenuIcon(activity: activity)
            if !title.isEmpty {
                Text(title)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex Bar，\(activityLabel(activity))")
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
