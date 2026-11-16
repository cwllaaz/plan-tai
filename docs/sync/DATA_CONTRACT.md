# 计划台 V2.0 · 同步数据契约（DATA_CONTRACT）

> 状态：**已冻结（2026-11-15）**。协议版本 `1`，载荷 schema `1`，本地数据库结构 `2`。
> 本文件是实体、序列化、时区、删除、版本与冲突的**唯一权威说明**。
> HTTP 细节见 [API_CONTRACT](API_CONTRACT.md)，客户端签名见 [CLIENT_INTERFACE](CLIENT_INTERFACE.md)。

## 0. 版本与边界

| 版本 | 值 | 说明 |
|---|---|---|
| `protocolVersion` | `1` | 请求/响应信封与错误码版本 |
| `schemaVersion` | `1` | 实体 `payload` 的字段结构版本 |
| 本地 `PRAGMA user_version` | `2` | 在 V1 的 1 上做**只加不减**迁移 |
| 备份 JSON `schemaVersion` | 跟随本地库版本 | V1 备份（1）必须仍可恢复到 V2 库 |

三条铁律：

1. **本地优先**：所有用户操作先写本地 SQLite；网络失败不得阻塞编辑。
2. **服务端版本优先于客户端时钟**：变更顺序只看 `serverCursor`/`serverRevision`；
   `clientUpdatedAt` 仅用于诊断与冲突展示，绝不参与排序或“最后写入者赢”。
3. **禁止整库覆盖**：任何同步都不得用云端快照直接替换本地数据库。必须走
   操作队列 + 逐实体合并 + 冲突处理（见 ARCHITECTURE §5）。

---

## 1. 基础编码规则

### 1.1 日历日（无时区）

| 项 | 规则 |
|---|---|
| 字段 | `scheduledDate`、`startDate`、`endDate`、`date` |
| 编码 | `YYYY-MM-DD`，定长 10 字符，**不带时间、不带时区、不带 Z** |
| 例 | `"2026-11-16"` |
| 语义 | 用户日历上的“那一天”。在哪个时区看都是同一天 |
| 禁止 | 用 `DateTime`、Unix 毫秒、`2026-11-16T00:00:00Z` 表示日历日 |

### 1.2 时刻（UTC）

| 项 | 规则 |
|---|---|
| 字段 | `clientUpdatedAt`、`serverUpdatedAt`、`createdAt`、`completedAt`、`deletedAt`、`authenticatedAt` |
| 编码 | ISO 8601 UTC，**必须带 `Z`**；规范输出固定 6 位小数：`YYYY-MM-DDTHH:MM:SS.ffffffZ` |
| 例 | `"2026-11-15T06:00:00.000000Z"` |
| 接受 | 解析时可接受 3 位/6 位小数，但服务端存储与比较前统一补到 6 位 |
| 禁止 | 本地时区字符串、无 `Z` 的字符串、把时刻当“哪一天”用 |

时刻只用于审计、完成时间、删除标记、同步排序参考。**业务日期一律用 1.1**。

### 1.3 当天的墙钟时间

任务的一天内时间用两个整数表达，不用时间戳：

```json
"timeSlot": { "startMinute": 540, "durationMinutes": 90 }
```

- `startMinute`：0–1439（0 = 00:00，540 = 09:00）；
- `durationMinutes`：1–1440，且 `startMinute + durationMinutes <= 1440`；
- `timeSlot: null` 表示“当天要做，但不排具体时刻”；
- **不允许跨午夜**；跨天用 `span`。

### 1.4 枚举、颜色、数字、字符串

| 类型 | 规则 |
|---|---|
| 项目状态 | `active` / `paused` / `archived` |
| 阶段状态 | `planned` / `doing` / `done` / `dropped` |
| 任务状态 | `todo` / `done` |
| 任务优先级 | `low` / `normal` / `high` / `urgent`（线上用名字，不用 0–3 数字） |
| 颜色 | `#RRGGBB` 大写；项目必填，阶段可为 `null`（继承项目色） |
| 整数 | JSON number，不用字符串；`sortOrder`、`startMinute` 等必须为整数 |
| 文本 | UTF-8；长度按 Unicode 码点计，限制见 §3；`null` 仅允许明确标注可空的字段 |
| 数组 | `focusItems` 为字符串数组，最多 3 条，单条 ≤ 60 字符；顺序有意义 |

### 1.5 公共同步字段（服务端维护，不在实体 payload 内）

