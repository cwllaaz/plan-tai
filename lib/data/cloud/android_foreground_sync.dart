// ignore_for_file: prefer_initializing_formals

/// Android 首版「前台自动同步」驱动（不引入常驻服务/后台任务）。
///
/// 职责：把 Android 的生命周期与账号变化翻译成 [SyncService.syncNow] 调用，
/// 让下列时机得到一次同步尝试（对应任务要求的 §6）：
///
/// | 时机 | 实现 |
/// |---|---|
/// | 登录成功 / 会话恢复 / 软件启动 | 账号流出现非空账号后延迟一次（启动时 `restoreSession` 由控制器触发） |
/// | 从后台恢复前台 | `AppLifecycleState.resumed` |
/// | 本地保存任务后 | 同步引擎自身的 `database.localWrites` debounce（自动上传默认开启） |
/// | 网络恢复且存在待同步 | 离线态按 30s→5min 退避重试（引擎自动重试未启动时兜底） |
/// | 点击「立即同步」 | UI 直接调用控制器，不经过本类 |
///
/// 并发控制：同一时刻只发起一次；同步引擎内部对重复调用复用同一个 Future，
/// 保证不会有两路同时写本地库。进程被杀时待同步操作在 SQLite outbox 里，
/// 不依赖本类的内存状态，下次启动后照常上传。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/cloud/cloud_services.dart';
import '../../core/cloud/cloud_types.dart';

final class AndroidForegroundSync with WidgetsBindingObserver {
  AndroidForegroundSync({
    required CloudAccountService account,
    required SyncService sync,
    DateTime Function()? clock,
    this.registerLifecycleObserver = true,
    this.loginSyncDelay = const Duration(milliseconds: 1500),
    this.resumeThrottle = const Duration(seconds: 15),
    this.resumeStaleAfter = const Duration(minutes: 2),
    this.offlineRetryBase = const Duration(seconds: 30),
    this.offlineRetryMax = const Duration(minutes: 5),
    this.initialSyncDelay = const Duration(seconds: 2),
    this.minAttemptGap = const Duration(seconds: 8),
    this.maxOfflineRetries = 8,
  }) : _account = account,
       _sync = sync,
       _clock = clock ?? DateTime.now;

  final CloudAccountService _account;
  final SyncService _sync;
  final DateTime Function() _clock;

  /// 是否注册 [WidgetsBinding] 生命周期观察者（单元测试可关闭）。
  final bool registerLifecycleObserver;

  final Duration loginSyncDelay;
  final Duration resumeThrottle;
  final Duration resumeStaleAfter;
  final Duration offlineRetryBase;
  final Duration offlineRetryMax;
  final Duration initialSyncDelay;
  final Duration minAttemptGap;
  final int maxOfflineRetries;

  StreamSubscription<CloudAccount?>? _accountSubscription;
  StreamSubscription<SyncStatus>? _statusSubscription;

  Timer? _loginTimer;
  Timer? _initialSyncTimer;
  Timer? _offlineRetryTimer;
  int _offlineAttempt = 0;

  bool _attached = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _initialSyncRequested = false;
  bool _observingBinding = false;
  String? _accountOwnerId;
  DateTime? _lastAttemptAt;
  DateTime? _lastResumeAt;

  /// 前台触发同步的次数（诊断/测试用；不代表成功）。
  int foregroundSyncAttempts = 0;

  /// 最近一次触发来源：`login` / `initial` / `resumed` / `offline-retry`。
  String? lastTriggerReason;

  /// 挂载：订阅账号与状态流；可选注册生命周期观察者。
  void attach() {
    if (_attached) return;
    _attached = true;
    _accountSubscription = _account.observeAccount().listen(_onAccountChanged);
    _statusSubscription = _sync.observeSyncStatus().listen(_onStatusChanged);
    if (registerLifecycleObserver) _tryObserveBinding();
  }

