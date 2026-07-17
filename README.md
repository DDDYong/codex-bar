# Codex Bar

Codex Bar 是一个面向 macOS 的原生 SwiftUI 菜单栏应用，用于在本机查看 Codex 的额度与 Reset 信息、会话活动、插件与 Skills，以及全设备 Token 活动汇总。

它以“本机数据、透明边界、可解释统计”为原则：额度趋势与全设备 Token 活动是两套不同的数据，不会相互替代或混写。

## 功能概览

- 菜单栏
  - 显示额度摘要与会话活动状态。
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
  - 仅读取 JSONL 会话首行元数据和独立索引中的线程名称，不读取或展示会话正文。
  - 支持归档、取消归档和删除受保护目录中的会话文件。
- 插件与 Skills
  - 扫描本机 Codex 插件、Skills 和 MCP 服务配置。
  - 仅允许卸载 `~/.codex/skills` 内、包含 `SKILL.md` 的 Skill 目录；插件与 MCP 不提供卸载入口。
- 数据源与设置
  - 展示各数据源状态。
  - 支持主题、菜单栏显示方式、快照保留期、会话/插件索引与 Token 热力图周期设置。

## 数据来源与统计口径

| 数据 | 来源 | 说明 |
| --- | --- | --- |
| Week / 短周期额度、Reset | 本机 Codex Usage / Reset 数据 | 仅用于额度与 Reset 页面及额度快照趋势 |
| 全设备 Token | `codex app-server --stdio` 的 `account/usage/read` | 包含累计 Token、峰值日、最长任务、连续天数和每日用量 |
| 会话索引 | `~/.codex/sessions`、`~/.codex/archived_sessions` 与 `session_index.jsonl` | 仅读取文件元数据和标题索引 |
| 插件、Skills、MCP | `~/.codex/plugins`、`~/.codex/skills`、`~/.codex/config.toml` | 读取安装与配置元数据 |

> 额度快照趋势是额度百分比变化，不是 Token 用量估算，更不会显示为精准 Token。

## 隐私与安全边界

- 不保存、不显示、不导出 Codex 登录 Token、Cookie、Authorization Header 或认证文件原文。
- 不读取、不保存、不展示会话正文。
- 全设备 Token 数据通过本机 Codex CLI 的 app-server 读取，应用只持久化统计汇总与每日 Token 桶。
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

可用参数：

```bash
./script/build_and_run.sh --verify     # 构建、安装、启动并确认进程存在
./script/build_and_run.sh --debug      # 使用 lldb 启动
./script/build_and_run.sh --logs       # 启动后输出应用日志
./script/build_and_run.sh --telemetry  # 启动后输出应用 telemetry 日志
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

## 当前限制

- 全设备 Token 功能依赖本机已安装、已登录且支持 app-server 的 Codex CLI。
- 应用不提供跨设备登录、云端同步或独立账户体系。
- 应用只处理本机可访问的 Codex 数据与配置；不同 Codex CLI 版本返回字段变化时，相关数据源会显示错误而不会伪造数据。
