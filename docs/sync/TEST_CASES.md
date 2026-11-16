# 计划台 V2.0 · 必测同步场景（TEST_CASES）

> 状态：**已冻结（2026-11-15）**。
> 协议样例：`docs/sync/fixtures/scenarios.json`；Fake 契约：`lib/core/cloud/` +
> `test/core/cloud/fake_cloud_services_test.dart`。
> 所有场景必须同时有：服务端测试（A）、客户端引擎测试（B）、必要的 UI 测试（C）。

## 0. 测试分层与命令

| 层 | 负责 | 命令 |
|---|---|---|
| 契约/Fake | 维护者 | `flutter test --no-pub test/core/cloud` |
| 服务端 | A | `server/` 内按 README（Go/JS/HTTP 测试） |
| 客户端引擎 | B | `flutter test --no-pub test/data/sync test/data/cloud` |
| UI | C | `flutter test --no-pub test/features/cloud_account` |
| 全量回归 | D | `flutter analyze --no-pub && flutter test --no-pub` |

测试数据固定 UUID/时间，**不得**在每次运行时随机生成；否则无法跨端比对。
测试不得使用真实用户数据库；必须用临时目录/内存库。

## 1. 必测场景（8 个）

### TC-01 新增任务

**前置**：账号已登录；工作区绑定；项目 `P1` 已存在于服务端（`serverRevision=1`）。

**步骤**

1. 本地 `createTask`（项目 P1，日期 2026-11-16，09:00–10:30）。
2. outbox 生成 `opType=create, baseRevision=0`。
3. `syncNow()` push。

**期望**

- 服务端 `applied`、`serverRevision=1`、分配新 `serverCursor`。
- 本地 outbox 删除；实体 `server_revision=1`。
- 再 pull 不产生重复实体。
- 另一设备 pull 后看到同一任务，日期/时间/项目一致。

### TC-02 修改任务

**前置**：TC-01 已同步；任务 `T1` 的 `serverRevision=1`。

**步骤**

1. 设备 A 改标题（base=1）。
2. push。

**期望**

- `applied`、`serverRevision=2`、新 cursor。
- 服务端 payload 为新标题；`updatedByDevice=A`。
- 设备 B 增量 pull 后标题更新，`server_revision=2`。

### TC-03 删除任务

**前置**：TC-02；`serverRevision=2`。

**步骤**

1. A 删除任务（base=2）。
2. push；B 增量 pull。

**期望**

- 服务端墓碑：`deleted=true`、`deletedAt` 非空、`payload=null`、`serverRevision=3`。
- B 本地任务软删除，列表/月历不再显示。
- 再次删除同一任务：`applied noOp=true`，不新增 cursor。

### TC-04 重复发送同一个操作

**前置**：TC-01 的 create 已成功，但客户端没收到响应（模拟断网）。

**步骤**

1. 用**同一 opId / 同一 payload** 重发。
2. 再 pull。

**期望**

- 服务端返回 `status=duplicate`，`serverRevision`/`serverCursor` 与首次相同。
- 不新建实体、不增加 cursor、不产生第二条 `planner_ops`。
- 客户端把 outbox 标记完成；最终只有一条任务。
- 同 opId 换 payload → 该 op `rejected` + `OP_ID_REUSED`（额外用例）。

### TC-05 两设备修改同一任务

**前置**：`T1` 在 `serverRevision=2`；A/B 都已拉到 rev2。

**步骤**

1. A 改标题为“A 版”，base=2 → push 成功，rev3。
2. B 改标题为“B 版”，base=2 → push。

**期望**

- B 收到 `conflict UPDATE_UPDATE`，`serverRevision=3`，
  `serverPayload.title="A 版"`，`serverUpdatedByDevice=A`。