  /// 注册生命周期观察者。
  ///
  /// 生产环境由 `runAndroidApp` 先 `ensureInitialized()`，这里必然成功；
  /// 纯 Dart 单元测试环境没有 WidgetsBinding，此时仅退化为"账号/状态触发"，
  /// 不能因为观察者注册失败就让整个云服务组装失败。
  void _tryObserveBinding() {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observingBinding = true;
    } on Object {
      _observingBinding = false;
    }
  }

  /// 卸载：可重复调用；关闭后不再发起任何同步。
  void detach() {
    if (_disposed) return;
    _disposed = true;
    _attached = false;
    _loginTimer?.cancel();
    _loginTimer = null;
    _initialSyncTimer?.cancel();
    _initialSyncTimer = null;
    _offlineRetryTimer?.cancel();
    _offlineRetryTimer = null;
    unawaited(_accountSubscription?.cancel() ?? Future<void>.value());
    _accountSubscription = null;
    unawaited(_statusSubscription?.cancel() ?? Future<void>.value());
    _statusSubscription = null;
    if (_observingBinding) {
      WidgetsBinding.instance.removeObserver(this);
      _observingBinding = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    handleLifecycleChanged(state);
  }

  /// 生命周期入口；测试可直接调用（不依赖真实 Flutter 绑定）。
  void handleLifecycleChanged(AppLifecycleState state) {
    if (_disposed) return;
    if (state != AppLifecycleState.resumed) return;
    final now = _clock().toUtc();
    final last = _lastResumeAt;
    if (last != null && now.difference(last) < resumeThrottle) return;
    _lastResumeAt = now;
    _offlineAttempt = 0;
    unawaited(_attempt(reason: 'resumed', allowWhenIdle: false));
  }

  // ---------------------------------------------------------------------------
  // 事件
  // ---------------------------------------------------------------------------

  void _onAccountChanged(CloudAccount? account) {
    if (_disposed) return;
    if (account == null) {
      _accountOwnerId = null;
      _initialSyncRequested = false;
      _loginTimer?.cancel();
      _loginTimer = null;
      return;
    }
    if (_accountOwnerId == account.ownerId) return;
    // 新登录 / 会话恢复：等控制器完成数据归属检查后再同步，避免抢跑。
    _accountOwnerId = account.ownerId;
    _initialSyncRequested = false;
    _loginTimer?.cancel();
    _loginTimer = Timer(loginSyncDelay, () {
      _loginTimer = null;
      unawaited(_attempt(reason: 'login', allowWhenIdle: true));
    });
  }

  void _onStatusChanged(SyncStatus status) {
    if (_disposed) return;
    if (status.phase == SyncPhase.offline) {
      _scheduleOfflineRetry();
      return;
    }
    _offlineAttempt = 0;
    _offlineRetryTimer?.cancel();
    _offlineRetryTimer = null;
    // 登录后第一次成功同步应由引擎启动自动同步定时器；若引擎尚未启动，
    // 这里补一次「从未同步」的初始尝试（例如云端为空时没有触发绑定同步）。
    if (status.phase == SyncPhase.idle &&
        status.lastSyncedAt == null &&
        !_initialSyncRequested &&
        _account.currentAccount() != null) {
      _initialSyncRequested = true;
      _initialSyncTimer?.cancel();
      _initialSyncTimer = Timer(initialSyncDelay, () {
        _initialSyncTimer = null;
        unawaited(_attempt(reason: 'initial', allowWhenIdle: true));
      });
    }
  }

  void _scheduleOfflineRetry() {
    if (_offlineRetryTimer != null) return;
    if (_offlineAttempt >= maxOfflineRetries) return;
    if (_account.currentAccount() == null) return;
    final delay = _backoff(_offlineAttempt);
    _offlineAttempt++;
    _offlineRetryTimer = Timer(delay, () {
      _offlineRetryTimer = null;
      unawaited(_attempt(reason: 'offline-retry', allowWhenIdle: true));
    });
  }

  Duration _backoff(int attempt) {
    final millis = offlineRetryBase.inMilliseconds * (1 << attempt.clamp(0, 8));
    final capped = millis > offlineRetryMax.inMilliseconds
        ? offlineRetryMax.inMilliseconds
        : millis;
    return Duration(milliseconds: capped);
  }

  // ---------------------------------------------------------------------------
  // 同步
  // ---------------------------------------------------------------------------

  /// 发起一次同步尝试。
  ///
  /// [allowWhenIdle] 为 false 时，只有「有待上传操作」或「距上次成功同步超过
  /// `resumeStaleAfter`」才会真的同步（避免每次切回前台都打一次网络请求）。
  Future<void> _attempt({
    required String reason,
    required bool allowWhenIdle,
  }) async {
    if (_disposed || _inFlight) return;
    if (_account.currentAccount() == null) return;
    final status = _sync.status;
    if (status.phase == SyncPhase.syncing) return;
    final now = _clock().toUtc();
    final last = _lastAttemptAt;
    if (last != null && now.difference(last) < minAttemptGap) return;
    if (!allowWhenIdle) {
      final pending = status.pendingOperations;
      final lastSyncedAt = status.lastSyncedAt;
      final stale =
          lastSyncedAt == null ||
          now.difference(lastSyncedAt) >= resumeStaleAfter;
      if (pending == 0 && !stale) return;
    }
    _inFlight = true;
    _lastAttemptAt = now;
    foregroundSyncAttempts++;
    lastTriggerReason = reason;
    try {
      await _sync.syncNow();
    } on Object {
      // SyncService 用 SyncResult 表达失败；这里只兜住实现层意外抛出的异常，
      // 不让一次自动尝试变成未捕获错误。
    } finally {
      _inFlight = false;
    }
  }
}

