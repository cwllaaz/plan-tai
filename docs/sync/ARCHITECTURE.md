# 计划台 V2.0 · 云同步架构（ARCHITECTURE）

> 状态：**已冻结（2026-11-15）**。本文回答“为什么这样同步、各层职责、失败时怎么办”。
> 字段与编码见 [DATA_CONTRACT](DATA_CONTRACT.md)，HTTP 见 [API_CONTRACT](API_CONTRACT.md)。

## 1. 目标与非目标

### 目标

1. Windows / Ubuntu / Android / 浏览器使用**同一云端账号**的同一份数据。
2. 本地优先：断网仍可完整使用；同步是后台能力，不是保存前提。
3. 自动同步 + 手动“一键双向同步”。
4. 冲突可见、可选择，**绝不静默覆盖**。
5. 保留现有 Flutter 界面、日历业务与 SQLite 数据；V1 用户升级后数据不丢。
6. 自有 2 核 2 GB 服务器可承载（PocketBase + SQLite + Caddy）。
7. 账号隔离：绝不把 A 账号的本地数据上传到 B 账号。

### 非目标（V2 本阶段不做）

- 实时协作/光标/推送（WebSocket）。
- 字段级自动合并（CRDT/OT）。
- 端到端加密（E2EE）。
- 服务端全文搜索、附件/图片同步。
- 团队共享项目、权限角色。
- 完整服务端与真实同步引擎的实现（由 月历模块/B 在后续阶段完成）。

---

## 2. 总体结构

```
┌──────────────────────────────────────────────────────────────────┐
│ Flutter UI（数据层）                                             │
│  月历 / 项目页 / 每日面板 / 云账号与同步状态 / 冲突对话框           │
│  只依赖 PlannerRepository + CloudAccountService + SyncService      │
└───────────────┬──────────────────────────────┬───────────────────┘
                │ 本地读写（流）                 │ 登录/同步（Future/Stream）
┌───────────────▼──────────────┐   ┌───────────▼───────────────────┐
│ 本地数据层（每日面板模块）          │   │ 云服务层（每日面板模块）             │
│ SQLite v2 + PlannerRepository │   │ CloudAccountService            │
│ outbox / conflicts / cursor   │◄──┤ SyncService（push/pull/冲突）   │
└───────────────┬──────────────┘   └───────────┬───────────────────┘
                │                              │ HTTPS JSON
                │                    ┌─────────▼───────────────────┐
                │                    │ PocketBase（月历模块）        │
                │                    │ users / planner_entities /   │
                │                    │ planner_ops / planner_devices│
                │                    │ SQLite + 自定义 sync 路由    │
                │                    └─────────────────────────────┘
```

### 2.1 分层职责

| 层 | 负责 | 不负责 |
|---|---|---|
| UI | 展示、用户确认、冲突选择、状态提示 | 拼 HTTP、写 SQL、算 revision |
| 本地数据层 | 实体 CRUD、迁移、outbox、事务、流通知 | 网络、账号、冲突策略 |
| 云服务层 | 认证、token、HTTP、push/pull、应用远端变更、冲突持久化 | 直接改 UI 状态、绕过仓储写业务表 |
| 服务端 | 鉴权、owner 隔离、版本/游标、幂等、校验、级联、持久化 | 业务 UI、客户端本地库 |

**关键边界**：UI 永远不直接调 HTTP；同步层永远不直接 `setState`；
服务端永远不信任客户端时间与 `ownerId`。

---

## 3. 本地优先的工作区模型

### 3.1 为什么按账号分库

如果只用一个 `app.db` 再按 `ownerId` 过滤行，任何一处查询漏了 owner 条件都会
造成跨账号数据泄露；迁移与回滚风险也高。V2 采用**一个账号一个本地工作区**：

```
%APPDATA%\计划台\data\
├─ app.db                         # 既有本地库（local-default，可绑定一个账号）
├─ app.db.binding.json            # 该库的绑定记录（若已绑定）
├─ device.json                    # 安装级 deviceId，不随备份复制
├─ workspaces.json                # 可选：当前激活工作区指针（Agent D 维护）
├─ accounts\
│   └─ <ownerId>\
│       ├─ app.db                 # 该账号的工作区
│       └─ binding.json
├─ backups\                       # 现有 JSON/快照备份
└─ sync\                          # 可选：日志/诊断，不放 token
```

