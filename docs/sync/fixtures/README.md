# 协议测试夹具（fixtures）

> 本目录是 **A/B/C 三个 Agent 共用的固定测试数据**。
> 主文件：`scenarios.json`。字段语义以 [../DATA_CONTRACT.md](../DATA_CONTRACT.md)、
> [../API_CONTRACT.md](../API_CONTRACT.md) 为准。

## 1. 使用规则

1. **不得改 ID/时间/游标**：所有 UUID、ISO 时间、`serverCursor` 都是固定的，
   跨端比对依赖它们。测试代码不得在运行时随机生成这些值。
2. **语义断言优先**：`serverTime`、`appliedAt` 允许服务端替换为当前时间；
   其余字段必须逐字段一致（`serverTime` 可忽略）。
3. **不依赖真实服务器**：服务端测试可用 `scenarios.json` 驱动 HTTP handler；
   客户端测试可用它驱动 JSON 解析/同步引擎；UI 测试用 Fake，不读本文件。
4. **不包含真实用户数据**：全部是虚构示例，可提交 Git。
5. **新增场景**：只追加新 `id`，不改已有场景；同步更新 TEST_CASES。

## 2. 结构

```
scenarios.json
├─ fixtureVersion / protocolVersion / schemaVersion
├─ common                 # 固定 owner/device/entity/op ID
├─ entities               # 可复用的实体 payload
└─ scenarios[]
   ├─ id / title / given
   ├─ pushRequest / pushResponse
   ├─ pullRequest / pullResponse
   └─ 或 pushA/pushB/...   # 多设备场景
```

## 3. 场景索引

| id | 名称 | 关键断言 |
|---|---|---|
| TC-01 | 新增任务 | `applied`, `serverRevision=1` |
| TC-02 | 修改任务 | `applied`, `serverRevision=2` |
| TC-03 | 删除任务 | 墓碑 `deleted=true`, `payload=null` |
| TC-04 | 重复操作 | `duplicate`, 版本/游标不变 |
| TC-05 | 两设备改同一任务 | `UPDATE_UPDATE`, 返回 A 的 payload |
| TC-06 | 修改已删除任务 | `UPDATE_DELETE`, 禁止复活；保留本地=新 ID 副本 |
| TC-07 | 首次绑定既有数据 | project→span→task→note 全部 applied；快照一致 |
| TC-08 | 断网恢复 | 同 opId 重发 → `duplicate` 或 `applied`，无重复 |

## 4. 服务端测试接入

伪代码（语言无关）：

```text
fixture = load("docs/sync/fixtures/scenarios.json")
for scenario in fixture.scenarios:
    seedServer(scenario.given)
    actual = handlePush(scenario.pushRequest)
    assertSemanticEquals(actual, scenario.pushResponse, ignore=["serverTime", "appliedAt"])
    if scenario.pullRequest:
        actualPull = handlePull(scenario.pullRequest)
        assertSemanticEquals(actualPull, scenario.pullResponse, ignore=["serverTime"])
```

- `seedServer` 需按 `given` 预置项目/任务/墓碑；TC-01 依赖项目已存在。
- 服务端必须使用 fixture 中的 `ownerId` 作为登录用户 ID；不得改写。
- 响应字段顺序无关；数组顺序必须一致（`results` 与 ops 对齐）。
- 冲突场景必须校验 `conflict.serverPayload` 的完整字段，不能只校验 title。

## 5. 客户端测试接入

- 用 fixture 的 `pullResponse` 驱动同步引擎的“应用远端变更”，断言本地实体
  字段、`server_revision`、cursor、墓碑。
- 用 fixture 的 `pushResponse` 驱动 outbox 处理，断言 applied/duplicate/conflict
  分支与 outbox 删除/保留。
- 引擎不得依赖 fixture 中的 `serverTime` 做排序；只使用 `serverCursor`。

## 6. Fake 服务契约

Fake 的权威实现与测试在：

- `lib/core/cloud/fake_cloud_services.dart`
- `test/core/cloud/fake_cloud_services_test.dart`
- 语义说明：`docs/sync/CLIENT_INTERFACE.md` §8

Fake 必须支持：

| 行为 | 方法 |
|---|---|
| 登录/退出/会话恢复/过期 | `FakeCloudAccountService` |
| 状态流先推当前值、syncing→idle | `observeSyncStatus`, `syncNow` |
| 离线/未登录的结果 | `setOffline`, `setAccount` |
| 冲突列表/解决/manual 校验 | `seedConflict`, `resolveConflict` |
| 绑定检查只读、云端非空拒绝上传 | `setBindingInspection`, `applyBinding` |
| 自动同步开关 | `enableAutoSync` |

Fake **不模拟** SQLite/HTTP/服务端版本；它只提供 UI 所需的状态与结果。
A/B 的真实实现必须通过同一套语义测试，不能只让 Fake 通过。

## 7. 规范化哈希（可选增强）

若服务端实现 `requestHash`，对每个 op 的
`{entityType,entityId,opType,baseRevision,payload}` 按 DATA_CONTRACT §8
生成 canonical JSON + SHA-256。测试可将期望哈希作为额外断言字段加入
`scenarios.json`（新增字段不影响现有解析）。当前夹具暂不内置哈希值，
避免不同语言 JSON 序列化差异造成假失败。