/// 给 [CloudServices] 套上「前台自动同步 + 关闭时自动卸载」的包装。
///
/// 组合根只需要调用本函数，不必知道生命周期细节；返回的同步服务在
/// `close()` 时会先卸载驱动再关闭真实引擎（避免关闭后仍被定时器唤醒）。
CloudServices attachAndroidForegroundSync(
  CloudServices services, {
  DateTime Function()? clock,
  bool registerLifecycleObserver = true,
}) {
  final driver = AndroidForegroundSync(
    account: services.account,
    sync: services.sync,
    clock: clock,
    registerLifecycleObserver: registerLifecycleObserver,
  );
  driver.attach();
  return CloudServices(
    account: services.account,
    sync: _ObservedSyncService(services.sync, driver),
  );
}

/// 纯委托包装：在 `close()` 时先卸载驱动。
final class _ObservedSyncService implements SyncService {
  _ObservedSyncService(this._inner, this._driver);

  final SyncService _inner;
  final AndroidForegroundSync _driver;

  @override
  Stream<SyncStatus> observeSyncStatus() => _inner.observeSyncStatus();

  @override
  SyncStatus get status => _inner.status;

  @override
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental}) =>
      _inner.syncNow(mode: mode);

  @override
  Future<SyncResult> uploadNow() => _inner.uploadNow();

  @override
  Future<SyncResult> downloadNow({
    SyncMode mode = SyncMode.incremental,
    bool overwriteLocal = false,
  }) => _inner.downloadNow(mode: mode, overwriteLocal: overwriteLocal);

  @override
  Future<void> enableAutoUpload(bool enabled) => _inner.enableAutoUpload(enabled);

  @override
  Future<void> enableAutoDownload(bool enabled) =>
      _inner.enableAutoDownload(enabled);

  @override
  Future<void> enableAutoSync(bool enabled) => _inner.enableAutoSync(enabled);

  @override
  Future<List<SyncConflict>> listConflicts() => _inner.listConflicts();

  @override
  Future<SyncResult> resolveConflict(
    String conflictId,
    ConflictResolution resolution, {
    Map<String, Object?>? mergedPayload,
  }) => _inner.resolveConflict(
    conflictId,
    resolution,
    mergedPayload: mergedPayload,
  );

  @override
  Future<BindingInspection> inspectBinding() => _inner.inspectBinding();

  @override
  Future<BindingResult> applyBinding(BindingChoice choice) =>
      _inner.applyBinding(choice);

  @override
  Future<void> close() async {
    _driver.detach();
    await _inner.close();
  }
}
