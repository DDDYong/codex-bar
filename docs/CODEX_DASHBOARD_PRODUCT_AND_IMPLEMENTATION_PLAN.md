# Codex Dashboard 产品与实施计划（纯原生 macOS 迁移版）

> 状态：历史迁移计划，原生 SwiftUI 迁移已完成；当前实现与验收状态以 README 和现有代码为准。
>
> 本文保留为架构决策记录，不再作为阶段启动门禁或当前实施清单。

## 1. 决策结论

### 1.1 产品形态

```text
菜单栏：额度、Reset、会话活动状态与高频操作
主窗口：仪表板、多导航查询、历史趋势与本机环境索引
```

主窗口采用 SwiftUI 原生界面，交互和视觉以 `docs/codex-dashboard-interactive-prototype.html` 为基线；不再以 WebView/Tauri 前端作为长期架构。

### 1.2 分发策略

首版定位为自用与少量技术用户试用：

```text
Xcode 本机运行
  → Archive / 导出未签名 .app
  → 打包未签名 DMG
  → GitHub Releases
```

- 不加入 Apple Developer Program。
- 不做 Developer ID 签名和 Apple 公证。
- 不上架 Mac App Store。
- GitHub 下载者首次打开可能被 Gatekeeper 拦截，Release 页面必须如实说明手动允许方式。
- 因不走 App Store，首版不启用 App Sandbox，以保障在当前用户账户下只读 `~/.codex` 数据的能力。

这不是绕过 macOS 安全机制；不得要求用户关闭 Gatekeeper、执行提权脚本或修改系统安全策略。

### 1.3 永久产品边界

- 默认只读 Codex 本地数据；仅允许用户在“插件与 Skills”详情弹窗明确确认后，卸载满足路径保护规则的本地 Skill。不得修改插件、MCP、Codex 认证、会话或内部数据库。
- 不保存、显示、传入 UI、写入日志或导出登录 Token、Cookie、Authorization Header、认证文件原文或会话正文。
- 不把额度变化误写为精准 Token 数据。
- 任一数据源异常不得影响菜单栏、主窗口或其他数据源。

## 2. 当前项目基线

当前仓库是 Tauri 2 + Rust 菜单栏工具，不是 SwiftUI 项目：

| 现有能力 | 当前位置 | 原生迁移目标 |
|---|---|---|
| 菜单栏、菜单、轮询、刷新互斥 | `src-tauri/src/main.rs` | `AppState` + `MenuBarExtra` / 少量 AppKit 互操作 |
| Usage、Reset、认证读取、容错 | `src-tauri/src/codex.rs` | `CodexUsageSource` |
| `ProviderSnapshot`、`UsageWindow` | `src-tauri/src/models.rs` | Swift `CodexUsageSnapshot`、`UsageWindow` |
| 会话活动状态灯 | `src-tauri/src/session.rs` | `SessionActivitySource` |
| 会话 Hook 兼容回退 | `scripts/codex-session-hook.py` | 初期原样保留 |
| 开机启动 | `tauri-plugin-autostart` | `SMAppService`，在功能对等后迁移 |
| 当前前端 | `dist/index.html` | 不迁移；SwiftUI 原生实现原型界面 |

迁移原则是**迁移已验证行为，不逐行翻译 Rust 代码**。现有 Tauri 版本在原生版本通过功能验收前保持可运行，不能提前删除。

## 3. 原生工程目录

采用以下层级；截图中的前三层和 Xcode 工程/源码并列关系是正确的：

