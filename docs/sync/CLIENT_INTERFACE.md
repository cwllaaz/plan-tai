# 计划台 V2.0 · Flutter 公共接口（CLIENT_INTERFACE）

> 状态：**已冻结（2026-11-15）**。代码唯一来源：
> `lib/core/cloud/cloud_types.dart`、`cloud_services.dart`、`fake_cloud_services.dart`。
> 本文件解释语义与使用方式；签名冲突时以代码为准，且必须先改代码+本文再广播。

## 1. 导入方式

```dart
import 'package:jihuatai/core/cloud/cloud.dart';
```

UI 只依赖这个 barrel；**禁止** import `package:pocketbase`、`dart:io`、
`http`、`lib/data/**` 或任何具体实现。

## 2. 类型总览

| 类型 | 用途 |
|---|---|
| `CloudAccount` | 当前账号（ownerId/email/displayName/serverUrl） |
| `CloudAccountService` | 连接、登录、恢复、退出 |
| `SyncService` | 上传/下载/双向同步、自动方向、状态、冲突、绑定 |
| `SyncStatus` | UI 状态快照 |
| `SyncResult` | 单次同步结果 |
| `SyncConflict` | 一条待处理冲突 |
| `SyncPhase` / `SyncOutcome` | 状态/结果枚举 |
| `BindingInspection` / `BindingResult` | 首次绑定检查/执行 |
| `CloudException` | 统一错误 |
| `FakeCloudAccountService` / `FakeSyncService` / `FakeCloudServices` | UI 独立开发 |

## 3. 账号接口

```dart
abstract interface class CloudAccountService {
  Stream<CloudAccount?> observeAccount();
  CloudAccount? currentAccount();
  Future<ServerHandshake> connectServer(Uri baseUrl);
  Future<CloudAccount> login({
    required String username,
    required String password,
  });
  Future<CloudAccount?> restoreSession();
  Future<void> logout({bool revokeRemoteSession = true});
  Future<void> close();
}
```

语义：

| 方法 | 成功 | 失败 | UI 约定 |
|---|---|---|---|
| `observeAccount` | 先推当前值（可能 null），再推变化 | 流错误仅用于不可恢复错误 | 用 `StreamBuilder`；不要自己轮询 |
| `currentAccount` | 立即返回快照，不发网络 | 无 | 仅用于同步初始化 |
| `connectServer` | 返回握手；**不登录** | `protocol`/`network`/`timeout` | 登录页先调；失败留在当前页 |
| `login` | 返回账号并持久化 token | `unauthorized`/`network`/`rateLimited` | 成功后必须进入绑定检查 |
| `restoreSession` | 返回账号 | 无会话返回 null；网络错抛异常 | 启动时调用；失败按未登录处理 |
| `logout` | 清空 token/账号 | 即使远端撤销失败也必须本地清空 | 不清本地数据；不删账号工作区 |

**禁止**：`login` 成功后自动上传本地数据；自动上传只能由
`SyncService.applyBinding(BindingChoice.uploadLocalToAccount)` 在用户确认后触发。

### 3.1 登录页推荐流程

```
用户输入服务器地址 / 邮箱 / 密码
  → connectServer(Uri.parse(address))
  → login(username: email, password: password)
  → sync.inspectBinding()
  → 根据 BindingSituation 弹绑定确认
  → sync.applyBinding(choice)
  → 若 requiresRestart：提示重启/由 D 重建作用域
  → sync.syncNow()（或等待自动同步）
```

## 4. 同步接口

```dart
abstract interface class SyncService {
  Stream<SyncStatus> observeSyncStatus();
  SyncStatus get status;
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental});
  Future<SyncResult> uploadNow();
  Future<SyncResult> downloadNow({
    SyncMode mode = SyncMode.incremental,
    bool overwriteLocal = false,
  });
  Future<void> enableAutoUpload(bool enabled);
  Future<void> enableAutoDownload(bool enabled);
  Future<void> enableAutoSync(bool enabled); // 兼容：同时切换两个方向
  Future<List<SyncConflict>> listConflicts();
  Future<SyncResult> resolveConflict(
    String conflictId,
    ConflictResolution resolution, {
    Map<String, Object?>? mergedPayload,
  });
  Future<BindingInspection> inspectBinding();
  Future<BindingResult> applyBinding(BindingChoice choice);
  Future<void> close();
}
```

### 4.1 `syncNow` / `uploadNow` / `downloadNow`

