/// 供 UI / 测试使用的 Fake 云服务（**契约的一部分，已冻结**）。
///
/// 目标：数据层 不启动 PocketBase、不联网，也能完整走通：
/// 登录 → 首次绑定 → 同步中/成功/冲突/离线 → 解决冲突 → 退出。
///
/// 这些 Fake **不是**同步引擎：它们不读写 SQLite、不发 HTTP，只维护内存状态。
/// 真实实现由 每日面板模块 提供，二者必须通过 `test/core/cloud/` 的契约测试。
library;

import 'dart:async';

import 'cloud_services.dart';
import 'cloud_types.dart';

enum _FakeDirection { upload, download, both }

/// 可手动控制的内存账号服务。
final class FakeCloudAccountService implements CloudAccountService {
  FakeCloudAccountService({
    CloudAccount? account,
    DateTime Function()? clock,
    Map<String, String>? credentials,
  }) : _current = account,
       _clock = clock ?? DateTime.now,
       _credentials = Map<String, String>.from(
         credentials ?? const <String, String>{'demo@example.com': 'demo1234'},
       ) {
    if (account != null) _session = account;
  }

  final DateTime Function() _clock;
  final Map<String, String> _credentials;
  final StreamController<CloudAccount?> _changes =
      StreamController<CloudAccount?>.broadcast();

  CloudAccount? _current;
  CloudAccount? _session;
  Uri? _baseUrl;
  bool _closed = false;

  /// 登录/退出/会话恢复发生次数，供 UI 测试断言。
  int loginCalls = 0;
  int logoutCalls = 0;

