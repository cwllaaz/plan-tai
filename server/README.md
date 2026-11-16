# 计划台 V2.0 · 云同步服务端（PocketBase）

> 协议以 `docs/sync/API_CONTRACT.md` 为准；本目录实现 **行为契约**，不要求与
> PocketBase 的 collection API 一致。业务表全部是原生 SQLite 表（`pa_*`），
> 客户端只能通过 `/api/planner/*` 自定义路由读写，owner 一律取自认证身份。

## 1. 版本与文件

| 项 | 值 |
|---|---|
| PocketBase | **0.23.12**（JSVM hooks：`routerAdd` / `onRecordAuthWithPasswordRequest` / `__hooks`） |
| 服务端可执行文件 | `server/bin/pocketbase.exe`（**不提交 Git**，见 `.gitignore`） |
| 业务库 | `server/pb_data/data.db`（**不提交 Git**） |
| 路由 | `server/pb_hooks/routes.pb.js` |
| 业务逻辑 | `server/pb_hooks/lib/{push,pull,state,db,validate,util,auth}.js` |
| 迁移 | `server/pb_migrations/*.js` |

> 为什么锁 0.23.12：`pb_hooks` 的 `$apis.requireAuth`、`e.requestInfo().body`、
> `app.runInTransaction` 等 API 在该版本验证可用；升级大版本需重新做 JSVM 回归。

## 2. 本地启动（开发 / 测试）

```powershell
# 1) 下载 PocketBase 0.23.12（脚本会做，也可手动放到 server/bin）
#    https://github.com/pocketbase/pocketbase/releases/tag/v0.23.12

# 2) 创建管理员（只需一次）
# 密码请自行设置（不要写进任何提交到 Git 的文件）
server\bin\pocketbase.exe superuser upsert admin@jihuatai.local '<管理员密码>' `
  --dir=server\pb_data

# 3) 启动（只监听 127.0.0.1）
$env:PA_RATE_LIMIT_AUTH='200'; $env:PA_RATE_LIMIT_SYNC='1000'
server\bin\pocketbase.exe serve --dev --http=127.0.0.1:8090 `
  --dir=server\pb_data `
  --hooksDir=server\pb_hooks `
  --migrationsDir=server\pb_migrations
```

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:8090/api/planner/health
```

一键真实双客户端 E2E（会重置 `pb_data`，只用于开发机）：

```powershell
.\scripts\e2e-real-server.ps1
```

## 3. 账号

- 注册默认关闭（`users.createRule = null`），账号由管理员创建。
- 支持「邮箱或用户名」登录（`passwordAuth.identityFields = [email, username]`）。
- Token 14 天；客户端用 `/api/collections/users/auth-refresh` 续期。
- 普通用户只能看/改自己：`listRule/viewRule/updateRule = id = @request.auth.id`。

管理员创建普通用户：

```powershell
$admin = Invoke-RestMethod -Method Post `
  -Uri http://127.0.0.1:8090/api/collections/_superusers/auth-with-password `
  -ContentType application/json `
  -Body (@{identity='admin@jihuatai.local';password='<管理员密码>'} | ConvertTo-Json)

$body = @{ email='user@example.com'; password='<用户密码>';
  passwordConfirm='<用户密码>'; name='用户'; verified=$true } | ConvertTo-Json
Invoke-RestMethod -Method Post -Headers @{Authorization=$admin.token} `
  -Uri http://127.0.0.1:8090/api/collections/users/records `
  -ContentType 'application/json; charset=utf-8' `
  -Body ([Text.Encoding]::UTF8.GetBytes($body))
```

## 4. 路由

| 方法 | 路径 | 认证 | 说明 |
|---|---|---|---|
| GET | `/api/planner/health` | 否 | 握手：status/protocolVersion/minSchemaVersion/maxSchemaVersion/features/limits |
| POST | `/api/planner/sync/push` | Bearer | 1–100 条操作，事务内处理，按 opId 幂等 |
| POST | `/api/planner/sync/pull` | Bearer | 增量 / 快照，游标 `c1_<16 位>` |
| GET | `/api/planner/sync/state` | Bearer | 诊断：账号、记录数、最大游标 |

错误统一 `{code,message,retryable}`；业务冲突放在 push 200 响应的 `results[]`，
不使用 4xx 表示单条冲突。

## 5. 存储与语义

- `pa_projects` / `pa_spans` / `pa_tasks` / `pa_notes`：`PRIMARY KEY (owner, id)`，
  `revision` 乐观并发，`deleted_at` 软删除。
- `pa_changes(seq AUTOINCREMENT)`：全局单调递增，pull 游标只信它，不信客户端时钟。
- `pa_ops(owner, op_id)`：幂等去重，只缓存 **applied** 结果；冲突/拒绝重试会重新判定。
- 级联：删除 project → 同事务墓碑 span/task；删除 span → 同事务把 task.spanId 置 null
  （task revision +1，保留任务）。
- 备注：同 owner 同 date 仅一条未删除记录（partial unique index + 事务内校验）；
  冲突返回 `NOTE_DATE_TAKEN`。
- 时间：客户端允许 6 位微秒（`2026-11-15T08:00:00.123456Z`），服务端统一归一为秒级 UTC。

## 6. 生产部署（PocketBase + Caddy + systemd）

> 本仓库**不包含**生产服务器凭据；以下为可执行方案，实际变更需用户批准后执行。

1. **准备**（2C2G 足够）：
   - Linux x86_64，PocketBase 0.23.12；
   - 独立系统用户 `jihuatai`，目录 `/opt/jihuatai/{bin,pb_data,pb_hooks,pb_migrations}`；
   - 只监听 `127.0.0.1:8090`，由 Caddy 终止 TLS。
2. **HTTPS**：Caddy 反向代理 `sync.example.com` → `127.0.0.1:8090`，
   自动 Let's Encrypt；限制请求体 1 MiB、超时 30s。
3. **systemd**：`Restart=always`、`NoNewPrivileges=true`、`ProtectSystem=strict`，
   仅 `pb_data` 可写；环境变量 `PA_RATE_LIMIT_AUTH` / `PA_RATE_LIMIT_SYNC`。
4. **备份**：
   - PocketBase 内置备份（Dashboard → Settings → Backups）+ 定时 `sqlite3 .backup`；
   - 备份目录独立于 `pb_data`，至少保留 7 天；
   - 每季度做一次「恢复 → 健康检查 → 抽样同步」演练。
5. **账号**：关闭公开注册；管理员建号；离职/丢失设备时删除用户 token（改密码）。
6. **防火墙**：仅开放 22/80/443；8090 只绑定 loopback。

## 7. 已知边界

- 服务端未实现管理端 UI，账号与备份走 PocketBase Dashboard。
- 快照（`mode=snapshot`）按变更日志分页，不做实体级压缩；V1 数据量（<1 万条）足够。
- `pa_ops` 保留 180 天后可清理（见 API_CONTRACT §4.4.10）；当前未自动清理。
- 未做多实例/共享存储；单机 SQLite 是设计前提。
