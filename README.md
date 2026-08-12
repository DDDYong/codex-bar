# Codex Bar

Codex Bar 是一个面向 macOS 的原生 SwiftUI 菜单栏应用，用于在本机查看 Codex 的额度与 Reset 信息、会话活动、插件与 Skills，以及全设备 Token 活动汇总。

它以“本机数据、透明边界、可解释统计”为原则：额度趋势与全设备 Token 活动是两套不同的数据，不会相互替代或混写。

## 功能概览

- 菜单栏
  - 显示额度摘要与会话活动状态。
  - 仅当两个或更多 Provider 的会话同时处于运行状态时，每 6 秒轮播；只运行一方时固定显示正在消耗额度/金额的 Provider，全部空闲时默认显示 ChatGPT。
  - 轮播项使用统一占位宽度，Provider 图标、指标和右下角活动指示灯始终成组切换。
  - 第三方显示方式：详细为“图标 + 可用/预算/配额 + Provider 可核验明细”，简略为“图标 + 可用余额、Key 预算或配额”，仅图标不显示指标文字。
  - 支持打开仪表板、立即刷新、切换显示方式、登录时启动和退出。
- 仪表板
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
  - 支持 DeepSeek、OpenRouter、SiliconFlow 的独立启用、钥匙串凭据管理和连接测试。
  - Kimi、GLM、MiniMax、火山方舟、通义千问位于默认关闭的实验区；实验能力不会更改 Codex 或 cc-switch 的 Provider 路由。

## 数据来源与统计口径

| 数据 | 来源 | 说明 |
| --- | --- | --- |
| Week / 短周期额度、Reset | 本机 Codex Usage / Reset 数据 | 仅用于额度与 Reset 页面及额度快照趋势 |
| DeepSeek 余额 | DeepSeek `/user/balance` | API Key 优先从 macOS 钥匙串读取；展示当前可用、充值与赠送余额，不把当前充值余额误作累计充值 |
| DeepSeek 今日/累计用量 | DeepSeek Platform `/api/v0/usage/amount` 与 `/api/v0/usage/cost` | 用户显式启用实验开关后，只读 Chrome 的 DeepSeek 平台登录态；今日与本月指标先返回，历史月份以受控并发在后台渐进缓存，未补齐前不显示累计值 |
| OpenRouter credits / Key 用量 | OpenRouter `/api/v1/credits` 与 `/api/v1/key` | Management Key 读取账户购买与累计使用；推理 API Key 读取 Key 预算和日/周/月消费；两种凭据和口径分开显示 |
| SiliconFlow 余额 | SiliconFlow `/v1/user/info` | 展示官方账户可用余额；官方接口没有返回的消费与 Token 明细不做推算 |
| 第三方今日请求、Token 与费用 | cc-switch `proxy_request_logs` | 以只读方式聚合受支持 Provider 的请求数、成功/失败数、Token、模型和成本；仅覆盖实际经过用户已启用代理的请求，不读取提示词、响应正文或错误正文 |
| MiniMax Token Plan 配额 | 官方 `mmx quota show --output json` | 仅在用户开启实验能力，且 `/opt/homebrew/bin/mmx` 或 `/usr/local/bin/mmx` 已安装、已登录时读取；展示 5 小时/周配额及 CLI 版本，不把配额伪装成余额 |
| 全设备 Token | `codex app-server --stdio` 的 `account/usage/read` | 包含累计 Token、峰值日、最长任务、连续天数和每日用量 |
| 会话索引 | `~/.codex/sessions`、`~/.codex/archived_sessions` 与 `session_index.jsonl` | 仅读取文件元数据和标题索引 |
| 插件、Skills、MCP | `~/.codex/plugins`、`~/.codex/skills`、`~/.codex/config.toml` | 读取安装与配置元数据 |

> 额度快照趋势是额度百分比变化，不是 Token 用量估算，更不会显示为精准 Token。统一快照还可包含同一采集周期成功刷新的第三方 Provider 聚合值及其独立更新时间、来源和过期语义；不包含凭据或原始响应。

## 隐私与安全边界

