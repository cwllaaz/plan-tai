# 计划台 V2.0 · 首次绑定与账号切换（ACCOUNT_BINDING）

> 状态：**已冻结（2026-11-15）**。
> 目标：任何情况下都不把 A 账号/未归属的本地数据自动上传给 B 账号；任何覆盖前
> 都有可恢复备份；用户必须明确确认数据归属。

## 1. 为什么这是最高风险区

现有用户已经在 `%APPDATA%\计划台\data\app.db` 积累了真实数据（审计时：5 个项目、
7 条任务、2 条 live 跨天安排、1 条每日备注）。首次登录如果直接：

- 把本地库当云端空库上传 → 可能把旧数据灌进别人的账号；
- 用云端快照覆盖本地 → 丢用户本地数据；
- 换账号时复用同一个库 → 跨账号泄露；
- 上传失败后标记为已绑定 → 重试时重复创建/覆盖。

因此绑定流程必须是**独立的、可恢复的、显式确认的状态机**。

## 2. 五个必须区分的场景

| # | 场景 | 本地 | 云端 | 默认动作 | 禁止 |
|---|---|---|---|---|---|
| 1 | 全新安装，云端有数据 | 空 | 有 | 新建账号库 + snapshot 拉取 | 让用户误以为本地空=云端空 |
| 2 | 全新安装，云端为空 | 空 | 空 | 新建账号库，绑定，等待首次写入 | 自动创建示例数据上传 |
| 3 | 本地已有数据，云端为空 | 有 | 空 | 展示数量，用户确认后上传 | 未经确认自动上传 |
| 4 | 本地和云端都有数据 | 有 | 有 | **禁止自动合并**；只能取消/以云端为准（先归档）/保持本地不绑定 | 自动上传、自动覆盖 |
| 5 | 本地数据已绑定其他账号 | 有（绑定 A） | 当前登录 B | 拒绝上传；取消或为 B 新建库 | 把 A 数据传给 B |
| 6 | 同设备切换账号 | A 库 | B 账号 | 打开/新建 B 的独立库；A 库保留 | 复制 A 数据到 B |

> 场景 1/2 的“云端有/无”必须由 `inspectBinding()` 实际查询得出；
> 网络失败时 `cloudRecords=null`，不得当成 0。

## 3. 绑定记录与工作区布局

### 3.1 目录

```
%APPDATA%\计划台\data\
├─ app.db                         # 既有库：local-default
├─ app.db.binding.json            # 既有库的绑定（若已绑定）
├─ device.json                    # 安装级 deviceId
├─ workspaces.json                # 可选：激活工作区
├─ accounts\
│   └─ <ownerId>\
│       ├─ app.db                 # 账号工作区
│       └─ binding.json
└─ backups\
```

### 3.2 `binding.json`（数据库旁路，不进备份）

```json
{
  "bindingVersion": 1,
  "workspaceId": "local-default",
  "ownerId": "usr_01j9owner0000000000000000",
  "serverUrl": "https://planner.example.com",
  "state": "bound",
  "boundAt": "2026-11-15T06:00:00.000000Z",
  "lastVerifiedAt": "2026-11-15T06:10:00.000000Z",
  "lastServerRevision": 42,
  "note": "首次绑定；上传 14 条，冲突 0"
}
```

- `state`：`unbound` / `pending`（上传中，可恢复）/ `bound` / `needs_reconcile`。
- 一个库最多一个 ownerId；ownerId 不匹配 = 场景 5。
- 绑定记录**不放入 SQLite**：数据库备份复制到另一台机器时不会自动继承账号。
- 写入用“临时文件 + rename”，避免半写。

### 3.3 `device.json`

```json
{
  "deviceId": "0192f0a0-0000-7000-8000-00000000000a",
  "createdAt": "2026-11-15T05:00:00.000000Z"
}
```

- 每个安装一个；丢失则重新生成（旧设备记录留在服务端，不影响数据）。
- 不放进数据库、不进备份、不复制到新机器。

### 3.4 激活工作区

`workspaces.json`（由 Agent D 维护，可选）：

```json
{
  "version": 1,
  "activeWorkspaceId": "account-usr_01j9...",
  "workspaces": [
    { "id": "local-default", "dbPath": "app.db", "bindingPath": "app.db.binding.json" },
    { "id": "account-usr_01j9...", "dbPath": "accounts/usr_01j9.../app.db", "bindingPath": "accounts/usr_01j9.../binding.json" }
  ]
}
```

切换账号 = 改 `activeWorkspaceId` + 重启/重建 `PlannerApp`。**不拷贝数据**。