- 三个方法同一实例同一时刻只跑一个；重复调用返回进行中的 Future。
- `syncNow`：push pending → pull incremental（双向，保留给首次绑定/兼容）。
- `uploadNow`：**只 push**，不 pull；不改变本地拉取游标。
- `downloadNow`：**只 pull**，不 push；本机待上传的改动保留在 outbox。
  若远端改到同一条记录，`RemoteApplier` 会保留本地版本并生成冲突，不静默覆盖。
- `downloadNow(overwriteLocal: true)`：**仅在用户二次确认后使用**。先整库备份，
  再清空本机业务表、outbox 与冲突，用云端完整快照重建本机数据；云端没有的
  本机记录会被移除，执行后本机与云端快照一致。备份是尽力而为：SQLite 快照 /
  JSON 备份都失败时仍继续，并在结果里说明。
- 有冲突不抛异常，返回 `SyncOutcome.conflict`；冲突写 `listConflicts()`。
- 未登录返回 `authRequired`；离线返回 `offline`；协议不兼容抛 `CloudException`。
- `SyncMode.full` 只用于首次绑定/修复；`downloadNow(full)` 做快照拉取，
  不做“本地差异自动重推”。
- 三个按钮在 `phase == syncing` 时都应禁用。

### 4.2 `enableAutoUpload` / `enableAutoDownload`

- 两个开关**独立持久化**，默认关闭/开启由实现决定；UI 必须分别展示。
- 自动上传：本地写入 debounce 后 push；只影响 outbox，不拉取。
- 自动下载：启动/网络恢复/定时拉取；不主动 push。
- 任一开关关闭时，对应方向的定时器/订阅必须停止；另一个方向不受影响。
- 兼容方法 `enableAutoSync(bool)` 等价于同时设置两个开关。

### 4.3 `listConflicts` / `resolveConflict`

- 列表按 `detectedAt` 升序；UI 显示实体类型、标题（从 payload 取）、
  本地/服务端摘要、检测时间。
- `manual` 必须传 `mergedPayload`，否则抛 `CloudException(protocol)`。
- 解决成功后冲突从列表移除，并尽快同步；同步失败时冲突保留。
- UI 不得批量“全部保留本地/全部保留服务端”而不提示影响。

### 4.4 `inspectBinding` / `applyBinding`

- `inspectBinding` **只读**：只统计本地 live 记录数、云端记录数、当前绑定；
  不得上传、不得写数据库、不得清空数据。
- 云端记录数未知时必须返回 `cloudRecords=null` 或抛网络错误，
  不得用 `0` 冒充“云端为空”。
- `applyBinding` 必须先备份再执行；`BindingResult.backupPath` 必须可展示。
- `uploadLocalToAccount` 仅在 `canUpload == true` 时允许；否则抛
  `CloudException(conflict)`，UI 不得绕过。
- `requiresRestart == true` 时，UI 提示“需要重启以切换本地数据空间”，
  不得自行清空当前 Repository。

## 5. 状态与状态机

```dart
enum SyncPhase { signedOut, idle, syncing, offline, needsAttention, error }
```

```
signedOut ──login──► idle
idle ──syncNow──► syncing ──success──► idle
                         ├─conflict──► needsAttention
                         ├─offline───► offline ──网络恢复──► syncing
                         └─error─────► error ──重试/登录──► idle
needsAttention ──resolveConflict──► idle
任何阶段 ──logout──► signedOut
```

UI 展示建议：

| phase | 顶栏图标 | 文案 |
|---|---|---|
| `signedOut` | `cloud_off` | 未登录 |
| `idle` | `cloud_done` | 已同步 · 刚刚/时间 |
| `syncing` | 旋转 | 同步中… |
| `offline` | `cloud_off` | 离线，稍后重试 |
| `needsAttention` | `cloud_sync_problem` | N 条冲突待处理 |
| `error` | `error_outline` | 同步失败（可重试） |

`SyncStatus.pendingOperations > 0` 时即使 `idle` 也应显示“N 项待上传”。
`lastError` 只在错误态展示；成功后必须清空。

`SyncStatus` 的方向字段：

| 字段 | 含义 |
|---|---|
| `autoUploadEnabled` | 自动上传开关 |
| `autoDownloadEnabled` | 自动下载开关 |
| `lastUploadedAt` | 最近一次成功上传时刻 |
| `lastDownloadedAt` | 最近一次成功从云端更新时刻 |
| `autoSyncEnabled` | 兼容 getter：任一自动方向开启即为 true |

## 6. 错误处理

所有实现把底层错误映射为 `CloudException`：