- B 本地不得自动覆盖；`sync_conflicts` 增加一条，保留 B 的 `localPayload`。
- B 选择 `keepServer` → 本地变“A 版”，冲突清除。
- 或 B 选择 `keepLocal` → 以 base=3 再 push，rev4，最终“B 版”；A 下次 pull 看到“B 版”。

### TC-06 修改已被删除的任务

**前置**：`T1` 已被 A 删除，`serverRevision=4`，墓碑。

**步骤**

1. B 基于旧版本 rev3 修改 `T1`。
2. push。

**期望**

- `conflict UPDATE_DELETE`，`serverDeleted=true`，`serverPayload=null`。
- 服务端**不得**复活实体；`T1` 仍为墓碑。
- B 选择 `keepServer` → 本地删除。
- B 选择 `keepLocal` → 以**新 entityId** 创建副本（create base=0），
  旧 ID 保持墓碑；新副本出现在月历。
- 新副本的标题/日期/项目与 B 的本地意图一致。

### TC-07 首次绑定包含既有本地数据的设备

**前置**：本机 `app.db` 有 1 项目、1 阶段、1 任务、1 备注；云端为空；
用户已登录并确认上传；已完成整库快照 + JSON 备份。

**步骤**

1. `inspectBinding()` → `localDataCloudEmpty`，`canUpload=true`，`cloudRecords=0`。
2. `applyBinding(uploadLocalToAccount)`。
3. 按 `project → span → task → note` 分批 push（每批 ≤100，opId 稳定）。
4. 全部 applied 后 `syncNow(mode: full)`。

**期望**

- 4 条实体全部 `applied`，`serverRevision=1`，cursor 依次递增。
- 阶段 `projectId` 指向刚上传的项目；任务 `spanId` 指向刚上传的阶段。
- 备注 `date` 唯一。
- 快照 pull 返回 4 条 live 实体，本地 `server_revision` 全部为 1。
- 绑定记录 `state=bound`；备份路径可在 UI 看到。
- 中断后重试不产生重复实体（opId 幂等）。

### TC-08 断网后恢复同步

**前置**：TC-01 的任务已在本地创建，push 时断网（请求可能到达服务器，
也可能没到达）。

**步骤**

1. 断网 → push 失败，outbox 保留 `pending`，状态 `offline`。
2. 恢复网络 → 自动/手动同步。
3. 用同一 opId 重发。
4. pull 增量。

**期望**

- 若首次未到达：`applied`，rev1。
- 若首次已到达但响应丢失：`duplicate`，rev1，无重复。
- 本地只有一条任务；outbox 清空；状态 `idle`；`lastSyncedAt` 更新。
- 再同步一次：`noChanges`，不产生新版本。

## 2. 额外必测（服务端/引擎）

| ID | 场景 | 期望 |
|---|---|---|
| TC-09 | 账号隔离：B 知道 A 的 entityId | B pull 不到；B push update/delete 返回 404/403，A 数据不变 |
| TC-10 | 伪造 body `ownerId` | 403 `OWNER_MISMATCH` |
| TC-11 | 无 token / 过期 token | 401；refresh 成功后继续 |
| TC-12 | 删除项目级联 | 项目/阶段/任务全部墓碑；任务不复活；pull 分页能拿全 |
| TC-13 | 删除阶段 | 阶段墓碑；任务保留且 `spanId=null`，rev+1；另一设备一致 |
| TC-14 | 同一天两个 note 不同 ID | 第二个 `conflict NOTE_DATE_TAKEN`，不写入 |
| TC-15 | 引用不存在的 project/span | `rejected MISSING_REFERENCE`，不写入 |
| TC-16 | 分页：250 条变更，limit=100 | 3 页，`hasMore` 正确，无重复/遗漏 |
| TC-17 | 快照分页中途有新写入 | snapshotSeq 固定；新写入在下一轮增量出现，不漏 |
| TC-18 | 游标非法/过大 | 409 `CURSOR_INVALID`，不返回数据 |
| TC-19 | payload 超 256 KiB / 101 ops | 400/413，事务不写入 |
| TC-20 | 升级：V1 库→V2 迁移 | 旧数据/ID/revision 不变；`server_revision=0`；备份可用 |
| TC-21 | 恢复备份后同步 | 进入 `needs_reconcile`；不会自动把旧数据灌回云端 |
| TC-22 | 已绑定 A 的库登录 B | B 的 push 为 0；UI 阻止上传；A 数据不变 |
| TC-23 | 云端非空 + 本地上传 | `applyBinding(uploadLocalToAccount)` 被拒；无写入 |
| TC-24 | 时钟偏差 | 客户端时间快/慢 1 天，仍按 serverCursor 排序，不丢变更 |
| TC-25 | 时区/跨天 | UTC+8 与 UTC-8 设备看到同一 `YYYY-MM-DD`；跨天条 5 天不变 |

