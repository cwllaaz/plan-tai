# 计划台 V2.0 · 同步 API 协议（API_CONTRACT）

> 状态：**已冻结（2026-11-15）**。`protocolVersion=1`，载荷 `schemaVersion=1`。
> 实体字段见 [DATA_CONTRACT](DATA_CONTRACT.md)；客户端签名见 [CLIENT_INTERFACE](CLIENT_INTERFACE.md)。
> 服务端实现由 月历模块 负责；三端（Windows / Ubuntu / Android / Web）必须使用同一套路径与语义。

## 1. 总则

| 项 | 约定 |
|---|---|
| Base URL | `https://<host>`；开发可 `http://localhost:8090` |
| API 前缀 | `/api/planner`（PocketBase 自定义路由） |
| 认证 | PocketBase 内置 `users` 集合的 Bearer token |
| 编码 | 请求/响应 `application/json; charset=utf-8` |
| 时间 | 所有时刻 UTC、`Z`、6 位小数（见 DATA_CONTRACT §1.2） |
| 版本 | 每个请求都带 `protocolVersion` 与 `schemaVersion` |
| 幂等 | push 以 `opId` 为幂等键；重试必须复用 |
| 排序 | 只信 `serverCursor`/`serverRevision`，不信客户端时钟 |
| 大小 | 单请求 ≤ 1 MiB；单 op payload ≤ 256 KiB；单批 ≤ 100 ops |
| 限流 | 每用户 push 60 次/分、pull 120 次/分；认证 10 次/分/IP |
| 错误 | 统一 JSON `{code,message,retryable,requestId}`；不返回堆栈 |

### 1.1 通用请求头

```http
Authorization: Bearer <pocketbase-token>
Content-Type: application/json
X-Device-Id: 0192f0a0-0000-7000-8000-00000000000a
X-Client-Version: 2.0.0
```

`X-Device-Id` 只用于日志；真正的 `deviceId` 在 JSON body 中，服务端以 body 为准。

### 1.2 通用错误响应

```json
{
  "code": "AUTH_REQUIRED",
  "message": "请先登录",
  "retryable": false,
  "requestId": "req_01j9..."
}
```

| HTTP | code | 含义 |
|---|---|---|
| 400 | `INVALID_JSON` | body 不是合法 JSON |
| 400 | `INVALID_ENVELOPE` | 缺字段/类型错/未知字段（严格模式） |
| 400 | `UNSUPPORTED_PROTOCOL` | `protocolVersion` 不支持 |
| 400 | `SCHEMA_TOO_NEW` | `schemaVersion` 高于服务端支持 |
| 400 | `TOO_MANY_OPS` | 单批超过 100 |
| 400 | `PAYLOAD_TOO_LARGE` | 单 op 或请求过大 |
| 400 | `INVALID_ENTITY_TYPE` / `INVALID_OP_TYPE` | 枚举非法 |
| 400 | `INVALID_BASE_REVISION` | `baseRevision` 负数，或 create 时非 0 |
| 401 | `AUTH_REQUIRED` | 无 token |
| 401 | `TOKEN_EXPIRED` | token 过期，客户端应 refresh 或重新登录 |
| 403 | `OWNER_MISMATCH` | body 中 ownerId 与 token 用户不一致 |
| 403 | `ACCOUNT_DISABLED` | 账号被禁用 |
| 404 | `NOT_FOUND` | 路由不存在 |
| 409 | `CURSOR_INVALID` | 游标格式非法/超出服务端序号 |
| 409 | `RESET_REQUIRED` | 游标不可用，必须重新快照 |
| 413 | `REQUEST_TOO_LARGE` | 超过反向代理/服务端上限 |
| 429 | `RATE_LIMITED` | 带 `Retry-After` 秒数 |
| 500 | `INTERNAL` | 未预期错误；可重试 |
| 503 | `MAINTENANCE` | 维护中；带 `Retry-After` |

**业务冲突不用 4xx**：push 中单条 op 的冲突/拒绝放在 200 响应的 `results[]` 中。
只有整个请求无法处理时才用 4xx/5xx。

---

## 2. 健康检查与握手

### `GET /api/planner/health`（公开）

响应 `200`：

```json
{
  "status": "ok",
  "serverVersion": "pocketbase-0.23.12",
  "protocolVersion": 1,
  "minSchemaVersion": 1,
  "maxSchemaVersion": 1,
  "serverTime": "2026-11-15T06:00:00.000000Z",
  "features": ["sync.push", "sync.pull"],
  "limits": { "maxOpsPerPush": 100, "maxPullLimit": 500 }
}
```