规则：

1. 既有 `app.db` 保持原路径，**不搬移、不重建**；首次绑定只写旁路
   `app.db.binding.json`，不动数据库内容。
2. 新账号默认新建 `accounts/<ownerId>/app.db`，从空库开始并全量拉取。
3. 一个本地库最多绑定一个 `ownerId`；一个账号可以有多台设备。
4. 切换账号 = 切换 Repository/数据库文件（需要重启或重建应用作用域），
   不是清空当前库。
5. 绑定记录在数据库外，数据库备份被复制到另一台机器时不会自动继承账号，
   避免“把 A 的库当 B 上传”。
6. `deviceId` 在数据库外；复制/恢复数据库不会复制设备身份。

### 3.2 仓库与应用装配

- `PlannerRepository` 接口保持不变；`SqlitePlannerRepository` 仍是唯一业务写入口。
- 云服务层持有同一个 `PlannerDatabase`/`SqlitePlannerRepository`，用于：
  - 读取待上传实体；
  - 在事务内应用远端变更；
  - 写 outbox/conflicts/cursor。
- 应用启动顺序（Agent D 负责）：
  1. 解析 `workspaces.json` / 绑定记录，确定激活工作区；
  2. 打开对应 SQLite；
  3. 构造 `V1` 仓储 + 云服务（若已登录）；
  4. `runApp`；
  5. 恢复会话并触发一次后台同步。
- 未登录时云服务可为 `null`；UI 显示“未登录”，本地功能不受影响。

---

## 4. 同步引擎的数据流

### 4.1 本地写入 → outbox

```
UI 调用 repository.create/update/delete
  → SqlitePlannerRepository 事务
      ├─ 写实体表（revision+1 / deletedAt）
      ├─ 写 change_log（审计）
      └─ 写 sync_outbox（opId、base=serverRevision、payload）
  → COMMIT
  → notifyChanged() → UI 流刷新
  → 触发器调度一次 debounce 同步
```

- outbox 与业务写入同事务，保证“写了业务但永远不上传”不会发生。
- `baseRevision` 取写入前的 `server_revision`；删除/级联同样入队。
- 未登录时 outbox 只积累，不发送；登录/绑定后再推。
- 本地 `revision` 与 `server_revision` 分离：前者给 UI 乐观并发，后者给同步。

### 4.2 一次同步（手动或自动）

```
syncNow()
 1. 前置检查：已登录、工作区绑定 owner 匹配、协议版本兼容、无并发 sync
 2. push：
    读取 pending outbox（按 project→span→task→note、createdAt 升序）
    分页 ≤100 条 → POST /sync/push
    逐条处理 results：
      applied/duplicate → 删除 outbox，写 server_revision
      conflict          → 写 sync_conflicts，保留 outbox 或转 failed
      rejected          → 标记 failed + 可读错误，停止该实体后续操作
 3. pull：
    从本地 cursor 增量拉（首次/修复用 snapshot）
    逐页事务应用：
      project/span/task/note upsert 或墓碑
      写 server_revision
      不写 outbox/change_log
      COMMIT 后保存 nextCursor
 4. 更新 SyncStatus（idle/needsAttention/offline/error）
 5. 若有冲突：状态 needsAttention，UI 显示“N 条冲突”
```

**顺序固定为 push → pull**。理由：

- 先上传本地意图，服务端才能给出权威冲突；
- 再拉取服务端最新状态与级联结果；
- 不先 pull 再 push，避免“刚拉下来的数据被本地旧 outbox 覆盖”。

### 4.3 为什么不用“云端覆盖本地”

| 覆盖式同步 | 本方案 |
|---|---|
| 云端旧数据可能抹掉本地新编辑 | 本地操作先入 outbox，逐条提交 |
| 删除会被对端“复活” | 墓碑 + 版本校验 |
| 无冲突概念 | 冲突持久化、用户选择 |
| 网络失败可能半库损坏 | 每页事务 + 可重放 |
| 多设备时钟不可信 | 服务端 cursor/revision 排序 |

### 4.4 自动上传 / 自动下载触发

