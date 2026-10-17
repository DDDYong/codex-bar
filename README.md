# Codex Bar

Codex Bar 是一个面向 macOS 的原生 SwiftUI 菜单栏应用，用于在本机查看 Codex 的额度与 Reset 信息、会话活动、插件与 Skills，以及全设备 Token 活动汇总。

它以“本机数据、透明边界、可解释统计”为原则：额度趋势与全设备 Token 活动是两套不同的数据，不会相互替代或混写。

## 功能概览

- 菜单栏
  - 显示额度摘要与会话活动状态。
  - 仅当两个或更多 Provider 的会话同时处于运行状态时，每 6 秒轮播；只运行一方时固定显示正在消耗额度/金额的 Provider，全部空闲时默认显示 ChatGPT。
  - Provider 图标、指标和状态指示灯始终成组切换；状态栏宽度按当前原生文本实际测量，自适应切换显示项和显示方式。
  - 菜单栏图标使用 macOS 模板色；Codex 图标内部的 `>_` 图形在菜单栏中透明化。状态圆点独立放在图标右侧：运行中为绿色、等待输入为橙色、失败为红色，已完成或无活动时隐藏；当前屏与非当前屏的亮度由系统菜单栏状态统一适配。
  - 状态栏支持单行/多行：详细显示 5 小时指标与周额度重置信息，简略只保留两组核心额度，第三方统一为“主指标 / 辅助指标”；多行官方状态中 `5h`/`W` 固定在标签列居中，百分比及后续信息从统一位置左对齐；完整 Provider 明细在展开面板查看，仅图标不显示指标文字。
  - 状态栏文字使用原生 AppKit 绘制，不先渲染成 SwiftUI 位图；状态栏弹出菜单在显示项宽度变化时会重新对齐到当前菜单栏图标。
  - 弹出菜单打开后，点击菜单或状态栏图标以外的区域会自动收起。
  - 支持打开仪表板、立即刷新、切换显示方式、登录时启动和退出。
- 仪表板
  - 只维护一个普通层级窗口；重复打开时激活并聚焦已有窗口，关闭窗口不会退出菜单栏应用。
  - 显示 Week 额度、Reset 次数、到期时间、最近额度快照趋势。
  - 显示全设备 Token 汇总、最近 7 日 Token 柱状图及悬停明细。
- 额度与 Reset
  - 从本机 Codex 环境读取可用额度、短周期额度和 Reset 到期信息。
- 活动统计
  - 从本机 `codex app-server --stdio` 读取全设备 Token 汇总与每日用量。
  - 提供每日、每周、累计三种热力图口径。
  - 支持近一个月、近三个月、近半年、近一年展示范围。
- Codex 会话
  - 会话索引仅读取 JSONL 首行元数据和独立索引中的线程名称；活动判断临时读取近期文件的有限前缀与尾部，只提取 Provider/模型元数据和事件类型，不保存或展示正文。
  - 支持归档、取消归档和删除受保护目录中的会话文件。
- 插件与 Skills
  - 扫描本机 Codex 插件、Skills 和 MCP 服务配置。
  - 仅允许卸载 `~/.codex/skills` 内、包含 `SKILL.md` 的 Skill 目录；插件与 MCP 不提供卸载入口。
- 数据源与设置
  - 展示各数据源状态。
  - 支持主题、菜单栏显示方式、快照保留期、会话/插件索引与 Token 热力图周期设置。
  - 支持 DeepSeek、智谱 GLM 的独立启用、钥匙串凭据管理和连接测试；OpenRouter、SiliconFlow 已从活动 Provider 列表移除。
  - 所有第三方 Provider（包括 DeepSeek、智谱 GLM 和实验 Provider）首次安装默认关闭；用户主动启用后保存到本机设置，后续启动恢复上一次状态。
  - Kimi、MiniMax、火山方舟、通义千问位于默认关闭的实验区；实验能力和智谱 GLM 直连都不会更改 Codex 或 cc-switch 的 Provider 路由。

## 数据来源与统计口径

