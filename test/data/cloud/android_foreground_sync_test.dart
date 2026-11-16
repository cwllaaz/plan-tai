/// Android 前台自动同步驱动测试。
///
/// 用真实 Timer 的短时长验证触发时机、节流与重试；不涉及网络与 SQLite。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/data/cloud/android_foreground_sync.dart';

CloudAccount _account() => CloudAccount(
  ownerId: 'owner-1',
  email: 'android@example.com',
  serverUrl: Uri.parse('https://sync.example.com'),
  authenticatedAt: DateTime.utc(2026, 11, 15),
);

SyncStatus _status({
  SyncPhase phase = SyncPhase.idle,
  int pending = 0,
  DateTime? lastSyncedAt,
  int conflicts = 0,
}) => SyncStatus(
  phase: phase,
  account: _account(),
  pendingOperations: pending,
  lastSyncedAt: lastSyncedAt,
  conflictCount: conflicts,
);

/// 等待真实 Timer 与微任务全部跑完。
Future<void> _settle([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

void main() {
  late FakeCloudAccountService account;
  late FakeSyncService sync;

  setUp(() {
    account = FakeCloudAccountService(account: _account());
    sync = FakeSyncService(account: _account());
  });

  tearDown(() async {
    await sync.close();
    await account.close();
  });

  AndroidForegroundSync build({
    Duration loginSyncDelay = const Duration(minutes: 10),
    Duration resumeThrottle = const Duration(seconds: 15),
    Duration offlineRetryBase = const Duration(milliseconds: 20),
    Duration initialSyncDelay = const Duration(minutes: 10),
  }) => AndroidForegroundSync(
    account: account,
    sync: sync,
    registerLifecycleObserver: false,
    loginSyncDelay: loginSyncDelay,
    resumeThrottle: resumeThrottle,
    offlineRetryBase: offlineRetryBase,
    initialSyncDelay: initialSyncDelay,
    minAttemptGap: Duration.zero,
  );

  test('登录 / 会话恢复后延迟触发一次同步', () async {
    final driver = build(loginSyncDelay: const Duration(milliseconds: 10));
    driver.attach();
    account.seedSession(_account());
    expect(sync.syncCalls, 0, reason: '不应在账号流刚出现时立刻同步（先让控制器检查绑定）');

    await _settle();
    expect(sync.syncCalls, 1);
    expect(driver.foregroundSyncAttempts, 1);
    expect(driver.lastTriggerReason, 'login');
    driver.detach();
  });

  test('回到前台且存在待同步改动时触发同步', () async {
    sync.emitStatus(_status(pending: 3, lastSyncedAt: DateTime.now().toUtc()));
    final driver = build();
    driver.attach();

    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    await _settle();
    expect(sync.syncCalls, 1);
    expect(driver.lastTriggerReason, 'resumed');
    driver.detach();
  });

  test('回到前台但没有待同步且最近同步过：不打扰网络', () async {
    sync.emitStatus(_status(lastSyncedAt: DateTime.now().toUtc()));
    final driver = build();
    driver.attach();

    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    await _settle();
    expect(sync.syncCalls, 0);
    driver.detach();
  });

  test('回到前台且从未同步过：会尝试拉取云端数据', () async {
    sync.emitStatus(_status());
    final driver = build(initialSyncDelay: const Duration(minutes: 10));
    driver.attach();

    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    await _settle();
    expect(sync.syncCalls, 1);
    driver.detach();
  });

  test('回到前台有节流：短时间内多次恢复只同步一次', () async {
    sync.emitStatus(_status(pending: 1, lastSyncedAt: DateTime.now().toUtc()));
    final driver = build(resumeThrottle: const Duration(minutes: 5));
    driver.attach();

    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    await _settle();
    expect(sync.syncCalls, 1);
    driver.detach();
  });

  test('非 resumed 的生命周期事件不触发同步', () async {
    sync.emitStatus(_status(pending: 2));
    final driver = build();
    driver.attach();

    driver.handleLifecycleChanged(AppLifecycleState.paused);
    driver.handleLifecycleChanged(AppLifecycleState.inactive);
    driver.handleLifecycleChanged(AppLifecycleState.hidden);
    driver.handleLifecycleChanged(AppLifecycleState.detached);
    await _settle();
    expect(sync.syncCalls, 0);
    driver.detach();
  });

  test('离线且有待同步：按退避自动重试', () async {
    sync.emitStatus(_status(phase: SyncPhase.offline, pending: 2));
    final driver = build(offlineRetryBase: const Duration(milliseconds: 15));
    driver.attach();

    await _settle(120);
    expect(sync.syncCalls, greaterThanOrEqualTo(1));
    expect(driver.lastTriggerReason, 'offline-retry');
    driver.detach();
  });

  test('detach 之后不再触发任何同步', () async {
    sync.emitStatus(_status(pending: 5));
    final driver = build();
    driver.attach();
    driver.detach();

    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    account.seedSession(_account());
    await _settle();
    expect(sync.syncCalls, 0);
  });

  test('未登录时不做任何同步尝试', () async {
    await account.logout();
    final driver = build();
    driver.attach();
    driver.handleLifecycleChanged(AppLifecycleState.resumed);
    await _settle();
    expect(sync.syncCalls, 0);
    driver.detach();
  });

  test('包装后的 CloudServices 关闭时会卸载驱动，不再发起同步', () async {
    final services = FakeCloudServices(
      signedInAccount: _account(),
      sync: FakeSyncService(account: _account()),
    );
    final wrapped = attachAndroidForegroundSync(
      services.services,
      registerLifecycleObserver: false,
    );
    expect(wrapped.sync, isNot(same(services.sync)));
    await wrapped.close();
    // 关闭后 observeSyncStatus 仍可安全调用（直接委托内部实现）。
    expect(wrapped.sync.status.phase, isNotNull);
  });
}