客户端 `connectServer()` 必须校验：

1. `status == "ok"`；
2. `protocolVersion == 1`；
3. `minSchemaVersion <= 1 <= maxSchemaVersion`；
4. `features` 同时包含 `sync.push` 与 `sync.pull`；
5. 正式环境 URL scheme 为 `https`（localhost 例外）。

不满足时抛 `CloudException(protocol)`，不得继续登录。

---

## 3. 认证（PocketBase 原生）

### 3.1 登录

```http
POST /api/collections/users/auth-with-password
Content-Type: application/json

{ "identity": "user@example.com", "password": "••••••••" }
```

成功 `200`：

```json
{
  "token": "<jwt>",
  "record": {
    "id": "usr_01j9owner0000000000000000",
    "email": "user@example.com",
    "name": "小明",
    "verified": true
  }
}
```

失败 `400`/`401`：`{ "code": "AUTH_FAILED", "message": "账号或密码不正确" }`。
**不要**区分“用户不存在”和“密码错误”，避免账号枚举。

### 3.2 恢复会话

```http
POST /api/collections/users/auth-refresh
Authorization: Bearer <token>
```

成功返回新的 `token` 与 `record`。401 时客户端清除本地 token，进入未登录状态。

### 3.3 退出登录

PocketBase token 无状态；客户端删除本地 token 即可。若服务端增加了会话表，
可调用 `POST /api/planner/auth/logout` 撤销当前设备 token；V1 不要求。

### 3.4 密码重置

```http
POST /api/collections/users/request-password-reset
{ "email": "user@example.com" }
```

成功恒返回 `204`（不泄露邮箱是否存在）。重置链接由 PocketBase 邮件模板发送。

### 3.5 账号与 ownerId

- 账号身份用**邮箱**；`record.id` 即 `ownerId`。
- 客户端不得把邮箱当 ownerId；所有隔离以 `record.id` 为准。
- 服务端所有查询必须带 `owner = @request.auth.id`，不得信任 body 里的 `ownerId`。

---

## 4. Push：`POST /api/planner/sync/push`

### 4.1 请求

```json
{
  "protocolVersion": 1,
  "schemaVersion": 1,
  "deviceId": "0192f0a0-0000-7000-8000-00000000000a",
  "clientVersion": "2.0.0",
  "ownerId": "usr_01j9owner0000000000000000",
  "sentAt": "2026-11-15T06:00:00.000000Z",
  "ops": [
    {
      "opId": "0192f0b0-0000-7000-8000-000000000001",
      "entityType": "task",
      "entityId": "0192f0a2-0000-7000-8000-000000000001",
      "opType": "create",
      "baseRevision": 0,
      "clientRevision": 1,
      "clientUpdatedAt": "2026-11-15T05:02:00.000000Z",
      "payload": {
        "createdAt": "2026-11-15T05:02:00.000000Z",
        "projectId": "0192f0a1-0000-7000-8000-000000000001",
        "spanId": null,
        "title": "写同步协议",
        "notes": "",
        "scheduledDate": "2026-11-16",
        "timeSlot": { "startMinute": 540, "durationMinutes": 90 },
        "priority": "high",
        "status": "todo",
        "completedAt": null,
        "sortOrder": 0
      }
    }
  ]
}
```

字段约束：

| 字段 | 必填 | 说明 |
|---|---|---|
| `protocolVersion` | 是 | 必须为 1 |
| `schemaVersion` | 是 | 必须为 1；高于服务端 → `SCHEMA_TOO_NEW` |
| `deviceId` | 是 | UUIDv7；本安装稳定 |
| `clientVersion` | 否 | 诊断 |
| `ownerId` | 否 | 若提供必须等于 token 用户，否则 403 |
| `sentAt` | 否 | 客户端时钟，仅诊断 |
| `ops` | 是 | 1–100 条，按依赖顺序排列 |

每条 op：

| 字段 | 必填 | 约束 |
|---|---|---|
| `opId` | 是 | UUIDv7；同一操作重试复用 |
| `entityType` | 是 | `project`/`span`/`task`/`note` |
| `entityId` | 是 | UUIDv7 |
| `opType` | 是 | `create`/`update`/`delete` |
| `baseRevision` | 是 | create=0；update/delete ≥1 |
| `clientRevision` | 否 | 诊断 |
| `clientUpdatedAt` | 否 | 诊断；不参与排序 |
| `payload` | create/update 必填 | 见 DATA_CONTRACT §2；delete 省略或 null |