## 4. 绑定状态机

```
                 ┌──────────────┐
                 │   unbound    │
                 └──────┬───────┘
      用户确认上传        │        用户选择云端/新建
   （仅云端空）           │
                 ┌──────▼───────┐
                 │   pending    │  ← 先整库备份，再分批 push
                 └──────┬───────┘
              全部 applied│       失败/中断
                 ┌──────▼───────┐
                 │    bound     │  ← 再 pull 一次，确认一致
                 └──────┬───────┘
        恢复备份/检测到不一致│
                 ┌──────▼───────┐
                 │needs_reconcile│ → 全量 pull 对账，禁止自动 push
                 └──────────────┘
```

任何状态都可取消；取消不得删除本地数据。

## 5. 首次绑定流程（按场景）

### 5.1 场景 1：全新安装，云端有数据

1. 登录成功，`inspectBinding()` 返回 `freshInstallCloudHasData`、
   `cloudRecords > 0`。
2. 询问用户：“云端已有 N 条数据，是否创建本机工作区并下载？”
3. 用户确认 → 新建 `accounts/<ownerId>/app.db`（空库）→ `binding.state=bound`
   → `syncNow(mode: full)`。
4. 全量 pull 分页应用；完成后显示“已下载 N 条”。
5. 不复制任何 `local-default` 数据（本来为空）。

### 5.2 场景 2：全新安装，云端为空

1. `inspectBinding()` 返回 `freshInstallCloudEmpty`，`cloudRecords == 0`。
2. 新建账号库 + `state=bound`；无需上传。
3. 用户开始新建数据，outbox 正常累积。

### 5.3 场景 3：本地有数据，云端为空

1. `inspectBinding()` 返回 `localDataCloudEmpty`，展示：
   - 本地 live 记录数（项目/阶段/任务/备注分项）；
   - 云端 0 条；
   - 目标账号邮箱。
2. 用户必须勾选/点击“把本机数据上传到该账号”。
3. 执行前强制：
   - `BackupService.snapshotDatabase(prefix: 'pre-bind')`；
   - `BackupService.exportJson()`；
   - 校验快照 `quick_check`。
4. `binding.state=pending`；按 `project → span → task → note` 分批 push
   （每批 ≤100，opId 稳定）。
5. 每批 applied/duplicate 后写 `server_revision`；有 conflict 立即停止并提示
   （理论上云端空不应冲突；若发生说明云端并非真空/并发，需人工处理）。
6. 全部成功后 `state=bound`；再 `syncNow(mode: full)` 对齐。
7. 失败/中断：`state=pending`；下次登录同一账号可继续；换账号必须拒绝。

### 5.4 场景 4：本地和云端都有数据

**禁止自动上传/自动合并。** UI 只提供：

| 选项 | 行为 | 结果 |
|---|---|---|
| 取消 | 不做任何事 | 本地保持 unbound；登录可保持但不同步 |
| 以云端为准（推荐） | 整库快照 + JSON 备份 → 归档当前库 → 新建账号库 → 全量 pull | 本地旧数据保留在归档；当前库=云端 |
| 保持本地不绑定 | 新建空的账号库（或不登录） | 本地库不参与同步 |

“合并两边”在 V2 **不提供自动实现**；如未来提供，必须先做 dry-run 报告、
逐实体冲突列表与用户确认。当前版本不得用“先上传再拉取”冒充合并。

### 5.5 场景 5：本地已绑定其他账号

1. 读取 `binding.json` 的 ownerId；与当前登录账号比较。
2. 不匹配 → `inspectBinding()` 返回 `boundOtherAccount`，`canUpload=false`。
3. UI 明确显示：“本机数据属于 A（email），当前登录 B；不会上传。
   可为 B 新建独立工作区，A 的数据保留。”
4. 用户选择：
   - 取消登录 → 回到未登录/原账号；
   - 为 B 新建空库 → 切换激活工作区，A 库不变。
5. **任何情况下不得把 A 的记录推给 B**；服务端 owner 隔离是最后防线。

### 5.6 场景 6：同设备切换账号

1. 退出登录：清 token，不删账号库、不删本地数据。
2. 登录 B：读取 B 的 `accounts/<B>/app.db`；不存在则新建空库。
3. 切换 `workspaces.json` 激活项；提示重启/由 D 重建作用域。
4. A 的 outbox 保留在 A 库；B 的同步只读写 B 库。
5. 不得把 A 的 outbox 复制到 B；不得共用 `sync_state.cursor`。

## 6. 上传协议（首次绑定专用）

