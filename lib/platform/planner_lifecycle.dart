import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'android_database_host.dart';
import 'android_memory_channel.dart';

/// Android 应用生命周期 × 本地数据库的守护器。
///
/// Android 的前提与 Windows 不同：**进程随时可能被系统回收**，且没有「关窗退出」
/// 这一刻可以依赖。因此这里把数据安全收敛成三条可验证的规则：
///
/// | 时机 | 动作 | 原因 |
/// |---|---|---|
/// | `hidden`（不再可见） | WAL `PASSIVE` checkpoint | 绝大多数「切后台」都先经过它，代价最小 |
/// | `paused`（进入后台 / 锁屏） | WAL `TRUNCATE` checkpoint | 把 WAL 合入主库并截断，进程随后被杀也不丢已提交事务 |
/// | `detached` | 同上（尽力而为） | 引擎分离前的最后机会 |
/// | `resumed`（回到前台） | `SELECT 1` 健康检查 + 补取原生内存事件 | 连接若已不可用要尽早暴露，而不是等用户点开某页才炸 |
/// | 系统内存压力 | `PRAGMA shrink_memory` + `PRAGMA optimize` | 释放 SQLite 页缓存/WAL 索引；**不关闭文件连接**（见下） |
///
/// 为什么低内存时不关闭连接：连接被 `SqlitePlannerRepository` 持有并被界面流监听，
/// 关闭会让正在展示的页面立刻 `StateError`。真正「释放连接」由系统回收进程完成，
/// 下次冷启动由 [AndroidDatabaseHost.open] 重新打开并做完整性检查——这条路径由
/// `test/platform/android_database_host_test.dart` 的「异常退出」用例覆盖。
/// 因此这里的低内存处理是「释放内存缓存 + 之后查询自动重建缓存」。
///
/// 说明：横竖屏 / 字体缩放 / 深色模式切换已在 `AndroidManifest.xml` 里声明为
/// `configChanges` 自处理，Activity 不会重建，数据库连接与界面状态都保留。
final class PlannerLifecycleGuard with WidgetsBindingObserver {
  PlannerLifecycleGuard._({
    required this.host,
    required this.memoryChannel,
    required this.binding,
  });

  static PlannerLifecycleGuard? _active;

  /// 当前已安装的守护器（未安装为 null）。
  static PlannerLifecycleGuard? get active => _active;

  /// 被守护的存储目标（正式运行时是 [AndroidDatabaseHost]）。
  final PlannerStorageLifecycleTarget host;

  /// 原生内存压力通道。
  final AndroidMemoryPressureChannel memoryChannel;

  /// 用于注册/注销生命周期观察者的绑定。
  final WidgetsBinding binding;

  StreamSubscription<int>? _memorySubscription;

  bool _disposed = false;

  // 诊断计数器（设置页/测试可读）。
  int checkpoints = 0;
  int memoryReleases = 0;
  int healthChecks = 0;
  int healthFailures = 0;
  int nativeMemoryEvents = 0;

  AppLifecycleState? lastLifecycleState;
  DateTime? lastCheckpointAt;
  DateTime? lastMemoryReleaseAt;
  String? lastError;

  bool get isDisposed => _disposed;

  /// 安装守护器（幂等：已安装则返回现有实例）。
  ///
  /// 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用（组合根在 `main`
  /// 里已经保证）。[binding] / [memoryChannel] 仅供测试注入。
  static PlannerLifecycleGuard install({
    required PlannerStorageLifecycleTarget host,
    WidgetsBinding? binding,
    AndroidMemoryPressureChannel? memoryChannel,
  }) {
    final existing = _active;
    if (existing != null) {
      if (!existing._disposed && identical(existing.host, host)) return existing;
      // 组合根被再次执行（Activity 重建 / 工作区切换）时，旧守护器绑的是已关闭的
      // 数据库宿主，必须先解绑再装新的，避免 checkpoint 打到一个死连接上。
      unawaited(existing.dispose());
    }

    final resolvedBinding = binding ?? WidgetsBinding.instance;
    final channel = memoryChannel ?? AndroidMemoryPressureChannel();
    final guard = PlannerLifecycleGuard._(
      host: host,
      memoryChannel: channel,
      binding: resolvedBinding,
    );

    resolvedBinding.addObserver(guard);
    channel.start();
    guard._memorySubscription = channel.events.listen(guard._onNativeMemoryEvent);
    _active = guard;

    // 冷启动/热重启后先做一次健康检查，覆盖「上次进程被回收、本次连接是新建的」。
    guard._checkHealth();
    guard._drainNativeEvents();
    return guard;
  }