```text
codex-bar/
├── macos/
│   └── CodexBar/
│       ├── CodexBar.xcodeproj
│       ├── CodexBar/
│       │   ├── App/
│       │   │   ├── CodexBarApp.swift
│       │   │   ├── AppState.swift
│       │   │   └── AppConfiguration.swift
│       │   ├── Models/
│       │   ├── Sources/
│       │   │   ├── CodexUsageSource.swift
│       │   │   ├── SessionActivitySource.swift
│       │   │   ├── SessionIndexSource.swift
│       │   │   └── PluginSkillSource.swift
│       │   ├── Persistence/
│       │   │   ├── SnapshotStore.swift
│       │   │   └── SettingsStore.swift
│       │   ├── Features/
│       │   │   ├── Dashboard/
│       │   │   ├── Usage/
│       │   │   ├── Activity/
│       │   │   ├── Sessions/
│       │   │   ├── PluginsSkills/
│       │   │   ├── DataSources/
│       │   │   └── Settings/
│       │   ├── SharedUI/
│       │   └── Resources/
│       └── CodexBarTests/
├── src-tauri/                       # 迁移期保留的旧版本
├── dist/                            # 迁移期保留，不再作为原生 UI 来源
├── scripts/
└── docs/
```

约定：

- `macos/` 表示平台目录，允许未来加入其他平台而不污染仓库根目录。
- 外层 `CodexBar/` 是 Xcode 工程容器；内层 `CodexBar/` 是 target 的 Swift 源码根目录。这是标准 Xcode 结构，不是重复设计。
- `CodexBarTests/` 与 App 源码并列，不放进应用 bundle。
- 最低目标系统为 macOS 13；首版不采用 SwiftData，以免无必要提高系统要求。

## 4. 推荐原生架构

### 4.1 App 生命周期与窗口

```text
CodexBarApp
├── MenuBarExtra
│   ├── 仪表板
│   ├── 当前额度摘要与 Reset 到期项
│   ├── 立即刷新
│   ├── 显示方式
│   ├── 开机启动（后续）
│   └── 退出
└── Window(id: "dashboard")
    └── DashboardShellView
        ├── Sidebar
        ├── Header
        └── Routed feature content
```

- 默认采用 SwiftUI `MenuBarExtra` 与单例 `Window(id: "dashboard")`。
- 只有当 SwiftUI 不能稳定实现现有动态标题或状态圆点时，才引入最小 AppKit `NSStatusItem` 封装；不预设大型 `AppDelegate`。
- 关闭 Dashboard Window 不退出菜单栏 App。
- 仪表板入口只打开/聚焦固定窗口，绝不重复创建。

### 4.2 状态与并发

`AppState` 是唯一运行时事实来源，标记 `@MainActor`：

```text
AppState
├── currentUsage: CodexUsageSnapshot?
├── lastSuccessfulUsage: CodexUsageSnapshot?
├── usageError: UserVisibleError?
├── refreshState: idle / refreshing
├── sessionActivity: SessionActivity
├── selectedRoute: DashboardRoute
└── settings: AppSettings
```

规则：

- 手动刷新、启动刷新与定时刷新共用一个任务；刷新中再次请求直接复用/忽略，不并发请求。
- 60 秒额度轮询在主窗口关闭后继续；窗口只订阅 `AppState`，不得自行请求接口。
- 失败不得覆盖 `lastSuccessfulUsage`；UI 同时展示旧数据时间和最新错误。

### 4.3 数据源与持久化

| 模块 | 职责 | 首次接入 |
|---|---|---:|
| `CodexUsageSource` | 只在请求期间读取 `$CODEX_HOME/auth.json` 或 `~/.codex/auth.json`；获取 Usage/Reset 并脱敏解析 | N2 |
| `SessionActivitySource` | 读取近期 JSONL 状态事件，聚合状态灯 | N3 |
| `SnapshotStore` | 读取/写入本应用自己的脱敏快照 JSON | N5 |
| `SessionIndexSource` | 只读会话元数据索引 | N7 |
| `PluginSkillSource` | 只读插件 manifest、Skill `SKILL.md` 元数据 | N8 |
| `SettingsStore` | `UserDefaults` 中保存本应用设置 | N6 |

首版不使用 Keychain，因为本应用不拥有、复制或持久化 Codex 凭据。快照目录固定为：

```text
~/Library/Application Support/Codex Bar/
├── usage-snapshots.json
└── indexes/
```

## 5. 原型对齐与数据真实性