**顺序**：同一批内服务端按数组顺序处理；引用父实体必须排在前面。
客户端批量上传既有数据时固定按 `project → span → task → note` 分组，每组内按
`createdAt` 升序。

### 4.2 成功响应（200）

```json
{
  "protocolVersion": 1,
  "schemaVersion": 1,
  "ownerId": "usr_01j9owner0000000000000000",
  "serverTime": "2026-11-15T06:00:01.000000Z",
  "results": [
    {
      "opId": "0192f0b0-0000-7000-8000-000000000001",
      "entityType": "task",
      "entityId": "0192f0a2-0000-7000-8000-000000000001",
      "status": "applied",
      "noOp": false,
      "serverRevision": 1,
      "serverCursor": "c1_0000000000000001",
      "appliedAt": "2026-11-15T06:00:01.000000Z"
    }
  ]
}
```

`results` 与请求 `ops` **一一对应、顺序相同**。单条状态：

| status | 含义 | 额外字段 |
|---|---|---|
| `applied` | 已写入（或幂等 noOp） | `serverRevision`,`serverCursor`,`noOp` |
| `duplicate` | 同 opId 已处理过，返回原结果 | `serverRevision`,`serverCursor`,`duplicateOf` |
| `conflict` | 版本/唯一性/引用冲突 | `serverRevision`,`conflict` |
| `rejected` | 数据非法，未写入 | `error{code,message,retryable}` |

### 4.3 冲突响应片段

```json
{
  "opId": "0192f0b0-0000-7000-8000-000000000002",
  "entityType": "task",
  "entityId": "0192f0a2-0000-7000-8000-000000000001",
  "status": "conflict",
  "serverRevision": 2,
  "serverCursor": "c1_0000000000000002",
  "conflict": {
    "kind": "UPDATE_UPDATE",
    "serverRevision": 2,
    "serverDeleted": false,
    "serverPayload": {
      "createdAt": "2026-11-15T05:02:00.000000Z",
      "projectId": "0192f0a1-0000-7000-8000-000000000001",
      "spanId": null,
      "title": "写同步协议（设备 A）",
      "notes": "",
      "scheduledDate": "2026-11-16",
      "timeSlot": { "startMinute": 540, "durationMinutes": 90 },
      "priority": "high",
      "status": "todo",
      "completedAt": null,
      "sortOrder": 0
    },
    "serverUpdatedAt": "2026-11-15T06:01:00.000000Z",
    "serverUpdatedByDevice": "0192f0a0-0000-7000-8000-00000000000a",
    "serverCursor": "c1_0000000000000002"
  }
}
```

### 4.4 处理语义（服务端必须逐条实现）

1. **事务**：整批在一个 SQLite 事务中处理；单条 conflict/rejected 不导致整批回滚，
   已 applied 的保留。数据库级失败 → 整批回滚 + 500。
2. **幂等**：先查 `planner_ops(owner, opId)`：
   - 命中且 `requestHash` 相同 → 返回存下的原结果，`status=duplicate`；
   - 命中但 hash 不同 → 该 op `rejected` + `OP_ID_REUSED`，不写库。
3. **create**：
   - 无记录 → 插入，`serverRevision=1`，分配新 `serverCursor`；
   - 有 live 记录 → `conflict CREATE_EXISTS`，返回服务端版本；
   - 有墓碑 → `rejected ENTITY_DELETED`（禁止复活）。
4. **update**：
   - 无记录 → `rejected ENTITY_NOT_FOUND`；
   - 墓碑 → `conflict UPDATE_DELETE`；
   - `baseRevision != current` → `conflict UPDATE_UPDATE`；
   - 相等 → 校验关系/字段，写入，`serverRevision+1`，新 cursor；
   - 若规范化 payload 与当前完全相同 → `applied noOp=true`，不新增 cursor。
5. **delete**：
   - 无记录 → `applied noOp=true`（删除不存在的对象视为已达成）；
   - 已墓碑 → `applied noOp=true`；
   - live 且 base 不匹配 → `conflict DELETE_UPDATE`；
   - 匹配 → 墓碑，`serverRevision+1`，新 cursor；按 §3.2 级联/解绑。
6. **引用校验**：span/task 的父实体必须在同事务内可见且 live；否则
   `rejected MISSING_REFERENCE`。同批前面的 create 必须已提交到事务可见状态。