两个开关**独立**，由用户分别控制：

| 触发 | 行为 |
|---|---|
| 自动上传打开 + 本地写入 | debounce 2s；只 push，不 pull |
| 自动下载打开 + 启动/恢复会话 | 绑定检查通过后 2s 内只 pull |
| 自动下载打开 + 每 5 分钟 | 仅在线、空闲时 pull |
| 自动上传打开 + 网络恢复 | 立即 push（有 outbox 时） |
| 自动下载打开 + 网络恢复 | 立即 pull |
| 手动“上传到云端” | 只 push，忽略定时器 |
| 手动“从云端更新” | 只 pull，忽略定时器 |
| 两个开关都打开 | 仍按方向分别调度；同一时刻只跑一个操作 |
| 应用退到后台/关闭 | 不强制；下次启动恢复 |

退避：失败后 1s、2s、4s…上限 5 分钟，加 0–30% 抖动。
连续 401 → 停止对应方向的自动操作并要求重新登录。
存在未解决冲突时，自动下载仍可拉取，但不得自动“解决”冲突。

---

## 5. 冲突策略

### 5.1 原则

1. 服务端只做**版本检测**，不做自动合并。
2. 冲突必须持久化到本地，重启后仍在。
3. 用户必须看到双方内容与来源设备/时间，再做选择。
4. 默认不替用户选择；`keepLocal`/`keepServer` 都是一次显式操作。
5. 解决冲突后立即触发一次 push+pull，失败则保留冲突记录。

### 5.2 解决方式

| 选择 | 引擎行为 |
|---|---|
| `keepServer` | 用 `serverPayload` 覆盖本地实体；若是墓碑则软删除本地；删除冲突记录 |
| `keepLocal` | 用 `serverRevision` 作为新 `baseRevision` 重新 push 本地 payload；若服务端已删，创建**新 entityId 副本**（create base=0），旧 ID 保持墓碑 |
| `manual` | 用调用方提供的合并 payload，按 `keepLocal` 的规则提交 |

`manual` 的 payload 必须通过实体校验；不合法时拒绝并保留冲突。

### 5.3 不自动合并的原因

字段级自动合并需要知道“哪个字段被谁改”，而现有模型只有整实体 revision。
在没有字段级基线的情况下自动合并会静默丢失数据；V2 宁可让用户点一次。

---

## 6. 服务端架构（2 核 2 GB）

### 6.1 选型

- **PocketBase**：内置 users 认证、SQLite、迁移、备份、Admin UI。
- 自定义同步路由：`pb_hooks`（JS）或嵌入 Go 的 PocketBase 二选一；
  **行为必须满足 API_CONTRACT**。推荐先用 JS hooks（无需编译、部署简单），
  若事务/性能不足再换 Go 嵌入。
- 反向代理：Caddy（自动 HTTPS）或 Nginx + certbot。
- 进程管理：systemd；SQLite 单文件 + WAL。
- 资源：PocketBase 常驻约 30–80 MB；2 GB 足够。限制并发与请求体，避免
  zip bomb/大 payload 拖垮内存。

### 6.2 请求处理伪代码

```
onPush(req):
  user = requireAuth(req)
  body = validateEnvelope(req)
  assert body.ownerId == null || body.ownerId == user.id
  db.transaction:
    for op in body.ops:
      result = handleOp(user, body.deviceId, op)
      results.append(result)
  return 200 {results}
```

`handleOp` 内：

1. 查 `planner_ops(owner, opId)` → 幂等/冲突；
2. 校验 op 与 payload；
3. 按 create/update/delete 查实体、比 `baseRevision`；
4. 校验关系与 note 唯一；
5. 写入实体、分配 `serverSeq`、写 op 日志；
6. 级联（project/span）；
7. 返回 result。

### 6.3 数据一致性

- 单 writer（SQLite）下，事务串行化；`MAX(serverSeq)+1` 配唯一索引安全。
- 所有查询强制 `owner`；禁止用客户端传入的 owner 直接查询。
- 唯一索引是最后防线：note date、`(owner, type, entityId)`、`(owner, opId)`、
  `(owner, serverSeq)`。
- 定期 `PRAGMA integrity_check` + 备份校验。

### 6.4 部署拓扑