| 字段 | 类型 | 说明 |
|---|---|---|
| `ownerId` | string | 服务端用户 ID；客户端不得伪造 |
| `serverRevision` | int ≥ 1 | **每个实体独立**的服务端版本，每次成功写入 +1 |
| `serverCursor` | string | 服务端**每个 owner 全局递增**的变更游标，不透明 |
| `schemaVersion` | int | 该记录写入时的载荷 schema 版本 |
| `deleted` | bool | 是否墓碑 |
| `deletedAt` | string? | 服务端删除时刻（UTC） |
| `updatedByDevice` | string | 最后写入的设备 ID |
| `lastOpId` | string? | 最后应用的操作 ID，用于审计 |

客户端实体表仍保留本地 `revision`（乐观并发用）与本地 `updatedAt`；
**不得**把本地 `revision` 当成 `serverRevision`，也不得把 `updatedAt` 当同步游标。

---

## 2. 实体载荷（payload）

实体 `payload` 是**去掉了服务端字段**的完整快照。字段名与现有
`lib/data/entity_codec.dart` 的 JSON 尽量一致，减少映射错误。

### 2.1 project

```json
{
  "createdAt": "2026-11-15T05:00:00.000000Z",
  "name": "产品官网改版",
  "description": "信息架构与视觉重构",
  "color": "#3E63DD",
  "status": "active",
  "sortOrder": 0
}
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `createdAt` | 是 | 首次创建时刻（客户端生成，服务端保留第一个值） |
| `name` | 是 | trim 后 1–80 字符 |
| `description` | 否 | 默认 `""`，≤ 2000 |
| `color` | 是 | `#RRGGBB`；允许色板外的合法颜色（如「未归类」的 `#8B94A3`） |
| `status` | 是 | `active`/`paused`/`archived` |
| `sortOrder` | 否 | 默认 0；升序 |

### 2.2 span（跨天安排 / 阶段）