原型中的导航、紧凑居中窗口、固定侧栏、顶部刷新、卡片层级、列表滚动、模态详情、搜索筛选、空状态和深浅色主题，均作为 UI 验收基线。

| 原型内容 | 正式处理 |
|---|---|
| Week 百分比、短周期重置、Reset 数与到期列表 | N4 接入真实 `AppState` 数据 |
| `9,802 / 10,000` 绝对额度 | 不接入；当前源码只提供百分比 |
| 头像、昵称、Plus Plan、活跃徽章 | 默认隐藏；仅在验证 `plan_type` 后显示计划类型 |
| 历史快照、趋势图、导出、保存快照 | N5 后真实实现；无数据时显示空状态 |
| Token 总量、输入/输出、请求次数 | 不接入模拟数；N9 前始终显示数据不可用 |
| 会话名称、模型、cloud/local 标签 | N7 只展示已验证元数据，其他字段标 `[uncertain]` |
| 插件/Skills 数、来源和详情 | N8 仅来自真实扫描结果 |
| 数据源 `6/6` | N6 由实际可用数据源计算 |
| 设置 toggle、清空历史 | 仅在真实持久化和二次确认完成后启用 |

主窗口固定导航：

```text
仪表板
额度与 Reset
活动统计
Codex 会话
插件与 Skills
数据源
设置
```

阶段未接入的页面必须使用清晰空状态，不能保留原型数值、假记录或“已完成”提示。

## 6. 实施阶段

### N0：冻结与迁移设计（已完成）

- 审计当前 Tauri/Rust 数据流、菜单栏、刷新、错误处理和测试。
- 确认纯原生架构、免费分发、非 Sandbox、Xcode 目录层级和原型基线。
- 不修改 Tauri 应用代码。

### N1：创建原生工程与窗口骨架

范围：

- 创建 `macos/CodexBar/CodexBar.xcodeproj` 与目录结构；
- 建立 Accessory 风格菜单栏 App；
- 创建单例 Dashboard Window；
- 按原型实现侧栏、顶部、主题切换和七个页面壳；
- 关闭窗口后菜单栏继续运行。

不做：真实数据读取、刷新、快照、会话扫描、设置保存、自动启动、导出。

验收：可启动、可从菜单栏打开/聚焦唯一窗口、所有页面可切换、无模拟业务数据、旧 Tauri App 未受影响。

### N2：Usage/Reset Source 与安全解析

- 迁移 `codex.rs` 的认证文件定位、大小限制、JWT account id 回退、请求头敏感标记、双 Usage endpoint 回退、Reset 回退和 1 MB 响应限制；
- 迁移剩余比例、窗口、时间戳与 Reset 到期字段的兼容解析；
- 建立 XCTest 覆盖这些解析行为；
- 不实现任何 UI 以外的持久化。

验收：不输出敏感信息，未登录/限流/网络失败/格式变化均返回安全错误。

### N3：菜单栏功能 1:1 对等

- `AppState` 刷新互斥、启动刷新和 60 秒轮询；
- 迁移详细/简略/仅图标显示方式；
- 迁移会话活动状态灯和 Python Hook 回退；
- 迁移退出行为。

验收：原生菜单栏与旧版的核心显示、刷新和状态灯行为等价；迁移测试时不同时运行两套应用，避免重复请求。

### N4：真实额度与 Reset 页面

- 将 `AppState` 接入仪表板、额度与 Reset 页；
- 展示周额度、短周期（如存在）、Reset 数、全部到期时间、更新时间、加载/空/错误状态；
- 刷新失败时继续展示最后成功数据；
- 原型的绝对额度和 Token 模拟数不接入。

验收：同一次刷新同步菜单栏和主窗口，不额外发起第二个 Usage 请求。

### N5：快照与活动趋势

- 新增 `SnapshotStore`、快照去重、保留期、清空确认和导出；
- 接入原型的历史快照与趋势图；
- 仅显示“基于额度快照的估算变化”，标注数据缺口与估算属性。