7. **note 唯一**：create/update 后若同 owner 同 date 有另一条 live note →
   `conflict NOTE_DATE_TAKEN`，不写入。
8. **级联**：删除 project 时对子实体逐条生成墓碑/解绑与 cursor；
   删除 span 时把 task.spanId 置 null；这些额外变更**不**出现在 `results` 中，
   客户端 push 后必须 pull 才能拿到。
9. **不推进 pull 游标**：push 响应里的 cursor 只标识本次写入，客户端不得用它
   覆盖本地同步游标；必须再 pull（见 §5.4）。
10. **审计**：`planner_ops` 保存 opId、requestHash、status、resultJson、
    serverRevision、serverCursor、receivedAt、deviceId。保留 ≥ 180 天；
    早于 180 天可清理，清理后重放旧 op 可能被当新操作，客户端必须在此窗口内重试。

### 4.5 级联示例

删除 project 的响应只包含 project 的 `applied`；同事务内：

```
project  tombstone  rev+1  cursor c1_...10
span     tombstone  rev+1  cursor c1_...11
task     tombstone  rev+1  cursor c1_...12
task(span 解绑) update rev+1 cursor c1_...13
```

客户端随后 `pull(cursor=旧游标)` 拿到 4 条变更。

---

## 5. Pull：`POST /api/planner/sync/pull`

### 5.1 增量请求

```json
{
  "protocolVersion": 1,
  "schemaVersion": 1,
  "deviceId": "0192f0a0-0000-7000-8000-00000000000a",
  "mode": "incremental",
  "cursor": "c1_0000000000000009",
  "limit": 200
}
```

### 5.2 快照（首次/修复）请求

```json
{
  "protocolVersion": 1,
  "schemaVersion": 1,
  "deviceId": "0192f0a0-0000-7000-8000-00000000000a",
  "mode": "snapshot",
  "cursor": "c1_0000000000000000",
  "snapshotSeq": 42,
  "limit": 200
}
```

- `mode`：`incremental`（默认）或 `snapshot`。
- `cursor`：增量起点；snapshot 时作为分页位置（首次可为 `null`/`c1_0`）。
- `snapshotSeq`：仅 snapshot 后续页回传；首次省略，由服务端确定。
- `limit`：1–500，默认 200。

### 5.3 响应（200）

```json
{
  "protocolVersion": 1,
  "schemaVersion": 1,
  "ownerId": "usr_01j9owner0000000000000000",
  "serverTime": "2026-11-15T06:10:00.000000Z",
  "mode": "incremental",
  "snapshot": false,
  "snapshotSeq": null,
  "changes": [
    {
      "entityType": "task",
      "entityId": "0192f0a2-0000-7000-8000-000000000001",
      "schemaVersion": 1,
      "ownerId": "usr_01j9owner0000000000000000",
      "serverRevision": 2,
      "serverCursor": "c1_0000000000000010",
      "deleted": false,
      "deletedAt": null,
      "payload": {
        "createdAt": "2026-11-15T05:02:00.000000Z",
        "projectId": "0192f0a1-0000-7000-8000-000000000001",
        "spanId": null,
        "title": "写同步协议（设备 A）",
        "notes": "",
        "scheduledDate": "2026-11-16",
        "timeSlot": { "startMinute": 540, "durationMinutes": 90 },
        "priority": "high",
        "status": "todo",
        "completedAt": null,
        "sortOrder": 0
      },
      "serverUpdatedAt": "2026-11-15T06:01:00.000000Z",
      "updatedByDevice": "0192f0a0-0000-7000-8000-00000000000a",
      "lastOpId": "0192f0b0-0000-7000-8000-000000000002"
    }
  ],
  "nextCursor": "c1_0000000000000010",
  "hasMore": false,
  "resetRequired": false
}
```

### 5.4 语义

1. **增量**：返回 `serverSeq > cursorSeq` 的实体**最新状态**，按 cursor 升序；
   同一实体多次变更只返回一次（合并到最新）。`hasMore=true` 时客户端用
   `nextCursor` 继续，直到 false 才认为本轮完成。
2. **快照**：`mode=snapshot` 返回 `serverSeq <= snapshotSeq` 的全部实体
   （含墓碑），按 cursor 升序分页。首次响应给 `snapshotSeq`；后续页回传它。
   快照完成后客户端把同步 cursor 设为 `snapshotSeq`，再增量拉取之后的变化。