  @override
  Stream<CloudAccount?> observeAccount() =>
      Stream<CloudAccount?>.multi((controller) {
        controller.add(_current);
        final subscription = _changes.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  @override
  CloudAccount? currentAccount() => _current;

  @override
  Future<ServerHandshake> connectServer(Uri baseUrl) async {
    _ensureOpen();
    if (baseUrl.scheme != 'https' &&
        baseUrl.host != 'localhost' &&
        baseUrl.host != '127.0.0.1') {
      throw const CloudException(CloudErrorKind.protocol, '正式环境必须使用 HTTPS');
    }
    _baseUrl = baseUrl;
    return ServerHandshake(
      baseUrl: baseUrl,
      serverVersion: 'fake-pocketbase-0.0.0',
      protocolVersion: 1,
      minSchemaVersion: 1,
      maxSchemaVersion: 1,
      serverTime: _clock().toUtc(),
      features: const <String>['sync.push', 'sync.pull'],
    );
  }

  @override
  Future<CloudAccount> login({
    required String username,
    required String password,
  }) async {
    _ensureOpen();
    loginCalls++;
    final expected = _credentials[username.trim().toLowerCase()];
    if (expected == null || expected != password) {
      throw const CloudException(CloudErrorKind.unauthorized, '账号或密码不正确');
    }
    final baseUrl = _baseUrl ?? Uri.parse('https://fake.local');
    final account = CloudAccount(
      ownerId: 'fake-owner-${username.trim().toLowerCase()}',
      email: username.trim(),
      displayName: null,
      serverUrl: baseUrl,
      authenticatedAt: _clock().toUtc(),
    );
    _current = account;
    _session = account;
    _changes.add(account);
    return account;
  }

  @override
  Future<CloudAccount?> restoreSession() async {
    _ensureOpen();
    _current = _session;
    _changes.add(_current);
    return _current;
  }

  @override
  Future<void> logout({bool revokeRemoteSession = true}) async {
    _ensureOpen();
    logoutCalls++;
    _current = null;
    _session = null;
    _changes.add(null);
  }

  /// 测试辅助：不经过登录直接设置会话（模拟已保存 token 恢复）。
  void seedSession(CloudAccount? account) {
    _ensureOpen();
    _session = account;
    _current = account;
    _changes.add(account);
  }

  /// 测试辅助：模拟服务端 token 过期。
  void expireSession() {
    _ensureOpen();
    if (_current == null) return;
    _current = null;
    _session = null;
    _changes.add(null);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('FakeCloudAccountService 已关闭');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }
}

/// 可手动控制的内存同步服务。默认每次 `syncNow` 都成功且无变化。
final class FakeSyncService implements SyncService {
  FakeSyncService({
    CloudAccount? account,
    DateTime Function()? clock,
    BindingInspection? bindingInspection,
    SyncResult? queuedResult,
    bool autoUploadEnabled = false,
    bool autoDownloadEnabled = false,
  }) : _account = account,
       _clock = clock ?? DateTime.now,
       _bindingInspection =
           bindingInspection ??
           const BindingInspection(
             situation: BindingSituation.freshInstallCloudEmpty,
             canUpload: false,
             requiresBackup: false,
             recommendedChoice: BindingChoice.keepLocalUnbound,
             message: '本机与云端都没有数据',
           ),
       _nextResult = queuedResult,
       _autoUpload = autoUploadEnabled,
       _autoDownload = autoDownloadEnabled {
    _status = SyncStatus(
      phase: account == null ? SyncPhase.signedOut : SyncPhase.idle,
      account: account,
      autoUploadEnabled: autoUploadEnabled,
      autoDownloadEnabled: autoDownloadEnabled,
    );
  }

  final DateTime Function() _clock;
  final StreamController<SyncStatus> _changes =
      StreamController<SyncStatus>.broadcast();
  final Map<String, SyncConflict> _conflicts = <String, SyncConflict>{};

  CloudAccount? _account;
  late SyncStatus _status;
  BindingInspection _bindingInspection;
  SyncResult? _nextResult;
  bool _autoUpload;
  bool _autoDownload;
  bool _offline = false;
  bool _closed = false;
  CloudException? _nextFailure;

  /// `syncNow` / `uploadNow` / `downloadNow` 调用次数，供测试断言。
  int syncCalls = 0;
  int uploadCalls = 0;
  int downloadCalls = 0;
  int overwriteCalls = 0;
  final List<SyncMode> syncModes = <SyncMode>[];
  int resolveCalls = 0;
  BindingChoice? lastBindingChoice;

  @override
  SyncStatus get status => _status;

  @override
  Stream<SyncStatus> observeSyncStatus() =>
      Stream<SyncStatus>.multi((controller) {
        controller.add(_status);
        final subscription = _changes.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  @override
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental}) {
    syncCalls++;
    syncModes.add(mode);
    return _run(_FakeDirection.both, mode: mode);
  }

  @override
  Future<SyncResult> uploadNow() {
    uploadCalls++;
    return _run(_FakeDirection.upload, mode: SyncMode.incremental);
  }

  @override
  Future<SyncResult> downloadNow({
    SyncMode mode = SyncMode.incremental,
    bool overwriteLocal = false,
  }) {
    downloadCalls++;
    if (overwriteLocal) overwriteCalls++;
    syncModes.add(mode);
    return _run(
      _FakeDirection.download,
      mode: mode,
      overwriteLocal: overwriteLocal,
    );
  }

  Future<SyncResult> _run(
    _FakeDirection direction, {
    required SyncMode mode,
    bool overwriteLocal = false,
  }) async {
    _ensureOpen();
    if (_account == null) {
      return _finish(
        SyncResult(
          outcome: SyncOutcome.authRequired,
          finishedAt: _clock().toUtc(),
          message: '请先登录',
        ),
        direction,
      );
    }
    if (_offline) {
      return _finish(
        SyncResult(
          outcome: SyncOutcome.offline,
          finishedAt: _clock().toUtc(),
          message: '当前网络不可用',
        ),
        direction,
      );
    }
    final failure = _nextFailure;
    if (failure != null) {
      _nextFailure = null;
      _emit(
        _status.copyWith(
          phase: SyncPhase.offline,
          lastError: failure.message,
          message: null,
        ),
      );
      throw failure;
    }

    _emit(
      _status.copyWith(
        phase: SyncPhase.syncing,
        message: switch (direction) {
          _FakeDirection.upload => '正在上传',
          _FakeDirection.download => '正在下载',
          _FakeDirection.both => '正在同步',
        },
        lastError: null,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final result =
        _nextResult ??
        SyncResult(
          outcome: SyncOutcome.noChanges,
          finishedAt: _clock().toUtc(),
          message: overwriteLocal
              ? '已用云端覆盖本机'
              : direction == _FakeDirection.upload
              ? '没有待上传的改动'
              : direction == _FakeDirection.download
              ? '云端没有新数据'
              : '已是最新',
        );
    _nextResult = null;
    if (result.conflicts > 0) {
      _emit(
        _status.copyWith(
          phase: SyncPhase.needsAttention,
          conflictCount: _conflicts.length + result.conflicts,
          message: '有 ${result.conflicts} 条冲突需要处理',
        ),
      );
    }
    return _finish(result, direction);
  }

  SyncResult _finish(SyncResult result, _FakeDirection direction) {
    final success = result.isSuccess;
    final unresolvedConflicts = result.outcome == SyncOutcome.conflict
        ? _conflicts.length + result.conflicts
        : _conflicts.length;
    final phase = success
        ? (unresolvedConflicts == 0 ? SyncPhase.idle : SyncPhase.needsAttention)
        : switch (result.outcome) {
            SyncOutcome.conflict => SyncPhase.needsAttention,
            SyncOutcome.offline => SyncPhase.offline,
            SyncOutcome.authRequired => SyncPhase.signedOut,
            SyncOutcome.bindingRequired => SyncPhase.needsAttention,
            SyncOutcome.error => SyncPhase.error,
            SyncOutcome.success || SyncOutcome.noChanges => SyncPhase.idle,
          };
    _emit(
      _status.copyWith(
        phase: phase,
        lastSyncedAt: success ? result.finishedAt : _status.lastSyncedAt,
        lastUploadedAt: success && direction != _FakeDirection.download
            ? result.finishedAt
            : _status.lastUploadedAt,
        lastDownloadedAt: success && direction != _FakeDirection.upload
            ? result.finishedAt
            : _status.lastDownloadedAt,
        pendingOperations: success && direction != _FakeDirection.download
            ? 0
            : _status.pendingOperations,
        conflictCount: unresolvedConflicts,
        lastError: success ? null : result.message,
        message: result.message,
      ),
    );
    return result;
  }

  @override
  Future<void> enableAutoUpload(bool enabled) async {
    _ensureOpen();
    _autoUpload = enabled;
    _emit(
      _status.copyWith(
        autoUploadEnabled: enabled,
        autoDownloadEnabled: _autoDownload,
      ),
    );
  }

  @override
  Future<void> enableAutoDownload(bool enabled) async {
    _ensureOpen();
    _autoDownload = enabled;
    _emit(
      _status.copyWith(
        autoUploadEnabled: _autoUpload,
        autoDownloadEnabled: enabled,
      ),
    );
  }

  @override
  Future<void> enableAutoSync(bool enabled) async {
    _ensureOpen();
    _autoUpload = enabled;
    _autoDownload = enabled;
    _emit(
      _status.copyWith(
        autoUploadEnabled: enabled,
        autoDownloadEnabled: enabled,
      ),
    );
  }

  bool get isAutoUploadEnabled => _autoUpload;
  bool get isAutoDownloadEnabled => _autoDownload;
  bool get isAutoSyncEnabled => _autoUpload || _autoDownload;

  @override
  Future<List<SyncConflict>> listConflicts() async {
    _ensureOpen();
    final list = _conflicts.values.toList()
      ..sort((a, b) => a.detectedAt.compareTo(b.detectedAt));
    return List<SyncConflict>.unmodifiable(list);
  }

  @override
  Future<SyncResult> resolveConflict(
    String conflictId,
    ConflictResolution resolution, {
    Map<String, Object?>? mergedPayload,
  }) async {
    _ensureOpen();
    resolveCalls++;
    final conflict = _conflicts[conflictId];
    if (conflict == null) {
      throw CloudException(CloudErrorKind.notFound, '冲突不存在或已处理：$conflictId');
    }
    if (resolution == ConflictResolution.manual && mergedPayload == null) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '手动合并必须提供 mergedPayload',
      );
    }
    _conflicts.remove(conflictId);
    _emit(
      _status.copyWith(
        phase: _conflicts.isEmpty ? SyncPhase.idle : SyncPhase.needsAttention,
        conflictCount: _conflicts.length,
        message: '冲突已处理',
      ),
    );
    return SyncResult(
      outcome: SyncOutcome.success,
      finishedAt: _clock().toUtc(),
      conflicts: 0,
      message: '冲突已处理',
    );
  }

  @override
  Future<BindingInspection> inspectBinding() async {
    _ensureOpen();
    if (_account == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录再检查数据归属');
    }
    if (_offline) {
      throw const CloudException(CloudErrorKind.network, '当前网络不可用');
    }
    return _bindingInspection;
  }

  @override
  Future<BindingResult> applyBinding(BindingChoice choice) async {
    _ensureOpen();
    lastBindingChoice = choice;
    if (choice == BindingChoice.uploadLocalToAccount &&
        !_bindingInspection.canUpload) {
      throw const CloudException(
        CloudErrorKind.conflict,
        '云端已有数据或本地已绑定其他账号，禁止自动上传',
      );
    }
    return const BindingResult(
      changed: false,
      requiresRestart: false,
      message: 'Fake 绑定操作已记录',
    );
  }

  // ---------------------------------------------------------------------------
  // 测试辅助
  // ---------------------------------------------------------------------------

  /// 直接推送一个状态，模拟自动同步/网络变化。
  void emitStatus(SyncStatus status) {
    _ensureOpen();
    _emit(status);
  }

  void seedConflict(SyncConflict conflict) {
    _ensureOpen();
    _conflicts[conflict.id] = conflict;
    _emit(
      _status.copyWith(
        conflictCount: _conflicts.length,
        phase: SyncPhase.needsAttention,
      ),
    );
  }

  void setBindingInspection(BindingInspection inspection) {
    _ensureOpen();
    _bindingInspection = inspection;
  }

  /// 下一次 `syncNow` 的结果；只生效一次。
  void setNextResult(SyncResult result) {
    _ensureOpen();
    _nextResult = result;
  }

  /// 下一次 `syncNow` 抛指定异常；只生效一次。
  void failNextSync(CloudException failure) {
    _ensureOpen();
    _nextFailure = failure;
  }

  void setOffline(bool offline) {
    _ensureOpen();
    _offline = offline;
    _emit(
      _status.copyWith(
        phase: offline ? SyncPhase.offline : SyncPhase.idle,
        message: offline ? '当前离线' : null,
      ),
    );
  }

  void setAccount(CloudAccount? account) {
    _ensureOpen();
    _account = account;
    _emit(
      _status.copyWith(
        account: account,
        phase: account == null ? SyncPhase.signedOut : SyncPhase.idle,
      ),
    );
  }

  void _emit(SyncStatus status) {
    _status = status;
    if (!_changes.isClosed) _changes.add(status);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('FakeSyncService 已关闭');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }
}

/// 一组已接好线的 Fake 服务，UI 测试可直接 `FakeCloudServices.demo()`。
final class FakeCloudServices {
  FakeCloudServices({
    FakeCloudAccountService? account,
    FakeSyncService? sync,
    CloudAccount? signedInAccount,
  }) : account = account ?? FakeCloudAccountService(account: signedInAccount),
       sync =
           sync ??
           FakeSyncService(
             account: signedInAccount ?? account?.currentAccount(),
           );

  final FakeCloudAccountService account;
  final FakeSyncService sync;

  CloudServices get services => CloudServices(account: account, sync: sync);

  Future<void> close() => services.close();
}
