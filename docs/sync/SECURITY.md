# 计划台 V2.0 · 安全要求（SECURITY）

> 状态：**已冻结（2026-11-15）**。适用范围：Flutter 客户端（Windows/Ubuntu/Android/Web）、
> PocketBase 服务端、Caddy/反向代理、备份与运维。
> 目标不是“绝对安全”，而是：账号隔离、传输加密、凭证不落明文日志、
> 数据可恢复、2 核 2 GB 服务器不被轻易拖垮。

## 1. 威胁模型

| 威胁 | 影响 | 对策 |
|---|---|---|
| 中间人窃听/篡改 | 密码、token、数据泄露 | 强制 HTTPS/HSTS；证书校验；禁止明文 HTTP（localhost 例外） |
| 撞库/暴力破解 | 账号被接管 | 限流、失败冷却、强密码策略、可选 2FA（后续） |
| 跨账号越权 | A 读写 B 数据 | 服务端所有查询强制 owner；客户端按账号分库 |
| token 泄露 | 冒用账号 | 安全存储、短有效期、refresh、退出撤销、设备表 |
| 重放 push | 重复/覆盖数据 | opId 幂等 + requestHash；版本校验 |
| 恶意大 payload | 内存/磁盘耗尽 | 1 MiB 请求、256 KiB op、100 ops、代理层限制 |
| XSS（Web） | token 被窃 | 不用 localStorage；CSP；依赖审计 |
| 本地库被复制 | 数据泄露 | 依赖 OS 磁盘加密；V2 不做 E2EE；明确告知 |
| 备份泄露 | 全量数据泄露 | 备份目录权限、加密存储、不进 Git |
| 服务器被入侵 | 全量数据泄露 | 最小暴露面、非 root、自动更新、审计日志 |
| 误操作覆盖 | 数据丢失 | 绑定/恢复前强制备份；禁止整库覆盖 |

**不在 V2 范围**：端到端加密、零知识、抗有权限管理员的攻击、设备丢失远程擦除。

## 2. 传输安全

1. 正式环境只用 HTTPS（443）；HTTP 仅 `localhost`/`127.0.0.1` 开发。
2. 客户端必须校验证书；**禁止** `badCertificateCallback` 无条件放行。
3. HSTS：`max-age=31536000; includeSubDomains`（确认所有子域支持 HTTPS 后）。
4. TLS 1.2+；禁用弱套件；Caddy 自动证书；证书到期监控。
5. 反向代理限制：
   - `client_max_body_size 1m`；
   - 连接/读超时 30s；
   - 只暴露 80/443（80 仅跳转 443）；
   - PocketBase 只监听 `127.0.0.1:8090`。
6. Web 端 CORS 只允许正式域名，**不得** `*` + credentials；预检缓存合理。

## 3. 认证与密码

### 3.1 账号

- 使用 PocketBase 内置 `users` 集合；身份 = 邮箱；密码由 PocketBase 用
  bcrypt/argon2（以实际版本为准）哈希，服务端代码不接触明文。
- 注册默认关闭；仅管理员创建/邀请，避免公开注册滥用。
- 邮箱验证建议开启；未验证账号限制同步（返回 403 `ACCOUNT_DISABLED`）。
- 密码策略：至少 10 位，禁止常见弱密码；不强制复杂字符组合（长度优先）。
- 登录失败：按 IP + 账号双维度冷却；错误信息统一“账号或密码不正确”。

### 3.2 token

- PocketBase JWT 默认有效期以服务端配置为准；建议 ≤ 14 天，并启用 refresh。
- 客户端每次请求带 `Authorization: Bearer`；不得放 URL query。
- 401 时最多尝试一次 `auth-refresh`；失败清除 token，要求重新登录。
- 退出登录默认调用撤销（若服务端支持会话表）；即使失败也必须本地清除。
- token 不写入日志、不写入 `SyncStatus.message`、不写入崩溃报告。

### 3.3 客户端 token 存储