### 6.1 顺序

```
1. projects（按 createdAt 升序）
2. plan_spans（按 createdAt 升序；projectId 必须已上传）
3. planner_tasks（按 createdAt 升序；projectId/spanId 必须已上传）
4. daily_notes（按 date 升序）
```

每批最多 100 op；批间可失败重试。每个实体用 `opType=create`、`baseRevision=0`、
`opId` 在首次尝试前生成并持久化到 outbox；重试复用。

### 6.2 只上传 live 记录

- 本地墓碑不上传（云端从未有该实体）。
- 若实体有 `server_revision > 0`，说明不是首次上传，改用 update/delete 语义；
  首次绑定只处理 `server_revision=0` 的 live 记录。
- 备注按 `date` 唯一；若云端已有同日 note（不应发生），停止并提示冲突。

### 6.3 分批与断点

- 每批成功后立即从 outbox 删除已确认 op，并更新实体的 `server_revision`。
- 进程崩溃后 `state=pending`；用 outbox 继续，不重新生成 opId。
- 上传完成后跑一次 `syncNow(mode: full)`，逐页应用快照，确认本地与服务端一致。
- 一致性检查：项目/阶段/任务/备注的 live 数量与云端返回数量一致；
  不一致则进入 `needs_reconcile`，不标记 bound。

## 7. 以云端为准 / 覆盖本地时的保护

只有用户显式选择 `useCloudAndArchiveLocal` 才允许：

1. 关闭自动同步，停止所有 push；
2. `snapshotDatabase(prefix: 'pre-cloud-replace')`；
3. `exportJson()` 到 `backups/`；
4. 校验两个备份可读；
5. 把当前 `app.db` 复制/移动到 `archive/local-<timestamp>.db`（保留绑定旁路）；
6. 新建账号库，写 `binding.json`；
7. 全量 pull；
8. 在 UI 展示备份路径与“如何恢复”。

**不得**直接 `DELETE FROM` 或 `VACUUM` 覆盖原库；不得在没有备份时执行。

## 8. 备份与恢复协议

### 8.1 绑定时必须备份

| 时机 | 备份 |
|---|---|
| 首次上传前 | SQLite 快照 + JSON |
| 以云端为准前 | SQLite 快照 + JSON + 归档当前库 |
| 解决批量冲突前 | SQLite 快照（可选但推荐） |
| 结构迁移前 | 快照（V1 已有迁移事务，但仍建议） |

备份目录：`%APPDATA%\计划台\data\backups\`；文件名含 `pre-bind`/`pre-cloud-replace`。
备份含真实用户数据，**不得提交 Git、不得上传服务器**。

### 8.2 恢复后的同步

现有 `BackupService.restore` 会整体替换四张表并写入
`change_log(database, full, restore)`。同步层必须识别该标记：

1. 停止自动 push；
2. 清空 `sync_outbox` 与未解决冲突（备份中的实体没有可靠 opId）；
3. `binding.state = needs_reconcile`；
4. 做一次 snapshot pull，按 entityId 匹配并写 `server_revision`；
5. 本地有、服务端无的 live 实体 → 作为 create 入 outbox（用户确认后上传）；
6. 服务端有、本地无 → 作为 pull 应用；
7. 两边都有但内容不同 → 生成冲突，不得自动覆盖。

在完成对账前，UI 显示“需要重新同步”，禁止“一键同步”直接覆盖。

## 9. 账号删除/退出/注销

- 退出登录：清 token；本地数据与 outbox 保留；自动同步停止。
- 切换账号：按 §5.6；旧账号库保留。
- 注销账号（若未来提供）：先提示导出备份；服务端删除 owner 数据；
  本地账号库保留为只读归档，不再同步。
- 管理员禁用账号：同步返回 403；本地仍可用；提示联系管理员。

## 10. 验收清单

- [ ] 五种场景均有 UI 文案与不可绕过的分支。
- [ ] 云端有数据时 `uploadLocalToAccount` 被拒绝（服务端/客户端双重）。
- [ ] 已绑定 A 的库登录 B 时，B 的 push 数量为 0，且 UI 明确说明。
- [ ] 首次上传前存在可校验的 SQLite 快照 + JSON 备份。
- [ ] 上传中断后重试复用 opId，不产生重复实体。
- [ ] 换账号后 A/B 的 cursor、outbox、数据库文件互不混用。
- [ ] 恢复备份后进入 `needs_reconcile`，不会自动把旧数据灌回云端。
- [ ] 所有覆盖操作都可从备份恢复，路径在 UI 可见。