```
Internet
  │ 443
Caddy (TLS, HSTS, body limit, rate limit)
  │ 127.0.0.1:8090
PocketBase (systemd, 非 root, 数据目录 /var/lib/jihatai)
  └─ pb_data/data.db (SQLite WAL)
备份：每日 03:00 本地 + 每周异机/对象存储；保留 7 日 + 4 周
监控：/api/planner/health、磁盘、5xx、push/pull 延迟、op 失败率
```

- 服务器时间用 NTP；`serverTime` 只用于展示，不参与排序。
- 防火墙只开 22/80/443；PocketBase 不直接暴露公网。
- 升级前手动备份 + 演练恢复；迁移脚本只向前。

---

## 7. 关键失败路径

| 失败 | 本地状态 | 用户看到 | 恢复 |
|---|---|---|---|
| push 网络中断 | outbox 保留 | 离线/重试中 | 退避重试同 opId |
| push 响应丢失 | outbox 保留 | 可能重复发送 | 服务端幂等返回 duplicate |
| 单条 conflict | 冲突表 + outbox 保留 | “N 条冲突” | 用户解决后重试 |
| 单条 rejected | op failed | 可读原因 | 修复数据/放弃该 op |
| pull 页应用失败 | 该页回滚，cursor 不变 | 同步失败 | 重放同页 |
| 数据库损坏 | 停止打开，不重建 | 启动失败页 | 从备份恢复 |
| 备份恢复 | 数据被替换 | 需重新对账 | `needs_reconcile` + 全量 pull |
| token 过期 | 未登录，outbox 保留 | 请重新登录 | 登录后继续 |
| 服务器维护 | outbox 保留 | 维护中 | 503 退避 |

**任何情况下都不得**：删除本地库、清空 outbox、用空云端覆盖本地、把冲突
自动标记为已解决。

---

## 8. V1 → V2 迁移

1. 本地库 `user_version 1 → 2`：加 `server_revision` 列 + 三张同步表（只加不减）。
2. 既有实体保持 ID/内容/`revision` 不变；`server_revision=0`。
3. 首次登录：走绑定流程（ACCOUNT_BINDING），云端为空才允许上传。
4. 已绑定账号升级：`server_revision` 从 0 开始会与云端冲突；因此升级后首次同步
   必须做 **snapshot pull 对账**：按 entityId 匹配，采用服务端 revision，
   本地未上传的差异进入 outbox，然后 push。禁止直接 create 全部。
5. 备份 JSON 继续兼容；恢复后进入 `needs_reconcile`。
6. UI：顶栏云图标从“后续版本”占位替换为真实状态；现有月历/项目/任务交互不改。

---

## 9. 可观测性

- 客户端：`SyncStatus`（phase、pending、conflicts、lastError、lastSyncedAt）；
  本地日志只记录 opId/实体类型/耗时/错误码，**不记录账号密码、token、备注正文**。
- 服务端：结构化日志 `requestId, ownerHash, deviceId, opCount, applied, conflict,
  rejected, ms`；不记录 payload 正文。
- 指标：push/pull QPS、p95 延迟、5xx、冲突率、op 重试次数、SQLite 大小、磁盘余量。
- 告警：5xx > 1%、磁盘 < 20%、健康检查失败 2 分钟、备份失败。

---

## 10. 决策记录（ADR 摘要）

| 决策 | 选择 | 理由 |
|---|---|---|
| 云端存储 | PocketBase + SQLite | 2C2G 足够、内置认证、迁移/备份成熟 |
| 同步粒度 | 实体级 revision + 全局 cursor | 简单、可测；字段级合并留待 V3 |
| 本地隔离 | 每账号一个 SQLite 工作区 | 避免漏加 owner 条件导致跨账号泄露 |
| 删除 | 永久墓碑 | 离线设备不复活；数据量小可接受 |
| 冲突 | 不自动合并 | 现有模型无字段级基线，自动合并会丢数据 |
| 首次绑定 | 云端空才允许上传；否则显式选择 | 防止覆盖/混账号 |
| 认证 | PocketBase 邮箱+密码 | 需求“普通账号密码”；避免自建密码体系 |
| 客户端时钟 | 不用于排序 | 多设备时钟不可信；服务端 cursor 权威 |