| 平台 | 存储 | 备注 |
|---|---|---|
| Windows | Windows Credential Manager（`flutter_secure_storage` 或 DPAPI 插件） | 不用明文文件/注册表 |
| Android | Android Keystore + EncryptedSharedPreferences | 关闭备份（`allowBackup=false` 或排除） |
| Ubuntu | libsecret（GNOME Keyring/KWallet） | 无 keyring 时提示安装，不退化为明文 |
| Web | `sessionStorage`（关闭标签即失效）；优先 HttpOnly/SameSite Cookie | **禁止 localStorage**；CSP 限制脚本源 |

- Web 端如使用 Cookie：`HttpOnly; Secure; SameSite=Lax/Strict`；需要 CSRF 防护
  （同步接口是 JSON + 自定义头，天然降低表单 CSRF 风险，但仍需校验 Origin）。
- 不把 token 写进 `device.json`/`binding.json`/数据库。

## 4. 账号与数据隔离

### 4.1 服务端

- 所有 `planner_entities`/`planner_ops`/`planner_devices` 查询必须带
  `owner = @request.auth.id`；**不得**用 body 中的 `ownerId` 作为过滤条件。
- `ownerId` 若出现在 body，只用于一致性校验；不匹配 → 403 `OWNER_MISMATCH`。
- 集合 API Rules 设为“拒绝所有客户端直接 CRUD”，只允许自定义路由/hook。
- 唯一索引包含 owner：`(owner, entityType, entityId)`、`(owner, opId)`、
  `(owner, serverSeq)`；note date 唯一也包含 owner。
- 管理员/运维账号与普通用户分离；PocketBase Admin UI 不暴露公网或加 IP 白名单。
- 删除用户时级联删除其同步数据（`cascadeDelete`），满足数据删除要求。

### 4.2 客户端

- 一个本地库只绑定一个 ownerId（见 ACCOUNT_BINDING）。
- 推送前校验 `binding.ownerId == currentAccount.ownerId`；不匹配立即停止。
- 切换账号切换数据库；禁止在同一个库上“按 owner 过滤行”。
- 账号 A 的 outbox/cursor/冲突不得复制到账号 B。

### 4.3 测试

- 必须有两账号隔离测试：B 登录后 pull 不到 A 的任何实体；B push 不能改 A 的
  entityId（即使知道 ID）；B 的 cursor 不影响 A。
- 伪造 body `ownerId` 必须 403；无 token 必须 401。

## 5. 输入校验与 DoS 防护

| 项 | 限制 |
|---|---|
| 请求体 | ≤ 1 MiB（代理 + 服务端双限） |
| 单 op payload | ≤ 256 KiB |
| ops/批 | ≤ 100 |
| 文本长度 | 项目名 80、任务标题 200、备注正文 10000、任务备注 5000、描述 2000 |
| focusItems | ≤ 3 条，单条 ≤ 60 |
| 日期 | 严格 `YYYY-MM-DD`，年份 1–9999 |
| 时刻 | 严格 ISO UTC，带 Z |
| 颜色 | `^#[0-9A-F]{6}$` |
| UUID | 小写 UUIDv7；非法直接拒绝 |
| 游标 | 只接受服务端格式，序号 ≤ 当前 owner 最大序号；否则 `CURSOR_INVALID` |
| 枚举 | 白名单，未知值拒绝 |

- 解析 JSON 用严格模式；拒绝未知顶层字段（防止参数走私）。
- 不允许客户端指定 `serverRevision`/`serverSeq`/`ownerId` 作为写入值。
- 错误信息不回显完整 payload（避免日志注入/隐私泄露）。
- 请求 ID 用于排障；日志转义换行/控制字符。

## 6. 幂等、重放与冲突安全

1. `opId` 全局唯一；`planner_ops(owner, opId)` 唯一索引。
2. `requestHash` 规范化 SHA-256；同 opId 不同内容 → 该 op `rejected` + `OP_ID_REUSED`。
3. 重试窗口 ≥ 180 天；清理后旧 op 可能被当新操作，客户端必须在该窗口内重试。
4. `baseRevision` 必须由客户端从**服务端确认过的版本**复制；不得用本地 revision。
5. 删除是软删除；不允许 update 复活墓碑。
6. 冲突不自动解决；不信任客户端 `clientUpdatedAt` 作为“最后写入”。

## 7. 日志与隐私

- **禁止记录**：密码、token、完整 payload、每日备注正文、任务备注正文、邮箱
  完整值（可哈希/脱敏）。