## 3. UI 必测（Fake）

| ID | 场景 | 期望 |
|---|---|---|
| UI-01 | 未登录 | 顶栏 `cloud_off`，点击打开登录，不发起同步 |
| UI-02 | 连接失败 | 显示可读错误，可重试；不泄露堆栈 |
| UI-03 | 登录成功 → 绑定检查 | 显示云端/本地数量；云端非空时“上传本地”禁用 |
| UI-04 | 同步中 | 按钮禁用/旋转，显示待上传数 |
| UI-05 | 冲突 | 显示 N 条冲突；详情含双方摘要；保留本地/服务端可点 |
| UI-06 | 离线 | 显示离线，手动同步可重试；本地编辑不阻塞 |
| UI-07 | 退出登录 | 清账号状态；本地数据仍在；不删账号库 |
| UI-08 | 已绑定他号 | 明确提示不会上传；只提供取消/新建库 |
| UI-09 | 自动上传 / 自动下载开关 | 两个开关独立持久化；关闭一个不影响另一个 |
| UI-10 | 大列表/窄窗口 | 冲突/绑定向导不溢出，可滚动 |
| UI-11 | 上传按钮 | 只触发 push；不改变下载游标 |
| UI-12 | 从云端更新按钮 | 只触发 pull；本机待上传改动保留，冲突可见 |
| UI-13 | 有未上传改动时点从云端更新 | 弹二次确认；选“覆盖并更新”才传 overwriteLocal=true |

## 4. 手工双设备验收

1. 设备 A 登录 → 上传既有数据 → 设备 B 登录同账号 → 全量拉取。
2. A 离线改任务 → B 改同任务 → A 恢复：出现冲突，双方内容可见。
3. A 选保留本地 → B 拉取到 A 版本；B 再改 → A 拉取到 B 版本。
4. A 删除任务 → B 离线改该任务 → B 恢复：提示已删除，可选保留副本。
5. A 删除项目（含阶段/任务）→ B 拉取后全部消失；无孤儿。
6. A 修改跨天阶段起止日 → B 月历跨天条同步更新。
7. A 写每日备注 → B 同日备注冲突/合并策略符合预期。
8. 退出 A → 登录 B → 只看到 B 的数据；A 数据仍在独立库。
9. 重启 A → 状态/待上传/冲突恢复；不重复上传。
10. 服务器重启/维护 → 客户端退避重试；恢复后自动补齐。

## 5. 通过标准

- [ ] TC-01 ~ TC-08 在服务端测试与客户端引擎测试中各有一份可执行用例。
- [ ] TC-09 ~ TC-25 至少服务端/引擎覆盖；UI-01 ~ UI-10 用 Fake 覆盖。
- [ ] 所有测试使用固定夹具；不访问真实用户数据/生产服务器。
- [ ] 原有 243 个测试仍全绿；`flutter analyze` 零问题。
- [ ] 真实服务器联调至少跑通 TC-01/05/06/07/08 + 双设备手工验收。
- [ ] 测试报告记录：命令、结果、失败原因、剩余风险。
