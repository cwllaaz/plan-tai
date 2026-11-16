# 贡献指南（CONTRIBUTING）

感谢你愿意参与计划台。这是一个以**本地数据安全**和**可维护性**为优先目标的个人项目，
提交改动前请先读这几条约定。

## 开发环境

| 项 | 版本 / 要求 |
|---|---|
| Flutter | 3.50.0（stable），Dart 3.14 |
| Windows | Visual Studio 2022/2026 + 「使用 C++ 的桌面开发」工作负载 |
| Ubuntu | `clang cmake ninja-build pkg-config libgtk-3-dev libsqlite3-dev liblzma-dev` |
| Android | Android SDK（compileSdk 36）+ JDK 21 |

构建目录请使用**纯 ASCII 路径**（AGP 会拒绝非 ASCII 工程路径，Flutter 在部分
非 ASCII 路径下也可能失败）。

```bash
git clone https://github.com/<owner>/plan-tai.git
cd plan-tai
flutter pub get
flutter analyze     # 必须 0 issue
flutter test        # 必须全绿
```

## 提交前检查清单

- [ ] `flutter analyze` 零问题。
- [ ] `flutter test` 全部通过（跳过项需在 PR 中说明原因）。
- [ ] 涉及 UI 的改动附带截图（使用仓库内的演示数据，**不要**使用真实个人数据）。
- [ ] 没有提交任何密钥、令牌、`key.properties`、`*.jks`、数据库、日志或 `dist/` 产物。
- [ ] 没有引入会破坏 Windows / Ubuntu / Android 任一平台的依赖；如必须引入，
      说明平台隔离方案。
- [ ] 云同步相关改动遵守 `docs/sync/SECURITY.md`：令牌只经 `SecureTokenStore`，
      日志不含令牌、密码、完整响应体。

## 分支与提交信息

- 从 `main` 切出 `feature/<简述>` 或 `fix/<简述>`。
- 提交信息建议使用 Conventional Commits 前缀：`feat:`、`fix:`、`docs:`、`test:`、
  `refactor:`、`build:`、`chore:`；描述用中文或英文均可。
- 一个 PR 只做一件事；较大的改动请先开 Issue 讨论。

## 数据与隐私红线

- 仓库内所有示例、测试与截图必须使用**虚构数据**（`example.com` / `jihuatai.local`
  之类保留域名，虚构图目名称）。
- 不得提交真实数据库、备份、账号、服务器地址、日志或含个人信息的截图。
- 本地调试用的签名密钥、`.env`、`key.properties` 一律放在仓库之外。

## 发布流程（维护者）

1. 更新 `pubspec.yaml` 的 `version: <语义版本>+<构建号>`（构建号只增不减）。
2. 更新 `CHANGELOG.md`，在 `.github/release-notes/v<版本>.md` 写发布说明。
3. 合并到 `main`，推送标签 `git push origin v<版本>`。
4. `Release` 工作流自动构建三平台、生成 `SHA256SUMS.txt` 并创建 Release。
5. 检查 Release 资产与校验值，再对外公布。

## 行为准则

请保持友善、就事论事。数据丢失、隐私泄露、安全问题优先处理。
