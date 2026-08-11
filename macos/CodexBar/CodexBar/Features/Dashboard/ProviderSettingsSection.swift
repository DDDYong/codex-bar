import SwiftUI

enum ProviderSettingsInteraction {
    static func isEnableToggleDisabled(isTesting: Bool, isEnabled: Bool) -> Bool {
        isTesting && !isEnabled
    }
}

struct ProviderSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("第三方 Provider")
                    .font(.headline)
                Text("凭据只保存在 macOS 钥匙串。界面不会回显密钥，连接错误也不会包含响应正文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(ProviderID.allCases.filter { !$0.isExperimental }) { providerID in
                ProviderConfigurationCard(providerID: providerID)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实验 Provider")
                        .font(.subheadline.weight(.semibold))
                    Text("默认关闭。只读取已启用的 cc-switch 代理日志；MiniMax 还可读取已安装且已登录的官方 mmx CLI，不会切换或接管 Provider。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用实验能力", isOn: Binding(
                    get: { appState.experimentalProvidersEnabled },
                    set: appState.setExperimentalProvidersEnabled
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            ForEach(ProviderID.allCases.filter(\.isExperimental)) { providerID in
                ProviderConfigurationCard(providerID: providerID)
                    .disabled(!appState.experimentalProvidersEnabled)
                    .opacity(appState.experimentalProvidersEnabled ? 1 : 0.55)
            }

            if let error = appState.proxyUsageError, appState.experimentalProvidersEnabled {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

private struct ProviderConfigurationCard: View {
    @EnvironmentObject private var appState: AppState
    let providerID: ProviderID

    @State private var credentialDrafts: [ProviderCredentialKind: String] = [:]
    @State private var credentialPendingDeletion: ProviderCredentialKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ProviderIconHelper.iconView(for: providerID.providerType, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerID.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(providerID.sourceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(ProviderSettingsInteraction.isEnableToggleDisabled(
                        isTesting: isTesting,
                        isEnabled: appState.enabledProviderIDs.contains(providerID)
                    ))
            }

            Divider()

            if providerID.credentialKinds.isEmpty {
                Text("CodexBar 不保存此实验 Provider 的 API 凭据。仅当请求已由用户主动配置为经过 cc-switch，或本机已有官方 CLI 登录态时，才会显示可核验数据。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providerID.credentialKinds) { kind in
                    credentialRow(kind)
                }
            }

            if providerID == .deepseek {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(
                        "读取 DeepSeek 平台详细用量（实验）",
                        isOn: Binding(
                            get: { appState.deepSeekPlatformUsageEnabled },
                            set: appState.setDeepSeekPlatformUsageEnabled
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Text("启用后只读 Chrome 中 platform.deepseek.com 的登录态，查询今日用量并按月汇总历史累计消费。Token 仅驻留内存；本地只缓存脱敏后的月度金额，私有仪表盘接口可能变化。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button(providerID.credentialKinds.isEmpty ? "刷新实验指标" : "测试现有凭据") {
                    if providerID.credentialKinds.isEmpty {
                        appState.refreshProxyUsage()
                        Task { await appState.refreshProviderMetrics(providerID: providerID) }
                    } else {
                        Task { await appState.testProviderConnection(providerID) }
                    }
                }
                .buttonStyle(.bordered)
                .disabled((!providerID.credentialKinds.isEmpty && !appState.isProviderConfigured(providerID)) || isTesting)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if providerID.credentialKinds.isEmpty {
                    Text(experimentalSourceSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    credentialSummary
                }
            }
            .controlSize(.small)

            if let snapshot = appState.providerSnapshots[providerID] {
                Text("\(snapshot.source.displayName)\(snapshot.sourceVersion.map { " \($0)" } ?? "") · \(snapshot.coverage.displayName) · 更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !snapshot.issues.isEmpty {
                    Text("部分降级：\(snapshot.issues.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let message = connectionMessage {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .orange : .green)
            } else if let error = appState.providerErrors[providerID] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.background.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .confirmationDialog(
            "删除 \(credentialPendingDeletion?.title ?? "凭据")？",
            isPresented: Binding(
                get: { credentialPendingDeletion != nil },
                set: { if !$0 { credentialPendingDeletion = nil } }
            )
        ) {
            if let kind = credentialPendingDeletion {
                Button("从钥匙串删除", role: .destructive) {
                    appState.deleteProviderCredential(providerID: providerID, kind: kind)
                    credentialPendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { credentialPendingDeletion = nil }
        } message: {
            Text("删除后需要重新输入该凭据才能恢复查询；不会影响 Provider 账户或远端 API Key。")
        }
    }

    @ViewBuilder
    private func credentialRow(_ kind: ProviderCredentialKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if appState.hasStoredCredential(providerID: providerID, kind: kind) {
                    Label("钥匙串已配置", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                    Button("删除", role: .destructive) {
                        credentialPendingDeletion = kind
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                } else if appState.hasCredential(providerID: providerID, kind: kind) {
                    Label("检测到外部配置", systemImage: "link")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }

            HStack(spacing: 8) {
                SecureField("输入新的 \(kind.title)", text: draftBinding(for: kind))
                    .textFieldStyle(.roundedBorder)
                Button("保存并测试") {
                    let value = credentialDrafts[kind, default: ""]
                    credentialDrafts[kind] = ""
                    Task {
                        await appState.saveAndTestProviderCredential(
                            value,
                            providerID: providerID,
                            kind: kind
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(credentialDrafts[kind, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
            }

            Text(kind.helpText(for: providerID))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appState.enabledProviderIDs.contains(providerID) },
            set: { appState.setProviderEnabled(providerID, enabled: $0) }
        )
    }

    private func draftBinding(for kind: ProviderCredentialKind) -> Binding<String> {
        Binding(
            get: { credentialDrafts[kind, default: ""] },
            set: { credentialDrafts[kind] = $0 }
        )
    }

    private var isTesting: Bool {
        if case .testing = appState.providerConnectionStates[providerID] { return true }
        return false
    }

    @ViewBuilder
    private var credentialSummary: some View {
        let configured = providerID.credentialKinds.filter { appState.hasCredential(providerID: providerID, kind: $0) }
        Text(configured.isEmpty ? "未配置凭据" : "已配置 \(configured.count)/\(providerID.credentialKinds.count)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var connectionMessage: (text: String, isError: Bool)? {
        switch appState.providerConnectionStates[providerID, default: .idle] {
        case .idle, .testing:
            nil
        case .succeeded(let message):
            (message, false)
        case .failed(let message):
            (message, true)
        }
    }

    private var experimentalSourceSummary: String {
        if appState.proxyUsageByProvider[providerID] != nil { return "已检测到今日代理数据" }
        if appState.providerSnapshots[providerID]?.source == .localCLI { return "已连接官方 CLI" }
        return "当前无可用实验数据"
    }
}