验收：重启可恢复；无记录不绘制伪造曲线；不声称精准 Token。

### N6：数据源与设置

- 数据源页显示 Usage、Reset、会话活动、快照等已接入源的状态、时间、风险和脱敏错误；
- 设置页实现菜单栏显示方式、主题、快照保留与隐私读取开关；
- 迁移开机启动到 `SMAppService`；
- 开启真实 toggle、数据源计数与清空历史操作。

验收：设置重启后恢复；危险操作二次确认；单源失败不影响全局。

### N7：会话索引

- 先探测/验证会话路径和字段，再建立独立只读索引；
- 支持搜索、排序、显示经验证的标题/路径/时间/大小、打开项目目录；
- 损坏文件跳过；默认不读取或展示正文。

验收：大量文件下不会阻塞主线程；未知模型、模式、cloud/local、Token 字段不展示。

### N8：插件与 Skills

- 验证插件根目录、manifest 与 `SKILL.md`；
- 建立只读列表、计数、搜索、筛选、详情、路径复制；
- 允许版本、状态、归属关系缺失。

- 默认只读 Codex 本地数据；仅允许用户在“插件与 Skills”详情弹窗明确确认后，卸载满足路径保护规则的本地 Skill。不得修改插件、MCP、Codex 认证、会话或内部数据库。

### N9：精准 Token 可行性与稳定性

- 单独验证是否存在合规、稳定、可解释的精确 Token 数据源；
- 有明确来源才接入输入/输出/缓存/总 Token；没有则保持 N5 的额度变化估算；
- 精准与估算必须明确区分。

### N10：免费分发与 Tauri 退役

- 在干净用户环境进行原生版回归；
- 导出未签名 `.app`，打包 DMG 并发布 GitHub Releases；
- Release Notes 明确未签名/未公证及首次打开的系统提示；
- 用户验收后，再决定保留或归档 `src-tauri/` 与 `dist/`，不自动删除。

## 7. 测试与验收

| 层级 | 验证重点 |
|---|---|
| XCTest | Usage 解析、endpoint 回退、比例/日期、Reset 到期排序、刷新互斥、会话状态聚合、快照去重 |
| 手动菜单栏验证 | 标题三种显示、刷新、到期列表、状态灯、窗口打开/关闭、退出 |
| 主窗口验证 | 单例、路由、深浅色、空/加载/错误状态、窗口尺寸和滚动 |
| 数据源验证 | 未登录、401/403、429、断网、格式变化、权限拒绝、损坏 JSONL |
| 回归验证 | 原生版菜单栏与旧 Tauri 版行为对照；每次只运行一个版本 |
| 分发验证 | 未签名 DMG 从 GitHub 下载后可解压、可打开并按系统流程手动允许 |

每个阶段完成条件：

- 仅完成该阶段范围，不提前接入模拟功能；
- 相关 XCTest 通过；
- 不破坏已经迁移的菜单栏能力；
- 有加载、空和错误状态；
- 无新增未说明的敏感读取/存储；
- 用户验收后才进入下一阶段。

## 8. 风险与回滚

| 风险 | 应对 |
|---|---|
| 私有 Usage 接口变化 | 迁移现有全部兼容解析；单独封装、脱敏错误、保留最后成功数据 |
| 未签名 DMG 安装摩擦 | Release 明确说明；首版定位自用/技术用户，不承诺无拦截体验 |
| `~/.codex` 无访问权限 | 启动时探测，显示可理解错误，不提权、不绕过权限 |
| 原型模拟数据误导 | 按本计划的阶段映射，未验证字段永不显示数值 |
| 原生迁移回归 | 旧 Tauri 版本保留至 N10；原生版不通过验收即回退使用旧版 |
| 同时运行两个版本 | 迁移测试中一次只启动一个，避免重复 Usage 轮询 |

## 9. 当前状态

N1 起的原生迁移已落地；后续只按当前需求、README 产品边界和实际测试结果维护，不再等待旧计划中的阶段启动口令。