3. **删除**：`deleted=true`、`deletedAt` 非空、`payload=null`。客户端必须把本地
   实体软删除；若本地不存在该实体，直接忽略墓碑即可。
4. **游标**：`nextCursor` 是本次最后一条变更的 cursor；无变更时回显请求 cursor
   （首次为 `c1_0`）。客户端**事务提交成功后再持久化** `nextCursor`；崩溃后
   重放同一页是安全的（按 entityId + serverRevision 幂等 upsert）。
5. **快照完成**：`hasMore=false` 且 `mode=snapshot` 时，客户端把 `cursor` 设为
   `snapshotSeq`（不是 `nextCursor`），避免漏掉快照窗口外的后续变更。
6. **pull 不产生写操作**：不得因为拉取而生成 outbox；不得调用会写 `change_log`
   的仓储方法。
7. **顺序**：服务端按 cursor 升序返回；由于服务端保证父实体先创建、级联后置，
   客户端按返回顺序应用即可。若遇到父实体缺失（数据损坏），先暂存该变更并
   在下一轮重试，不得写入孤儿。
8. **resetRequired**：服务端无法保证游标连续性（例如管理员恢复/重建 owner 数据）
   时返回 `resetRequired=true`（可配 409 `RESET_REQUIRED`）。客户端必须：
   备份本地库 → 停止自动同步 → 进入 `needsAttention` → 用户确认后做 snapshot
   全量拉取 + 本地差异核对，禁止直接清空本地库。

### 5.5 分页边界

- 单页最多 500 条；服务端不得返回超过 `limit`。
- `hasMore` 必须准确；客户端不得用 `changes.length == limit` 猜测。
- 空页 + `hasMore=false` 合法；`nextCursor` 必须等于请求 cursor 或更大。
- `snapshotSeq` 只在 snapshot 模式出现；增量模式必须为 `null`。

---

## 6. 版本、限流与重试

### 6.1 客户端重试

| 情况 | 策略 |
|---|---|
| 网络错误/超时/5xx/429 | 指数退避 1s→2s→4s→…→5min，加 0–30% 抖动；保留 opId |
| 401 | 尝试一次 `auth-refresh`；失败则要求重新登录，不重试 push |
| 409 `CURSOR_INVALID`/`RESET_REQUIRED` | 停止增量，进入修复流程 |
| 单条 `rejected OP_ID_REUSED` | 代码 bug；该 op 标记失败并告警，不自动改 opId（同批其他 op 继续） |
| 400 `SCHEMA_TOO_NEW` | 提示升级客户端；停止同步 |
| 单条 `rejected` | 该 op 标记 failed，其余继续；UI 显示原因 |
| 单条 `conflict` | 写入本地冲突表，继续处理其他 op；同步结果 `conflict` |

### 6.2 服务端限流

- 按 owner 分桶；超限返回 429 + `Retry-After`。
- 登录失败按 IP + 账号双维度冷却，防暴力破解。
- 反向代理（Caddy/Nginx）限制 body 1 MiB、连接数、超时 30s。

### 6.3 协议兼容

- 服务端同时支持 `schemaVersion` 1；未来 2 时保留 1 的读写至少一个小版本。
- 客户端遇到未知可选字段必须忽略；遇到未知必填语义/更高 `schemaVersion`
  必须停止同步并提示升级，不得猜测写入。
- `protocolVersion` 不匹配直接拒绝，不做隐式降级。

---

## 7. 服务端存储模型（PocketBase）

> 月历模块 必须在 `server/` 内实现；以下为**行为契约**，不是强制文件布局。

### 7.1 集合

#### `users`（PocketBase 内置）

- 字段：`email`、`password`、`name`（显示名）、`verified`。
- 账号身份 = 邮箱；`record.id` = `ownerId`。
- 注册默认关闭（仅管理员邀请/创建），避免公开注册滥用 2C2G 服务器。

#### `planner_entities`

| 字段 | 类型 | 说明 |
|---|---|---|
| `owner` | relation users，必填，cascadeDelete | 隔离键 |
| `entityType` | select | project/span/task/note |
| `entityId` | text | UUIDv7 |
| `schemaVersion` | number | 写入时的载荷版本 |
| `payload` | json | 实体载荷；墓碑为 null |
| `serverRevision` | number | 每实体版本 |
| `serverSeq` | number | 每 owner 全局序号 |
| `deleted` | bool | 墓碑 |
| `deletedAt` | date | 墓碑时刻 |
| `lastOpId` | text | 最后 op |
| `updatedByDevice` | text | 设备 ID |
| `created`/`updated` | PocketBase 自动 | 服务端时刻 |

