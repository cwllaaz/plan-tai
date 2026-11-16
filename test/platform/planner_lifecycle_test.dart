import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/platform/platform.dart';
import 'package:material_ui/material_ui.dart' show AppLifecycleState, WidgetsBinding;

import 'support/platform_test_support.dart';

/// 记录调用次数的假存储目标（真正实现是 AndroidDatabaseHost）。
final class _FakeTarget implements PlannerStorageLifecycleTarget {
  bool open = true;
  bool alive = true;

  int checkpointCalls = 0;
  int releaseCalls = 0;
  int healthCalls = 0;
  final List<bool> truncateFlags = <bool>[];

  @override
  bool get isOpen => open;

  @override
  bool checkpoint({bool truncate = true}) {
    checkpointCalls++;
    truncateFlags.add(truncate);
    return true;
  }

  @override
  bool releaseMemory() {
    releaseCalls++;
    return true;
  }

  @override
  bool verifyAlive() {
    healthCalls++;
    return alive;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTarget target;
  late MockChannel memoryMock;

  setUp(() {
    target = _FakeTarget();
    memoryMock = MockChannel(AndroidMemoryPressureChannel.channelName)
      ..install();
    memoryMock.handler = (MethodCall call) async =>
        call.method == 'drainEvents' ? const <Object?>[] : null;
  });

  tearDown(() async {
    await PlannerLifecycleGuard.uninstall();
    memoryMock.uninstall();
  });

  PlannerLifecycleGuard installGuard(
    _FakeTarget target, {
    AndroidMemoryPressureChannel? channel,
  }) => PlannerLifecycleGuard.install(
    host: target,
    binding: WidgetsBinding.instance,
    memoryChannel: channel ?? AndroidMemoryPressureChannel(),
  );

  group('PlannerLifecycleGuard 生命周期动作', () {
    test('安装时做一次健康检查，并把守护器登记为单例', () {
      final guard = installGuard(target);

      expect(target.healthCalls, 1);
      expect(PlannerLifecycleGuard.active, same(guard));
      expect(guard.lastLifecycleState, isNull);
    });

    test('进入后台 / 锁屏（paused）：WAL TRUNCATE checkpoint + 释放内存', () {
      final guard = installGuard(target);

      guard.didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(target.truncateFlags, <bool>[true]);
      expect(target.releaseCalls, 1);
      expect(guard.lastLifecycleState, AppLifecycleState.paused);
      expect(guard.checkpoints, 1);
    });

    test('不可见（hidden）：被动 checkpoint（代价更小）', () {
      final guard = installGuard(target);

      guard.didChangeAppLifecycleState(AppLifecycleState.hidden);

      expect(target.truncateFlags, <bool>[false]);
    });

    test('引擎分离（detached）：尽力做一次 TRUNCATE checkpoint', () {
      final guard = installGuard(target);

      guard.didChangeAppLifecycleState(AppLifecycleState.detached);

      expect(target.truncateFlags, <bool>[true]);
    });

    test('瞬时状态（inactive）不做磁盘 I/O，避免来电/下拉通知栏卡顿', () {
      final guard = installGuard(target);

      guard.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(target.checkpointCalls, 0);
      expect(target.releaseCalls, 0);
    });

    test('回到前台（resumed）：健康检查 + 补取原生事件', () async {
      final guard = installGuard(target);

      guard.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(target.healthCalls, 2); // 安装 1 次 + resumed 1 次
      expect(guard.healthChecks, 2);
      expect(guard.healthFailures, 0);
    });

    test('连接不可用时不崩溃，只记录失败并继续运行', () {
      target.open = false;
      final guard = installGuard(target);

      guard.didChangeAppLifecycleState(AppLifecycleState.paused);
      guard.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(target.checkpointCalls, 0);
      expect(guard.healthFailures, greaterThanOrEqualTo(2));
      expect(guard.lastError, isNotNull);
    });

    test('系统内存压力：释放 SQLite 内存缓存', () {
      final guard = installGuard(target);

      guard.didHaveMemoryPressure();

      expect(target.releaseCalls, 1);
      expect(guard.memoryReleases, 1);
      expect(guard.lastMemoryReleaseAt, isNotNull);
    });

    test('原生内存事件（含安装后补取的缓冲事件）逐个处理', () async {
      var drainCalls = 0;
      memoryMock.handler = (MethodCall call) async {
        if (call.method != 'drainEvents') return null;
        drainCalls++;
        return drainCalls == 1 ? const <Object?>[10, 80] : const <Object?>[];
      };

      final guard = installGuard(target);
      await pumpEventQueue();

      expect(guard.nativeMemoryEvents, 2);
      expect(target.releaseCalls, 2);
      // 后台/临界事件前会先落盘。
      expect(target.truncateFlags, isNotEmpty);
    });
  });

  group('PlannerLifecycleGuard 安装/卸载', () {
    test('重复安装同一宿主返回同一实例', () {
      final first = installGuard(target);
      final second = installGuard(target);

      expect(identical(first, second), isTrue);
    });

    test('宿主变化时解绑旧守护器并安装新的（Activity 重建场景）', () {
      final first = installGuard(target);
      final nextTarget = _FakeTarget();
      final second = installGuard(nextTarget);

      expect(identical(first, second), isFalse);
      expect(first.isDisposed, isTrue);
      expect(second.host, same(nextTarget));
      expect(PlannerLifecycleGuard.active, same(second));
    });

    test('卸载后不再响应生命周期变化', () async {
      final guard = installGuard(target);
      await PlannerLifecycleGuard.uninstall();

      guard.didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(target.checkpointCalls, 0);
      expect(PlannerLifecycleGuard.active, isNull);
    });

    test('describe() 汇总可读的诊断信息', () {
      final guard = installGuard(target);
      guard.didChangeAppLifecycleState(AppLifecycleState.paused);
      guard.didHaveMemoryPressure();

      final description = guard.describe();
      expect(description, contains('checkpoint 1 次'));
      expect(description, contains('paused'));
    });
  });
}