  /// 卸载守护器（测试与「切换账号工作区后重启」流程用；生产环境随进程结束自然消失）。
  static Future<void> uninstall() async {
    final active = _active;
    _active = null;
    if (active != null) await active.dispose();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    binding.removeObserver(this);
    await _memorySubscription?.cancel();
    _memorySubscription = null;
    await memoryChannel.dispose();
  }

  // -------------------------------------------------------------------------
  // WidgetsBindingObserver
  // -------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lastLifecycleState = state;
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _checkHealth();
        _drainNativeEvents();
      case AppLifecycleState.inactive:
        // 来电、下拉通知栏、应用切换器预览等瞬时状态：不做磁盘 I/O，避免卡顿。
        break;
      case AppLifecycleState.hidden:
        _checkpoint(truncate: false, reason: 'hidden');
      case AppLifecycleState.paused:
        // 进入后台 / 锁屏：这是最可靠的「可能被杀」信号。
        _checkpoint(truncate: true, reason: 'paused');
        _releaseMemory('paused', truncate: false);
      case AppLifecycleState.detached:
        _checkpoint(truncate: true, reason: 'detached');
    }
  }

  @override
  void didHaveMemoryPressure() {
    _releaseMemory('flutter.didHaveMemoryPressure');
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  void _onNativeMemoryEvent(int level) {
    nativeMemoryEvents++;
    if (_disposed) return;
    final background =
        lastLifecycleState == AppLifecycleState.paused ||
        lastLifecycleState == AppLifecycleState.hidden ||
        lastLifecycleState == AppLifecycleState.detached;
    // Level 80 = TRIM_MEMORY_COMPLETE（后台进程即将被杀）；先落盘再释放内存。
    final critical = level >= 80;
    _releaseMemory('native.trimMemory($level)', truncate: background || critical);
  }

  void _checkpoint({required bool truncate, required String reason}) {
    if (_disposed || !host.isOpen) return;
    try {
      if (host.checkpoint(truncate: truncate)) {
        checkpoints++;
        lastCheckpointAt = DateTime.now().toUtc();
      } else {
        _recordError('$reason checkpoint 未成功');
      }
    } on Object catch (error) {
      _recordError('$reason checkpoint 异常：$error');
    }
  }

  void _releaseMemory(String reason, {bool truncate = false}) {
    if (_disposed || !host.isOpen) return;
    try {
      if (truncate) host.checkpoint(truncate: true);
      if (host.releaseMemory()) {
        memoryReleases++;
        lastMemoryReleaseAt = DateTime.now().toUtc();
      } else {
        _recordError('$reason 释放内存失败');
      }
    } on Object catch (error) {
      _recordError('$reason 释放内存异常：$error');
    }
  }

  void _checkHealth() {
    if (_disposed) return;
    healthChecks++;
    if (!host.isOpen) {
      healthFailures++;
      _recordError('恢复前台时本地数据库连接已关闭');
      return;
    }
    if (!host.verifyAlive()) {
      healthFailures++;
      _recordError('恢复前台时本地数据库连接不可用');
    }
  }

  void _drainNativeEvents() {
    unawaited(
      memoryChannel.drain().then((levels) {
        for (final level in levels) {
          _onNativeMemoryEvent(level);
        }
      }),
    );
  }

  void _recordError(String message) {
    lastError = message;
    stderr.writeln('[PlannerLifecycleGuard] $message');
  }

  /// 供设置页/诊断展示的一行摘要。
  String describe() =>
      '生命周期守护：checkpoint $checkpoints 次，释放内存 $memoryReleases 次，'
      '健康检查 $healthChecks 次（失败 $healthFailures），'
      '原生内存事件 $nativeMemoryEvents 次，最近状态 ${lastLifecycleState?.name ?? '未知'}';
}