- 不保存、不显示、不导出 Codex 登录 Token、Cookie、Authorization Header 或认证文件原文。
- 第三方凭据仅持久化到 macOS 钥匙串，并按 Provider 与凭据类型隔离；不会写入 UserDefaults、快照或日志。
- DeepSeek 平台详细用量默认关闭；启用后读取 Chrome 中 `platform.deepseek.com` 的 `userToken`，Token 仅驻留进程内存，不写入设置、钥匙串、快照或日志；本地仅缓存凭据指纹和按月消费合计，不保存原始账单行。
- 不保存、不展示或导出会话正文。
- 会话活动检测临时读取近期 JSONL 的有限前缀与尾部，只提取 Provider/模型元数据和事件类型，用于判断运行、等待、完成或失败状态；未改动的文件复用元数据缓存。
- cc-switch 遥测以 SQLite 只读模式访问，并先校验 schema；查询不选择 `error_message`、请求体、响应体或 Provider 配置字段。
- 实验 Provider 默认关闭，不在 CodexBar 中保存其 API 凭据；MiniMax CLI 的标准错误会被丢弃，不写日志或回显。
- 全设备 Token 数据通过本机 Codex CLI 的 app-server 读取，应用只持久化统计汇总与每日 Token 桶。
- GitHub Release 的 DMG 不包含构建者的 UserDefaults、钥匙串、Codex 会话、浏览器 Cookie 或 Application Support 数据；安装后只读取当前 macOS 用户本机的数据。
- 本应用自己的统计文件位于：

  ```text
  ~/Library/Application Support/Codex Bar/
  ├── usage-snapshots.json
  └── profile-snapshot.json
  ```

- 会话删除和 Skill 卸载属于写操作，应用会限制可操作路径；请在执行前确认目标。

## 运行要求

- macOS 13 或更高版本
- Xcode（用于本地构建）
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

脚本会停止旧进程、构建 Debug 版本、安装到 `/Applications/CodexBar.app` 并启动。它也会清理遗留的 `/Applications/Codex Bar.app`，确保系统只保留一个应用副本。

当前原生 SwiftUI 应用的 Debug 与 Release Bundle ID 均为 `com.codexbar.app`，`MARKETING_VERSION` 与当前 `v0.1.5` tag 对齐。仓库不据此推断既有 DMG 的升级身份；构建与安装流程不会尝试删除系统登录项。

可用参数：

```bash
./script/build_and_run.sh --verify     # 构建、安装、启动并确认进程存在
./script/build_and_run.sh --debug      # 使用 lldb 启动
./script/build_and_run.sh --logs       # 启动后输出应用日志
./script/build_and_run.sh --telemetry  # 启动后输出应用 telemetry 日志
```

如需用本机证书重新签名安装副本，必须显式传入 `security find-identity -v -p codesigning` 输出中的 40 位证书哈希；未配置时脚本保留 Xcode 构建签名，不会自动挑选任意证书：

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

### 应用为什么每次构建后只有一个副本？

`script/build_and_run.sh` 固定将最新构建安装到 `/Applications/CodexBar.app`，并在启动前终止旧进程、删除旧命名的应用副本。

### 登录时启动为什么需要系统批准？

Codex Bar 使用 macOS 13+ 的 `SMAppService.mainApp` 注册登录项，并持久化用户的启用意图。应用更新或本地构建替换后会在下次启动时自动核对并补注册；若系统状态为“需要批准”，应用会给出入口跳转到“系统设置 > 通用 > 登录项”。Debug 本地构建使用临时签名，最终发布版本仍应使用稳定签名完成重启验收。

## 当前限制

- 全设备 Token 功能依赖本机已安装、已登录且支持 app-server 的 Codex CLI。
- 应用不提供跨设备登录、云端同步或独立账户体系。
- 应用只处理本机可访问的 Codex 数据与配置；不同 Codex CLI 版本返回字段变化时，相关数据源会显示错误而不会伪造数据。
- 本版第三方 Provider 与 ChatGPT 仅在同一个“额度与 Reset”页面内以独立成功/失败指标卡展示，并写入统一额度快照；不新增独立第三方导航或历史页面，也不会生成或伪造 DeepSeek 会话历史。
- DeepSeek 官方公开余额接口不提供累计充值、累计已用或按 API Key 的今日明细。可选的平台登录态会逐月汇总平台报告的历史消费作为“已用”，并以“当前可用 + 累计已用”计算菜单中的“累计”；该值是账户额度总量口径，不等同于官方历史充值流水，且私有仪表盘接口可能随时变化。
- SiliconFlow 当前只接入官方账户余额；OpenRouter 当前只接入账户 credits、当前 Key 预算和 Provider 报告的周期消费，不包含逐请求 Token 明细。
- OpenRouter 的账户 credits 需要 Management Key；普通推理 API Key 只能提供当前 Key 的预算与用量视角。
- OpenAI/Anthropic 组织用量阶段需要 Admin Key；当前没有配置 `OPENAI_API_KEY`，因此该阶段按用户决定跳过，也没有新增任何 OpenAI 凭据或修改现有订阅登录链路。
- 当前机器的 cc-switch 本地代理开关为关闭时，代理遥测会保持未配置；CodexBar 不会为统计而自动打开代理。
- Kimi、GLM、火山方舟和通义千问当前只提供实验性的 cc-switch 请求遥测。MiniMax 可额外读取官方 CLI Token Plan；没有安装 `mmx` 时安全降级为不可用。
