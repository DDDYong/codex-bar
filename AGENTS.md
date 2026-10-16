# CodexBar 项目协作规范

## 已确认的产品标准

### 状态栏显示

- 状态栏支持详细、简略、仅图标三种显示模式。
- 状态栏支持单行/多行和左对齐/居中对齐/右对齐；这些选项统一放在“显示方式”菜单中。
- 多行模式的主指标和次指标使用相同的字体样式，不通过 Semibold/Regular 区分层级。
- 单行模式保持当前已有字号；多行模式必须保证第二行完整可见，不能因为切换模式导致裁切。
- 周额度使用 `W`，当天信息使用紧凑的短格式或省略；第三方 Provider 遵循与官方数据相同的两行排版规则。
- 菜单栏中的 Codex 图标保留原始蓝紫色品牌图标；运行/等待/失败等状态圆点可以继续使用语义状态色。仪表盘中的 Provider 图标可以保留品牌色。

### Provider 默认状态

- 首次运行或没有已保存选择时，所有第三方 Provider（包括 GLM）默认关闭。
- 用户明确开启 Provider 后，正常应用运行需要持久化该选择。
- 测试不得使用生产 `UserDefaults`，不得把测试中临时开启的 Provider 写入真实应用配置。

## 本地构建与安装标准

- 本地安装统一使用 `script/build_and_run.sh`，不要直接打开 `.build` 或 Xcode DerivedData 中的应用副本。
- 安装前停止已有的 `CodexBar`/`Codex Bar` 进程；运行中的应用只允许来自 `/Applications/CodexBar.app`。
- 安装后只保留 `/Applications/CodexBar.app` 作为活动应用。旧命名副本以及项目 `.build`、Xcode DerivedData 中的构建副本不得继续注册到 LaunchServices。
- 构建脚本清理旧副本时应优先注销明确的 LaunchServices 注册，再删除明确目标；不得用宽泛路径删除用户的其他应用或数据。
- 安装验证至少确认：签名有效、只有一个 CodexBar 进程、LaunchServices 不再显示旧构建路径。

## 修改与验证

- 保持已有用户配置、钥匙串和登录状态；修复重复图标时不要通过清空全部应用偏好来解决。
- 修改安装脚本后至少执行 `bash -n script/build_and_run.sh`，并用 `./script/build_and_run.sh --verify` 做一次实际安装验证。
- Swift 代码改动完成后运行相关测试；测试通过不等于已经完成实际安装验证，二者需要分别记录。