| kind | 典型来源 | UI |
|---|---|---|
| `network` | 断网、DNS、连接失败 | “网络不可用”，可重试 |
| `timeout` | 请求超时 | 可重试 |
| `unauthorized` | 401/密码错 | 重新登录/检查密码 |
| `forbidden` | 403 owner 不匹配/禁用 | 切换账号/联系管理员 |
| `notFound` | 404/会话不存在 | 刷新 |
| `conflict` | 业务冲突/绑定被拒 | 展示冲突/绑定说明 |
| `rateLimited` | 429 | 按 Retry-After 提示 |
| `server` | 5xx | 稍后重试 |
| `protocol` | 版本不兼容/响应非法 | 升级客户端/服务端 |
| `cancelled` | 用户取消 | 不提示错误 |
| `unknown` | 兜底 | 通用错误 + 日志 |

UI 不得直接显示 HTTP 状态码、JSON 解析异常或堆栈。

## 7. 线程与事务约束（实现方）

- 所有 SQLite 写在 `PlannerDatabase.transaction` 内；远端变更按页事务。
- `syncNow` 不得在 UI isolate 做长耗时 JSON 解析；网络/解析放 isolate 或异步。
- 流必须先推当前值；`observeSyncStatus` 在订阅时立即给 UI 一个状态。
- `close()` 可重复调用；关闭后所有方法抛 `StateError`，UI 不应再调用。
- 同步层不得调用 `PlannerRepository.update*` 来应用远端变更（会触发本地
  revision 校验与 outbox 回声）；使用专门的同步 DAO/原始 SQL，并在提交后
  `notifyChanged()`。

## 8. 用 Fake 独立开发 UI

```dart
final fakes = FakeCloudServices(
  signedInAccount: CloudAccount(
    ownerId: 'owner-demo',
    email: 'demo@example.com',
    serverUrl: Uri.parse('https://demo.local'),
    authenticatedAt: DateTime.utc(2026, 11, 15),
  ),
);
final CloudServices services = fakes.services;

// 模拟同步中 → 冲突
fakes.sync.setNextResult(SyncResult(
  outcome: SyncOutcome.conflict,
  finishedAt: DateTime.utc(2026, 11, 15, 6, 5),
  conflicts: 1,
));
fakes.sync.seedConflict(SyncConflict(
  id: 'c1',
  entityType: CloudEntityType.task,
  entityId: 'task-1',
  baseRevision: 1,
  serverRevision: 2,
  kind: ConflictKind.updateUpdate,
  detectedAt: DateTime.utc(2026, 11, 15, 6, 5),
  localPayload: const {'title': '本地标题'},
  serverPayload: const {'title': '服务端标题'},
));

// 在 widget test 中 pump，断言状态/对话框
```

Fake 能力：

| 类 | 控制方法 |
|---|---|
| `FakeCloudAccountService` | `seedSession`、`expireSession`、构造 credentials |
| `FakeSyncService` | `setNextResult`、`failNextSync`、`setOffline`、`emitStatus`、`seedConflict`、`setBindingInspection`、`setAccount` |
| `FakeCloudServices` | `.services`、`.close()` |

Fake 必须与真实实现通过 `test/core/cloud/` 的契约测试；Fake 的行为是 UI 测试的
基准，不是“随便返回成功”。

## 9. UI 集成点（Agent D 负责接线）

| 位置 | 现状 | V2 |
|---|---|---|
| `lib/app/app_shell.dart` 顶栏 | 云图标占位，点击提示“后续版本” | 云状态按钮 + 登录/同步面板入口 |
| `lib/app/settings_dialog.dart` | 文案列“云同步后续版本” | 显示账号/服务器/自动上传/自动下载/退出 |
| 新增 `CloudScope` | 无 | 注入 `CloudServices` + 账号状态 |
| `main.dart` | 直接构造 SQLite 仓储 | 解析工作区、构造云服务、恢复会话 |
| `app.dart` | 固定 repository | 支持工作区切换/重启 |

UI 数据层 不修改以上冻结文件；只新增 `lib/features/cloud_account/**` 与
`test/features/cloud_account/**`，通过构造参数/Fake 开发，等 D 接线。

## 10. 完成定义（每日面板模块 / C）

- B：真实 `CloudAccountService`/`SyncService` 实现上述接口；`flutter analyze`
  零问题；契约测试 + 引擎测试通过；不修改 `lib/core/cloud/` 冻结文件。
- C：登录/账号/同步状态/冲突/绑定 UI 可在 Fake 下完整走通；不启动 PocketBase；
  `flutter analyze` 零问题；widget tests 覆盖离线、冲突、绑定拒绝、退出登录。
- D：接线后现有 243 个测试仍全绿；新增端到端测试；真实服务器联调通过。