- 允许记录：requestId、owner 哈希/id 前缀、deviceId、entityType、opId、status、
  HTTP 码、耗时、错误码。
- 客户端崩溃报告不含 token/密码/正文；用户可关闭诊断上报。
- 服务器访问日志保留 ≤ 30 天；业务日志 ≤ 90 天；备份按保留策略。
- 遵守最小化原则：只收集同步必需数据。

## 8. 服务器加固（2C2G）

### 8.1 系统

- 独立非 root 用户运行 PocketBase；`NoNewPrivileges=true`、
  `ProtectSystem=strict`、`ProtectHome=true`、只读系统目录、仅数据目录可写。
- SSH：禁用密码登录，仅密钥；限制来源 IP（如可行）；fail2ban。
- 防火墙：仅 22/80/443；PocketBase 端口不对外。
- 自动安全更新（unattended-upgrades），内核/OpenSSL 及时修补。
- 时间同步（chrony/systemd-timesyncd）。
- 磁盘加密（如云厂商支持）；至少备份加密。

### 8.2 PocketBase

- 使用最新稳定版；关注安全公告；升级前备份 + 演练。
- Admin UI 不暴露公网；强密码 + 2FA（若版本支持）。
- 关闭公开注册；限制集合 API Rules；禁用不需要的端点。
- 数据目录权限 700；备份目录不在 Web 根下。
- `pb_data` 不进 Git；`.tmp` 开发数据不部署。

### 8.3 反向代理

- Caddy 自动 HTTPS；安全响应头：
  `Strict-Transport-Security`、`X-Content-Type-Options: nosniff`、
  `Referrer-Policy`、`Content-Security-Policy`（Web 端）。
- 请求体/速率限制；隐藏 `Server` 版本；关闭目录列表。
- 只代理必要路径；健康检查可公开，其余需 auth。

### 8.4 备份与恢复

- 每日 03:00 本地备份（PocketBase backup + SQLite 快照），每周异机/对象存储。
- 保留 7 日 + 4 周；备份加密（age/GPG）；密钥与备份分离。
- 每季度做一次恢复演练；记录 RPO/RTO（建议 RPO ≤ 24h，RTO ≤ 2h）。
- 备份文件权限 600；不上传公开网盘；不进 Git。

## 9. Web 端特别要求

- 使用 `sessionStorage` 或 HttpOnly Cookie；禁止 localStorage 存 token。
- CSP：`default-src 'self'; connect-src 'self' https://planner.example.com;
  script-src 'self'; object-src 'none'; base-uri 'none'`（按实际构建调整）。
- 不在 URL/Referer 中携带 token；不把 token 写入 DOM/日志。
- 第三方依赖审计（`flutter pub outdated`/SCA）；锁文件提交。
- 关闭浏览器标签后会话失效（sessionStorage 语义）；重新打开需登录或 refresh。

## 10. 事件响应

1. 发现 token 泄露：撤销该用户全部会话/轮换签名密钥；强制重新登录。
2. 发现服务端入侵：隔离主机、保留取证、从最近干净备份恢复、轮换所有密钥、
   通知用户（如适用法规）。
3. 发现数据损坏：停止写入、备份现场、用 `integrity_check` 与备份比对；
   不静默重建库。
4. 发现跨账号泄露：立即停服、审计 `planner_ops`/访问日志、修复 owner 过滤、
   通知受影响用户。
5. 所有安全事件记录时间线、影响范围、修复与复盘。

## 11. 安全验收清单

- [ ] 正式环境 HTTP 自动跳转 HTTPS；证书有效；HSTS 开启。
- [ ] 客户端无 `badCertificateCallback` 放行；token 存安全存储/ sessionStorage。
- [ ] 无 token 401；伪造 ownerId 403；B 无法读/写 A 数据。
- [ ] opId 重放不重复写；同 opId 不同内容 409。
- [ ] 超限 payload/ops 被 413/400 拒绝。
- [ ] 日志无密码/token/正文；错误响应无堆栈。
- [ ] PocketBase 非 root、仅本地监听；Admin UI 不公开。
- [ ] 备份加密、可恢复、不进 Git；恢复演练通过。
- [ ] 绑定/覆盖前有可校验备份；无自动跨账号上传路径。
