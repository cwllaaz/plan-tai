# 云同步协议集

计划台的云同步是**可选**能力：不登录时应用完全离线。登录后，客户端与你自建的
PocketBase 0.23.12 服务端通过 `/api/planner/*` 自定义路由同步数据。

## 阅读顺序

1. [ARCHITECTURE.md](ARCHITECTURE.md) — 分层、本地优先、同步算法、服务端拓扑。
2. [DATA_CONTRACT.md](DATA_CONTRACT.md) — 实体、编码、时区、删除墓碑、版本、本地 v2 表。
3. [API_CONTRACT.md](API_CONTRACT.md) — 登录、push、pull、错误码、PocketBase 模型。
4. [CLIENT_INTERFACE.md](CLIENT_INTERFACE.md) — Flutter 接口签名、状态机、Fake 用法。
5. [ACCOUNT_BINDING.md](ACCOUNT_BINDING.md) — 首次绑定、换账号、备份恢复、禁止事项。
6. [SECURITY.md](SECURITY.md) — TLS、令牌、账号隔离、限流、服务器加固。
7. [TEST_CASES.md](TEST_CASES.md) — 必测场景与手工验收清单。
8. [fixtures/](fixtures/) — 固定协议测试数据与 Fake 约定。

## 一句话架构

**本地 SQLite 先写 → outbox 同事务入队 → push（opId 幂等 + 版本冲突）→
pull（serverCursor 增量 / 快照）→ 每页事务应用 → 冲突持久化由用户解决。**

任何情况下都不允许用云端快照静默覆盖本地数据库，也不允许把未归属 / 他账号的数据自动上传。

## 冻结的契约代码

- `lib/core/cloud/cloud.dart`
- `lib/core/cloud/cloud_types.dart`
- `lib/core/cloud/cloud_services.dart`
- `lib/core/cloud/fake_cloud_services.dart`

变更契约需同步修改本目录文档与对应测试。
