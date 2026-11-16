# 安全说明（SECURITY）

## 支持范围与报告方式

计划台是本地优先的个人数据软件，数据默认只保存在本机。若你发现安全问题，请**不要**
直接开公开 Issue，请通过 GitHub 仓库的 Security 页面（`Security` → `Report a vulnerability`）
或仓库主页给出的联系方式私下报告，并附上复现步骤与影响范围。我们会尽快确认。

## 本项目如何处理敏感数据

| 数据 | 存放位置 | 是否进入 Git |
|---|---|---|
| 日程 / 项目 / 任务 / 备注 | 本机 SQLite（`app.db`，WAL 模式） | 否 |
| 本地备份 | 数据目录下的 `backups/*.json` 与恢复前快照 | 否 |
| 云同步登录令牌 | Windows：凭据管理器（DPAPI）；Linux：Secret Service；Android：Keystore（AES-256-GCM） | 否 |
| 云服务器账号密码 | 不持久化（登录时使用，令牌另存） | 否 |
| Android 正式签名密钥 | 仓库之外的本地目录 / CI Secrets | 否 |
| 自建服务端数据库 | 服务端 `pb_data/` | 否 |

- 仓库中**没有**真实用户数据、真实服务器地址、生产配置、密钥或令牌。
- 示例与测试数据全部为虚构内容（`example.com`、`jihuatai.local` 等）。
- 云端同步是可选项：不登录即完全离线；断网时本地功能不受影响。

## 自建云同步服务端的安全建议

1. 只使用 HTTPS，`pb_data` 目录仅服务账号可读写，PocketBase 默认只监听 `127.0.0.1`，
   由反向代理终结 TLS（参考 `docs/DEPLOYMENT.md`）。
2. 注册默认关闭，账号由管理员创建；`users` 集合的规则限制为只能读写自己的记录。
3. 管理员密码请使用强随机值，**不要**写进任何代码、脚本或提交到 Git 的文件。
4. 定期备份 `pb_data`，并离线保存服务端凭据。

## 供应链

- GitHub Actions 中使用的所有第三方 Action 均固定到 commit SHA。
- Flutter SDK 在 CI 中按固定版本下载并校验 SHA-256。
- 构建只使用官方 Runner 与官方 Flutter 工具链，不执行仓库外的第三方构建脚本。