```json
{
  "createdAt": "2026-11-15T05:01:00.000000Z",
  "projectId": "0192f0a1-0000-7000-8000-000000000001",
  "title": "信息架构评审",
  "startDate": "2026-11-16",
  "endDate": "2026-11-20",
  "status": "doing",
  "description": "",
  "color": null,
  "sortOrder": 0
}
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `projectId` | 是 | 同 owner、未删除的项目 |
| `title` | 是 | 1–120 |
| `startDate` | 是 | `YYYY-MM-DD` |
| `endDate` | 是 | `YYYY-MM-DD`，`>= startDate`；闭区间，16–20 日是 **5 天** |
| `status` | 是 | `planned`/`doing`/`done`/`dropped` |
| `description` | 否 | ≤ 2000 |
| `color` | 否 | `null` = 继承项目色 |
| `sortOrder` | 否 | 默认 0 |
| 跨度 | — | `endDate - startDate + 1 <= 366` |

**边界定义**：`startDate` 与 `endDate` 都包含。不存在“结束日 00:00 开区间”的歧义；
跨天条在月历上的分段由客户端视图负责，服务端只存日历日。

### 2.3 task

```json
{
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
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `projectId` | 否 | `null` = 收件箱；非空时必须存在且同 owner |
| `spanId` | 否 | 非空时 `projectId` 必须非空且等于该 span 的 `projectId` |
| `title` | 是 | 1–200 |
| `notes` | 否 | 默认 `""`，≤ 5000 |
| `scheduledDate` | 否 | `null` = 未排期（收件箱） |
| `timeSlot` | 否 | 非空时 `scheduledDate` 必须非空；不能跨午夜 |
| `priority` | 是 | `low`/`normal`/`high`/`urgent` |
| `status` | 是 | `todo`/`done` |
| `completedAt` | 否 | 仅 `status=done` 时非空；`todo` 必须为 `null` |
| `sortOrder` | 否 | 默认 0 |

**完成 ≠ 删除**：`done` 的任务仍留在当天。`todo → done` 由客户端写
`completedAt`；`done → todo` 必须清空。服务端要校验这两个不变量。

### 2.4 note（每日备注）

```json
{
  "createdAt": "2026-11-15T05:03:00.000000Z",
  "date": "2026-11-15",
  "body": "先完成首页转化路径梳理",
  "focusItems": ["首页转化路径", "视觉稿走查"]
}
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `date` | 是 | `YYYY-MM-DD`；**同一 owner 下未删除记录中唯一** |
| `body` | 否 | 默认 `""`，≤ 10000 |
| `focusItems` | 否 | 最多 3 条，单条 ≤ 60；trim、去空串、顺序保留 |

同一天第二次保存是 **update**，不是新建。两台设备各自为同一天创建 note
会产生两个不同 ID → 服务端返回 `NOTE_DATE_TAKEN` 冲突，必须由用户/引擎合并，
禁止静默丢弃任意一方。

---

## 3. 关系、级联与删除

### 3.1 关系

```
project 1 ── n span
project 1 ── n task        (task.projectId 可空)
span    1 ── n task        (task.spanId 可空)
note    独立，按 date 唯一
```

服务端在**每次写入**时校验：

1. `span.projectId` 指向同 owner、未删除的 project；
2. `task.projectId` 为空或指向同 owner、未删除的 project；
3. `task.spanId` 为空，或指向同 owner、未删除且 `projectId` 与任务一致的 span；
4. `note.date` 在同 owner 未删除记录中唯一；
5. 所有枚举/长度/时间区间约束与本地模型一致。

违反者返回 `rejected` + `VALIDATION_FAILED` / `MISSING_REFERENCE`，**不得写库**。

### 3.2 删除传播（必须与本地语义完全一致）

| 操作 | 服务端行为 | 变更流 |
|---|---|---|
| 删除 project | 同事务软删除该项目、其全部未删除 span、其全部未删除 task；每个实体 revision +1，各自分配 cursor | 原 project 墓碑 + 所有子实体墓碑 |
| 删除 span | 软删除 span；其下未删除 task 的 `spanId` 置 `null`，task revision +1（task 保留） | span 墓碑 + 受影响 task 的 update |
| 删除 task | 软删除 task | task 墓碑 |
| 删除 note | 软删除 note；释放该 date 的唯一约束 | note 墓碑 |

- 删除是**软删除**：`deleted=true` + `deletedAt`；不物理删除。
- 墓碑必须永久保留（V2 数据量小），否则离线设备会“复活”已删数据。
- 删除 project 的级联由服务端在同一事务生成；客户端 pull 到墓碑后**不得再次级联**
  生成本地 outbox（避免回声）。
- V2 **不提供恢复已删除实体**的 API。界面的“撤销删除”目前是新建一条新 ID
  （见 `day_detail_panel.dart`），因此同步层也按“新实体 create”处理。

### 3.3 删除与修改的冲突优先级

- 服务端已删除，客户端 `update` → 冲突 `UPDATE_DELETE`；服务端**绝不**因为
  update 而复活实体。
- 服务端已更新，客户端 `delete` 且 `baseRevision` 落后 → 冲突 `DELETE_UPDATE`；
  用户可选择“仍然删除”（以最新 revision 再发 delete）或“保留服务端版本”。
- 服务端已删除，客户端 `delete` → 幂等成功（`applied` + `noOp=true`），不产生新变更。
- 服务端已删除，客户端 `create` 同 ID → `rejected` + `ENTITY_DELETED`，禁止复活。

---

## 4. 操作、版本与游标

### 4.1 操作（op）

| 字段 | 说明 |
|---|---|
| `opId` | 客户端生成 UUIDv7，全局唯一；**同一操作重试必须复用** |
| `entityType` | `project`/`span`/`task`/`note` |
| `entityId` | 实体 UUIDv7；创建后永不变 |
| `opType` | `create`/`update`/`delete` |
| `baseRevision` | 本次修改基于的服务端版本；create 固定 `0` |
| `clientRevision` | 本地 revision，仅诊断 |
| `clientUpdatedAt` | 本地修改时刻（UTC），仅诊断/冲突展示 |
| `payload` | create/update 必填；delete 省略或 `null` |

### 4.2 版本规则

- `serverRevision` **按实体**从 1 开始，每次成功写入 +1。
- `create`：实体不存在 → 写入 `serverRevision=1`；已存在（含墓碑）→ 冲突/拒绝。
- `update`：`baseRevision == 当前 serverRevision` → 写入，`serverRevision+1`；
  不等 → 冲突，返回服务端当前版本与 payload。
- `delete`：`baseRevision == 当前` → 墓碑；已删除 → 幂等；
  不匹配且仍存活 → 冲突。
- 服务端**不做字段级自动合并**，也不做“最后写入者赢”。
- 若 `baseRevision` 落后但 `payload` 与服务端当前规范化 payload 完全相同，
  可返回 `applied` + `noOp=true`，不产生新版本（幂等优化）。

### 4.3 游标

- `serverCursor` 是**每个 owner 全局递增**的变更序号，用于增量 pull。
- 它是服务端维护的，**不是客户端时间**；客户端不得用 `updatedAt` 代替。
- 客户端按账号工作区持久化 `cursor`；换账号必须换游标。
- 游标不透明，格式示例 `c1_0000000000000012`；客户端不得解析。
- `serverRevision` 用于冲突检测；`serverCursor` 用于增量拉取。二者不可混用。

### 4.4 首次上传与既有数据

- 既有本地实体 `serverRevision` 初始为 `0`；首次上传全部用 `create` + `baseRevision=0`。
- 上传顺序必须是 `project → span → task → note`，否则引用校验失败。
- 只上传**未删除**实体；本地墓碑不需要上传到空云端（从未在云端存在）。
- 若云端非空，**禁止**把本地数据直接 `create` 上去；必须先走绑定确认
  （见 [ACCOUNT_BINDING](ACCOUNT_BINDING.md)）。
- 上传是幂等的：每批操作有稳定 `opId`；失败重试不得换 ID。

---

## 5. 时区与跨天规则

1. 所有“哪一天”用 `YYYY-MM-DD`；跨时区不改写日期。
2. 所有“时刻”用 UTC；客户端展示时再转本地时区。
3. `timeSlot` 是墙钟分钟数，不随设备时区移动。
4. 跨天安排的起止都是日历日闭区间；服务端不存“结束日 23:59:59”。
5. 客户端用本地时区决定“今天”，但“今天”只影响 UI 默认值，**不参与同步顺序**。
6. 设备时钟明显偏差时，同步仍以 `serverCursor` 排序；服务端可在 health 返回
   `serverTime`，客户端仅提示偏差，不改写数据。

---

## 6. 冲突对象

冲突由服务端在 push 响应中返回，客户端持久化到本地 `sync_conflicts`：

```json
{
  "kind": "UPDATE_UPDATE",
  "serverRevision": 4,
  "serverDeleted": false,
  "serverPayload": { "...": "服务端当前完整 payload" },
  "serverUpdatedAt": "2026-11-15T06:05:00.000000Z",
  "serverUpdatedByDevice": "0192f0a0-0000-7000-8000-00000000000a",
  "serverCursor": "c1_0000000000000012"
}
```

| `kind` | 含义 | 推荐处理 |
|---|---|---|
| `UPDATE_UPDATE` | 两设备都基于同一旧版本修改 | 用户选本地/服务端/手动合并 |
| `UPDATE_DELETE` | 本地改，服务端已删 | 保留为**新 ID 副本**，或接受删除 |
| `DELETE_UPDATE` | 本地删，服务端已改 | 仍然删除，或保留服务端 |
| `CREATE_EXISTS` | 本地 create 的 ID 已存在 | 采用服务端，或以 `baseRevision=serverRevision` 覆盖 |
| `NOTE_DATE_TAKEN` | 同一天已有另一条 note | 合并正文/重点，保留一条 |

`MISSING_REFERENCE` 是 **rejected** 而不是冲突：父实体不存在/已删时不得写入孤儿，
客户端应先同步父实体再重试。

`serverPayload` 对墓碑为 `null`；`serverDeleted=true`。冲突记录必须包含
`localPayload`（本地意图）与 `baseRevision`，否则无法做“保留本地”。

---

## 7. 本地数据库 v2 映射

### 7.1 实体表新增列（只加不减）

```sql
ALTER TABLE projects       ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE plan_spans     ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE planner_tasks  ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_notes    ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0;
```

- 既有记录迁移后 `server_revision=0`，表示“尚未在云端确认”。
- 本地 `revision` 继续由仓储维护，供 UI 乐观并发；同步层不得直接改它来“对齐”服务端。
- 拉取远端变更时，同步层在事务内：
  1. 按 `entityId` upsert 实体字段；
  2. 写入 `server_revision`；
  3. 把本地 `revision` 设为 `max(本地 revision, 服务端 revision)` 或 +1，
     保证 UI 下一次 update 不会误判；
  4. 调 `PlannerDatabase.notifyChanged()`；
  5. **不要**写 `change_log` / outbox，避免回声。

### 7.2 新增表

```sql
CREATE TABLE sync_outbox (
  op_id         TEXT PRIMARY KEY,
  entity_type   TEXT NOT NULL CHECK (entity_type IN ('project','span','task','note')),
  entity_id     TEXT NOT NULL,
  operation     TEXT NOT NULL CHECK (operation IN ('create','update','delete')),
  base_revision INTEGER NOT NULL,
  local_revision INTEGER NOT NULL,
  payload       TEXT NOT NULL,           -- 规范化 JSON；delete 为 '{}'
  device_id     TEXT NOT NULL,
  state         TEXT NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending','sending','failed')),
  attempts      INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT,
  last_error    TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX idx_outbox_pending ON sync_outbox(state, next_attempt_at, created_at);
CREATE UNIQUE INDEX ux_outbox_entity_pending
  ON sync_outbox(entity_type, entity_id) WHERE state = 'pending';

CREATE TABLE sync_conflicts (
  id            TEXT PRIMARY KEY,
  entity_type   TEXT NOT NULL,
  entity_id     TEXT NOT NULL,
  kind          TEXT NOT NULL,
  base_revision INTEGER NOT NULL,
  server_revision INTEGER NOT NULL,
  server_deleted INTEGER NOT NULL DEFAULT 0,
  local_payload TEXT,
  server_payload TEXT,
  detected_at   TEXT NOT NULL,
  resolved_at   TEXT
);
CREATE INDEX idx_conflicts_open ON sync_conflicts(resolved_at, detected_at);

CREATE TABLE sync_state (
  id            INTEGER PRIMARY KEY CHECK (id = 1),
  protocol_version INTEGER NOT NULL DEFAULT 1,
  cursor        TEXT,
  last_sync_at  TEXT,
  auto_sync     INTEGER NOT NULL DEFAULT 1,
  last_error    TEXT
);
INSERT OR IGNORE INTO sync_state(id) VALUES (1);
```

### 7.3 outbox 必须遵守的不变量

1. **同事务**：业务写入与 outbox 写入必须同一 `BEGIN IMMEDIATE`；任一步失败整体回滚。
2. **每次用户写入至少一条**：创建/修改/删除/级联删除/阶段解除关联都要入队。
3. **opId 首次发送后不变**：重试复用同一 `opId` 与同一规范化 payload。
4. **在途不可变**：`sending` 期间本地又改同一实体，必须新增一条 pending，
   收到确认后只删除对应 opId，不能把新改动误标为已同步。
5. **合并仅限未发送**：同一实体连续修改可在 `pending` 状态合并为一条（更新 payload、
   `local_revision`、`updated_at`），但不得改变已发送的 opId。
6. **删除优先**：若实体从未上传（`server_revision=0`）就被删除，可以只删 outbox
   中的 create/update，不发 delete；若已上传，则必须发 delete。
7. **恢复备份后**：`change_log` 会出现 `database/full restore`。同步层必须
   停止自动 push、清空/重建 outbox、把工作区标记为 `needs_reconcile`，
   先全量 pull 对齐 `server_revision`，再由用户确认上传本地差异。

### 7.4 设备 ID 与账号绑定不放在数据库里

- 设备 ID：`%APPDATA%\计划台\data\device.json`，安装级唯一；备份/复制数据库
  不得复制它。丢失时重新生成即可。
- 账号绑定：数据库旁路 `*.binding.json`（见 ACCOUNT_BINDING §3）。
  这样把数据库备份到另一台机器不会自动继承账号归属。

### 7.5 备份兼容

- 旧备份 `schemaVersion=1` 仍可恢复；新增列取默认值 0。
- 备份 JSON 不包含 `server_revision`、outbox、cursor、token、deviceId。
- 恢复后首次同步必须走 `needs_reconcile`，禁止直接按旧 outbox 上传。

---

## 8. 规范化 JSON 与哈希

`opId` 去重之外，服务端用 `requestHash` 防止“同 opId 不同内容”：

1. 对 op 的 `{entityType, entityId, opType, baseRevision, payload}` 做 canonical JSON：
   - 对象键按 Unicode 码点升序；
   - 无空格/换行；
   - 数字用最短十进制（整数不带 `.0`）；
   - 字符串 UTF-8、不转义非 ASCII（除必要控制字符）；
   - `null` 明确输出。
2. 对 canonical UTF-8 字节做 SHA-256，十六进制小写。
3. 服务端保存 `requestHash`；同 `opId` 且 hash 相同 → 返回原结果；
   hash 不同 → 该 op `rejected` + `OP_ID_REUSED`（同批其他 op 继续）。
4. 测试夹具提供 `canonicalHash` 期望值，服务端与客户端测试都必须校验。

---

## 9. 变更与兼容流程

1. 本文件、`lib/core/cloud/`、`docs/sync/` 已冻结；任何 Agent 不得自行改字段。
2. 需要新增字段时，提交：场景、字段、默认值、旧数据迁移、测试用例。
3. 只允许**加字段/加枚举值**的向后兼容变更；删除/改名 = 新 `schemaVersion`，
   并提供 V1→V2 迁移与双读期。
4. 服务端必须拒绝 `schemaVersion > maxSchemaVersion` 的写入；
   客户端必须拒绝 `payload` 中未知的必填语义（可忽略未知可选字段）。
5. 所有契约变更先在 `baseline/cloud-sync-v2` 上改，跑通全部测试后广播三个工作区。