索引（必须）：

```sql
CREATE UNIQUE INDEX ux_entities_owner_type_id
  ON planner_entities(owner, entity_type, entity_id);
CREATE UNIQUE INDEX ux_entities_owner_seq
  ON planner_entities(owner, server_seq);
CREATE INDEX ix_entities_owner_seq
  ON planner_entities(owner, server_seq);
CREATE INDEX ix_entities_owner_type_deleted
  ON planner_entities(owner, entity_type, deleted);
-- 若 SQLite JSON1 可用：
CREATE UNIQUE INDEX ux_note_date_live
  ON planner_entities(owner, json_extract(payload, '$.date'))
  WHERE entity_type = 'note' AND deleted = 0;
```

若 partial index 不可用，必须在 push 事务内用查询强制 note 唯一。

#### `planner_ops`

| 字段 | 类型 | 说明 |
|---|---|---|
| `owner` | relation users | |
| `opId` | text | 幂等键 |
| `requestHash` | text | canonical SHA-256 |
| `status` | text | applied/duplicate/conflict/rejected |
| `resultJson` | json | 原响应片段 |
| `serverRevision` | number | |
| `serverSeq` | number | |
| `deviceId` | text | |
| `receivedAt` | date | |

唯一索引 `(owner, opId)`；索引 `receivedAt` 供 TTL 清理。

#### `planner_devices`

| 字段 | 类型 | 说明 |
|---|---|---|
| `owner` | relation users | |
| `deviceId` | text | UUIDv7 |
| `platform` | text | windows/linux/android/web |
| `appVersion` | text | |
| `lastSeenAt` | date | |
| `lastCursor` | text | 可选，诊断 |

唯一索引 `(owner, deviceId)`。设备表不参与同步，不阻塞登录。

### 7.2 序号分配

- `serverSeq` 必须每 owner 单调递增，且在事务内分配。
- 推荐 `SELECT COALESCE(MAX(server_seq),0)+1 ... WHERE owner=?`（配唯一索引）；
  也可用 `planner_counters` 表。**不得**用客户端时间或随机数。
- 一次 push 中多条写入按处理顺序分配连续/递增序号；级联写入紧随原操作。

### 7.3 事务边界

- 整个 push 批处理在一个事务内；级联与 op 日志同事务。
- 任一致命数据库错误 → 全部回滚；单条业务冲突/拒绝不回滚已成功项。
- pull 只读；不得在 pull 中写 cursor/日志（除访问日志）。

---

## 8. 必测场景（协议层）

完整载荷与期望响应见 [TEST_CASES](TEST_CASES.md) 与 `fixtures/scenarios.json`。

1. 新增任务 → `applied`，`serverRevision=1`。
2. 修改任务（base=1）→ `applied`，`serverRevision=2`。
3. 删除任务（base=2）→ `applied`，墓碑。
4. 重复发送同一 op → `duplicate`，服务端版本/游标不变。
5. 两设备改同一任务：A 先成功；B base=1 → `UPDATE_UPDATE`，返回 A 的 payload。
6. 修改已删除任务：`UPDATE_DELETE`，不得复活。
7. 首次绑定既有本地数据：按 project→span→task→note 上传；快照 pull 后本地与服务端一致。
8. 断网恢复：同 opId 重发 → `duplicate`/`applied`，不重复建实体；随后 pull 到最新。

服务端测试必须覆盖：owner 隔离、note 唯一、级联、分页边界、游标非法、
payload 超限、同 opId 不同内容、删除幂等、create 已存在。

---

## 9. 路径总表

| 方法 | 路径 | 认证 | 用途 |
|---|---|---|---|
| GET | `/api/planner/health` | 否 | 握手/能力 |
| POST | `/api/collections/users/auth-with-password` | 否 | 登录 |
| POST | `/api/collections/users/auth-refresh` | Bearer | 恢复会话 |
| POST | `/api/collections/users/request-password-reset` | 否 | 重置密码 |
| POST | `/api/planner/sync/push` | Bearer | 上传操作 |
| POST | `/api/planner/sync/pull` | Bearer | 增量/快照拉取 |

客户端不得直连 `planner_entities`/`planner_ops` 集合的 CRUD API；
这些集合的 API Rules 必须是“拒绝所有客户端”，只允许服务端 hook 访问。
