/// 云账号与同步的公共接口（**已冻结**）。
///
/// 实现方：
/// - 每日面板模块 在 `lib/data/cloud/` 实现真实 HTTP + PocketBase 认证 + 同步引擎；
/// - 数据层 只依赖本文件，用 `FakeCloudServices` 独立开发 UI；
/// - Agent D 负责把 [CloudServices] 注入应用树并替换顶栏占位按钮。
///
/// 约束（所有实现必须遵守）：
/// 1. 这些方法**不阻塞 UI 线程**，全部返回 Future/Stream；
/// 2. 网络错误统一转成 [CloudException]，不向 UI 抛 HTTP/JSON 细节；
/// 3. `syncNow` 同一时刻只允许一个在跑；重复调用应复用或排队，不得并发写本地库；
/// 4. `logout` 不删除本地数据，也不删除账号工作区；
/// 5. `observeSyncStatus` 必须先推当前值，再推变化（与现有仓储流语义一致）；
/// 6. 禁止把密码、token 放进 [SyncStatus]、日志或异常 message。
library;

import 'cloud_types.dart';

/// 云端账号与认证。
abstract interface class CloudAccountService {
  /// 账号变化流（登录/退出/会话过期）。先推当前值。
  Stream<CloudAccount?> observeAccount();

  /// 当前账号；未登录返回 null。
  CloudAccount? currentAccount();

  /// 连接并校验服务端（`GET /api/planner/health`）。
  ///
  /// 成功只代表服务器可达且协议兼容，**不代表已登录**。
  /// `baseUrl` 必须是 https；仅 localhost/127.0.0.1 的开发环境允许 http。
  Future<ServerHandshake> connectServer(Uri baseUrl);

  /// 用普通账号密码登录（PocketBase `auth-with-password`）。
  ///
  /// 登录成功不会自动上传本地数据；数据归属由
  /// [SyncService.inspectBinding] + [SyncService.applyBinding] 处理。
  Future<CloudAccount> login({
    required String username,
    required String password,
  });

  /// 尝试用本地保存的会话恢复登录；没有会话或已过期返回 null。
  Future<CloudAccount?> restoreSession();

  /// 退出登录。默认通知服务端撤销会话；失败也必须清空本地 token。
  Future<void> logout({bool revokeRemoteSession = true});

  /// 释放资源；可重复调用。
  Future<void> close();
}

/// 双向同步服务。一个实例绑定一个本地工作区（一个 SQLite 库）。
abstract interface class SyncService {
  /// 同步状态流。先推当前值，再推变化。
  Stream<SyncStatus> observeSyncStatus();

  /// 当前状态快照（不等待网络）。
  SyncStatus get status;

  /// 手动一键双向同步：先 push 本地待上传操作，再 pull 服务端增量。
  ///
  /// [SyncMode.full] 用于首次绑定或游标修复，会做服务端快照拉取。
  /// 冲突不会抛异常，而是以 [SyncOutcome.conflict] 返回，并写入
  /// [listConflicts]。
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental});

  /// 只上传：把本机待上传改动 push 到云端，不从云端拉取。
  Future<SyncResult> uploadNow();

  /// 只下载：从云端拉取更新应用到本机，不主动上传本机改动。
  ///
  /// 默认保留本机未上传改动并生成冲突。用户明确确认“覆盖本机”时传
  /// [overwriteLocal] = true：实现会先整库备份，再丢弃本机 outbox/冲突，
  /// 用云端快照覆盖本机（云端没有的本机记录会从当前库移除）。
  Future<SyncResult> downloadNow({
    SyncMode mode = SyncMode.incremental,
    bool overwriteLocal = false,
  });

  /// 开启/关闭自动上传（本机改动后台推送）。
  Future<void> enableAutoUpload(bool enabled);

  /// 开启/关闭自动下载（定时从云端拉取更新）。
  Future<void> enableAutoDownload(bool enabled);

  /// 兼容旧调用：同时打开/关闭自动上传与自动下载。
  Future<void> enableAutoSync(bool enabled);

  /// 未解决的冲突（按检测时间升序）。
  Future<List<SyncConflict>> listConflicts();

  /// 解决一条冲突。成功后该冲突从列表移除，并尽快触发一次同步。
  ///
  /// [ConflictResolution.manual] 时必须提供 [mergedPayload]；其他方式忽略它。
  Future<SyncResult> resolveConflict(
    String conflictId,
    ConflictResolution resolution, {
    Map<String, Object?>? mergedPayload,
  });

  /// 只读检查本地数据归属与云端数据量。**不得产生任何写入/上传**。
  ///
  /// 未登录、网络不可用时应抛 [CloudException] 或返回 `cloudRecords == null`，
  /// 绝不能把“不知道”当成“云端为空”。
  Future<BindingInspection> inspectBinding();

  /// 执行用户确认的绑定选择。涉及本地数据时先做整库备份。
  ///
  /// 绑定成功后可能需要切换 Repository / 重启应用，见
  /// [BindingResult.requiresRestart]。
  Future<BindingResult> applyBinding(BindingChoice choice);

  /// 释放资源；可重复调用。
  Future<void> close();
}

/// 应用层注入的云服务组合。
final class CloudServices {
  const CloudServices({required this.account, required this.sync});

  final CloudAccountService account;
  final SyncService sync;

  Future<void> close() async {
    await sync.close();
    await account.close();
  }
}
