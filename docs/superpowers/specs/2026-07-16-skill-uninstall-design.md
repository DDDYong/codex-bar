# Skill 卸载设计

## 目标

在原生 macOS 应用的“插件与 Skills”页面中，为用户已安装的本地 Skill 提供受保护的卸载能力。入口位于现有详情弹窗；本次不提供 Skill 安装、插件卸载或 MCP 删除。

## 范围与边界

- 仅处理 `PluginSkillEntry.Kind.skill`。
- 仅允许删除当前用户 `~/.codex/skills` 目录下的 Skill 目录。
- 删除前必须由用户在详情弹窗中二次确认；确认内容包含 Skill 名称和实际将删除的目录。
- 不读取、展示、保存或上传 Skill 正文；校验只依赖已索引的路径和 `SKILL.md` 是否存在。
- 操作完成后重新索引 Skill 列表，并关闭详情弹窗。
- 若路径不安全、目录不存在、缺少 `SKILL.md` 或文件系统操作失败，保留详情弹窗并显示可理解的错误。

## 设计

新增一个独立、可注入测试的 `SkillLifecycleManaging` 协议与默认实现：

```text
PluginSkillDetailSheet
  -> AppState.uninstallSkill(entry)
    -> SkillLifecycleSource.uninstall(entry)
      -> FileManager.removeItem(skillDirectory)
  -> AppState.refreshPluginSkillIndex()
```

`SkillLifecycleSource` 将 `entry.path` 解析为 `SKILL.md` 文件路径，规范化符号链接后的路径，并同时验证：

1. 条目类型为 Skill；
2. 文件名为 `SKILL.md`；
3. 文件存在且为普通文件；
4. 父目录位于规范化后的 `~/.codex/skills/` 根目录内。

通过全部校验后，删除父目录及其资源。任何校验失败均拒绝删除。

`AppState` 沿用会话操作的单操作互斥模式：公开当前正在操作的 Skill ID 与错误信息；在执行期间阻止重复点击；成功后重新索引。插件与 MCP 不会进入该操作路径。

详情弹窗对 Skill 展示“卸载 Skill”按钮。点击按钮先展示 SwiftUI 确认对话框；确认按钮使用破坏性样式。操作中的按钮显示进度并禁用，错误显示在弹窗底部。非 Skill 条目不显示卸载入口。

## 测试与验证

- 为生命周期服务补充单元测试：正常删除、非 Skill 拒绝、`SKILL.md` 以外的路径拒绝、根目录外路径拒绝、缺失文件拒绝。
- 构建并运行现有 macOS 测试套件：

```sh
xcodebuild -project macos/CodexBar/CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test
```

- 手工验证：详情弹窗中仅 Skill 有卸载按钮；取消不改变文件；确认后条目从重新索引结果中消失；失败时仍可看到错误原因。

## 文档边界更新

产品文档的 Skills “只读”规则调整为：默认只读；仅在用户从详情弹窗明确确认时，允许删除符合路径保护规则的本地 Skill。其他 Codex 数据和配置仍保持原有边界。