| 数据 | 来源 | 说明 |
| --- | --- | --- |
| Week / 短周期额度 | `https://chatgpt.com/backend-api/api/codex/usage`，失败时回退到兼容的 `/backend-api/wham/usage` | 仅用于额度页面、菜单栏及额度快照趋势；请求时读取本机 Codex 登录态 |
| Reset 次数与到期时间 | 优先通过 `codex app-server --stdio` 的 `account/rateLimits/read` 读取，失败时回退到 ChatGPT Reset credits 接口 | 只接受新鲜且未到期的数据；本地短时缓存用于回退，不把过期缓存当成最新结果 |
| DeepSeek 余额 | DeepSeek `/user/balance` | API Key 优先从 macOS 钥匙串读取；展示当前可用、充值与赠送余额，不把当前充值余额误作累计充值 |
| DeepSeek 今日/累计用量 | DeepSeek Platform `/api/v0/usage/amount` 与 `/api/v0/usage/cost` | 用户显式启用实验开关后，只读 Chrome 的 DeepSeek 平台登录态；今日与本月指标先返回，历史月份以受控并发在后台渐进缓存，未补齐前不显示累计值 |
| 智谱 GLM 连接 | [Z.AI Chat Completions](https://docs.z.ai/api-reference/introduction) 的 `https://api.z.ai/api/paas/v4/chat/completions` | 使用固定模型 `glm-5.3-flash` 做显式连接测试；当前公开 API 契约未提供余额或累计用量接口，因此只显示连接状态，不伪造账单指标 |
| 第三方今日请求、Token 与费用 | cc-switch `proxy_request_logs` | 以只读方式聚合受支持 Provider 的请求数、成功/失败数、Token、模型和成本；仅覆盖实际经过用户已启用代理的请求，不读取提示词、响应正文或错误正文 |
| MiniMax Token Plan 配额 | 官方 `mmx quota show --output json` | 仅在用户开启实验能力，且 `/opt/homebrew/bin/mmx` 或 `/usr/local/bin/mmx` 已安装、已登录时读取；展示 5 小时/周配额及 CLI 版本，不把配额伪装成余额 |
| 全设备 Token | `codex app-server --stdio` 的 `account/usage/read` | 包含累计 Token、峰值日、最长任务、连续天数和每日用量；支持每日/每周/累计热力图口径 |
| 会话索引 | `~/.codex/sessions`、`~/.codex/archived_sessions` 与 `session_index.jsonl` | 仅读取文件元数据和标题索引 |
| 插件、Skills、MCP | `~/.codex/plugins`、`~/.codex/skills`、`~/.codex/config.toml` | 读取安装与配置元数据 |

> 额度快照趋势是额度百分比变化，不是 Token 用量估算，更不会显示为精准 Token。API 消费趋势优先使用 Provider 返回的按日数据；GLM 等没有公开账单接口的 Provider 仅在存在 cc-switch 代理日志时展示本地请求趋势。统一快照还可包含同一采集周期成功刷新的第三方 Provider 聚合值及其独立更新时间、来源和过期语义；不包含凭据或原始响应。

## 隐私与安全边界

- 不保存、不显示、不导出 Codex 登录 Token、Cookie、Authorization Header 或认证文件原文。
- 第三方凭据仅持久化到 macOS 钥匙串，并按 Provider 与凭据类型隔离；不会写入 UserDefaults、快照或日志。
- DeepSeek 平台详细用量默认关闭；启用后读取 Chrome 中 `platform.deepseek.com` 的 `userToken`，Token 仅驻留进程内存，不写入设置、钥匙串、快照或日志；本地仅缓存凭据指纹和按月消费合计，不保存原始账单行。
- 不保存、不展示或导出会话正文。
- 会话活动检测临时读取近期 JSONL 的有限前缀与尾部，只提取 Provider/模型元数据和事件类型，用于判断运行、等待、完成或失败状态；未改动的文件复用元数据缓存。
- cc-switch 遥测以 SQLite 只读模式访问，并先校验 schema；查询不选择 `error_message`、请求体、响应体或 Provider 配置字段。
- 实验 Provider 默认关闭，不在 CodexBar 中保存其 API 凭据；智谱 GLM 的 API Key 也只保存到钥匙串，连接测试不会保存请求或响应正文；MiniMax CLI 的标准错误会被丢弃，不写日志或回显。
- 全设备 Token 数据通过本机 Codex CLI 的 app-server 读取，应用只持久化统计汇总与每日 Token 桶。
- GitHub Release 的 DMG 不包含构建者的 UserDefaults、钥匙串、Codex 会话、浏览器 Cookie 或 Application Support 数据；安装后只读取当前 macOS 用户本机的数据。
- 本应用自己的统计文件位于：

  ```text
  ~/Library/Application Support/Codex Bar/
  ├── usage-snapshots.json
  ├── profile-snapshot.json
  └── deepseek-history-cost-v1.json
  ```

  `deepseek-history-cost-v1.json` 只保存按当前平台登录态指纹隔离的历史月度消费汇总，不保存原始账单行或登录 Token。

- 会话删除和 Skill 卸载属于写操作，应用会限制可操作路径；请在执行前确认目标。

## 运行要求

- macOS 13 或更高版本
- Xcode（用于本地构建）
- Xcode 工程依赖 Swift Package `SweetCookieKit`（最低 `0.5.2`，用于读取 Chrome 中的 DeepSeek 平台登录态）；首次构建时需要让 Xcode 完成依赖解析
- 已安装并登录 Codex CLI
- 若需要全设备 Token 活动，Codex CLI 需支持：

  ```bash
  codex app-server --stdio
  ```

  可以先执行以下命令更新 CLI：

  ```bash
  codex update
  ```

## 本地构建与运行

项目提供统一启动脚本：

```bash
./script/build_and_run.sh
```

脚本会停止旧进程、构建 Debug 版本、安装到 `/Applications/CodexBar.app` 并启动。它也会清理遗留的 `/Applications/Codex Bar.app`，注销项目 `.build` 与 Xcode DerivedData 中的旧 LaunchServices 注册，确保系统只保留一个应用入口。

当前原生 SwiftUI 应用的 Debug 与 Release Bundle ID 均为 `com.codexbar.app`，Xcode 工程版本为 `MARKETING_VERSION=0.1.10`、build `3`。`package.json`、`src-tauri/` 和 `dist/` 是迁移期间保留的旧 Tauri 工件，不参与当前原生 macOS 构建；构建与安装流程不会尝试删除系统登录项。

可用参数：

```bash
./script/build_and_run.sh --verify     # 构建、安装、启动并确认进程存在
./script/build_and_run.sh --debug      # 使用 lldb 启动
./script/build_and_run.sh --logs       # 启动后输出应用日志
./script/build_and_run.sh --telemetry  # 启动后输出应用 telemetry 日志
```

安装时脚本会优先使用本机唯一可用的 Apple Development 证书重新签名，避免每次 Debug 构建都生成新的 ad-hoc 身份；如果本机有多个证书，可显式传入 `security find-identity -v -p codesigning` 输出中的 40 位证书哈希。没有可自动选择的证书时会保留 Xcode 构建签名并输出警告：

```bash
CODEXBAR_SIGNING_IDENTITY=<40 位证书哈希> ./script/build_and_run.sh
```

运行测试：

```bash
xcodebuild \
  -project macos/CodexBar/CodexBar.xcodeproj \
  -scheme CodexBar \
  -destination 'platform=macOS' \
  test
```

## 项目结构

```text
codex-bar/
├── macos/CodexBar/
│   ├── CodexBar.xcodeproj/        # Xcode 工程
│   ├── CodexBar/                  # 应用源码
│   │   ├── App/                   # 生命周期、全局状态、配置
│   │   ├── Features/Dashboard/    # 仪表板及各页面 UI
│   │   ├── Models/                # 领域模型
│   │   ├── Sources/               # Codex / 本机数据读取与受保护操作
│   │   ├── Persistence/           # 本应用快照与设置持久化
│   │   ├── SharedUI/              # 共享 UI
│   │   └── Resources/             # 应用资源
│   └── CodexBarTests/             # XCTest
├── package.json                   # 迁移期保留的旧 Tauri 元数据
├── src-tauri/                     # 旧 Tauri/Rust 实现，当前原生 App 不使用
├── dist/                          # 旧前端静态资源，当前原生 App 不使用
├── script/build_and_run.sh        # 构建、安装、启动入口
└── docs/                          # 设计、计划与实现记录
```

## 开发约定

- `AppState` 是应用运行时的单一状态入口，页面只订阅状态，不重复发起相同的数据请求。
- 数据源失败不应清空最近一次成功数据，也不应影响其他模块。
- 新增统计时必须清楚标注其数据来源与口径，不能把近似值标为精准 Token。
- 新增涉及本机文件变更的能力，必须做路径校验并保留显式用户操作入口。

## 常见问题

### 全设备 Token 活动没有数据

1. 在终端确认 `codex` 可用，并执行 `codex update`。
2. 确认当前 Codex CLI 已登录。
3. 在“活动统计”页点击“立即同步”。
4. 若仍失败，在“数据源”页查看错误提示。

### 为什么额度趋势和 Token 活动数值不一致？

两者来源和含义不同。额度趋势记录的是本应用保存的剩余额度百分比；Token 活动来自 Codex app-server 的全设备账户汇总与每日 Token 桶，因此不应直接相加或相互推导。

### 为什么打开仪表盘时不会新建第二个窗口？

仪表盘由一个普通层级的 `NSWindowController` 持有。重复点击“打开仪表盘”只会激活并聚焦已有窗口；关闭窗口只关闭仪表盘，不会退出仍在菜单栏运行的 Codex Bar。

### 菜单栏状态圆点的颜色代表什么？

圆点只表示最近检测到的会话活动，不表示额度剩余比例：运行中为绿色，等待输入或审批为橙色，失败为红色；已完成、无活动或尚未识别时不显示圆点。圆点与 Provider 图标绑定切换，图标使用系统菜单栏模板色。

### 应用为什么每次构建后只有一个副本？

`script/build_and_run.sh` 固定将最新构建安装到 `/Applications/CodexBar.app`，并在启动前终止旧进程、删除旧命名的应用副本、注销旧构建路径的 LaunchServices 注册。不要直接打开 `.build` 或 Xcode DerivedData 中的应用副本，否则系统可能再次显示多个 CodexBar 图标。

### 如何配置智谱 GLM？

打开“设置 > 数据源”，找到“智谱 GLM”，输入 Z.AI API Key 后点击“保存并测试”。密钥只进入 macOS 钥匙串；测试会向官方 `glm-5.3-flash` 接口发送一次最小请求，后台刷新不会重复调用模型，也不会修改 Codex 或 cc-switch 的路由。

### 登录时启动为什么需要系统批准？

Codex Bar 使用 macOS 13+ 的 `SMAppService.mainApp` 注册登录项，并持久化用户的启用意图。应用更新或本地构建替换后会在下次启动时自动核对并补注册；若系统状态为“需要批准”，应用会给出入口跳转到“系统设置 > 通用 > 登录项”。Debug 本地构建使用临时签名，最终发布版本仍应使用稳定签名完成重启验收。

## 当前限制

- 全设备 Token 功能依赖本机已安装、已登录且支持 app-server 的 Codex CLI。
- 应用不提供跨设备登录、云端同步或独立账户体系。
- 应用只处理本机可访问的 Codex 数据与配置；不同 Codex CLI 版本返回字段变化时，相关数据源会显示错误而不会伪造数据。
- 本版第三方 Provider 与 ChatGPT 仅在同一个“额度与 Reset”页面内以左右两列展示：左侧为订阅与 API 指标，右侧为 Reset 与 API 消费趋势；不新增独立第三方导航或历史页面，也不会生成或伪造 DeepSeek 会话历史。
- DeepSeek 官方公开余额接口不提供累计充值、累计已用或按 API Key 的今日明细。可选的平台登录态会逐月汇总平台报告的历史消费作为“已用”，并以“当前可用 + 累计已用”计算菜单中的“累计”；该值是账户额度总量口径，不等同于官方历史充值流水，且私有仪表盘接口可能随时变化。
- OpenRouter 和 SiliconFlow 已从活动 Provider 列表与应用启动 wiring 移除；旧设置、快照和钥匙串命名仅保留兼容解析，不会被新版本主动删除。
- 智谱 GLM 当前通过通用 Model API 做连接测试；公开 API 不提供余额、累计用量或历史账单接口，因此不会推算账户账单。GLM 趋势只统计经过本机 cc-switch 的请求日志；GLM Coding Plan 的专用 endpoint 需要另行配置，不会自动切换。
- 当 cc-switch 本地代理开关关闭或数据库不可用时，代理遥测保持未配置；CodexBar 不会为统计而自动打开代理。
- 实验 Provider 的作用是补充官方没有公开的本地请求统计：Kimi、火山方舟和通义千问读取 cc-switch 代理日志，MiniMax 可额外读取官方 CLI Token Plan；它们不会保存 API Key、切换 Provider 路由或接管请求，没有对应日志/登录态时安全降级为不可用。
