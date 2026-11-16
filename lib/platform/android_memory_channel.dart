import 'dart:async';

import 'package:flutter/services.dart';

/// 原生「内存压力」事件通道（`com.jihuatai.planner/memory`）。
///
/// 原生侧：`MainActivity.onTrimMemory` / `onLowMemory` 记录事件，并尽力即时
/// `invokeMethod('onTrimMemory', level)`；Dart 侧没准备好时事件会留在原生缓冲区，
/// 由 [drain] 在应用回到前台时一次性取走，保证不丢关键的低内存信号。
///
/// 通道名与原生常量 `MainActivity.MEMORY_CHANNEL` 必须一致。
final class AndroidMemoryPressureChannel {
  AndroidMemoryPressureChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// 与 `MainActivity.companion.MEMORY_CHANNEL` 保持一致。
  static const String channelName = 'com.jihuatai.planner/memory';

  final MethodChannel _channel;
  final StreamController<int> _events = StreamController<int>.broadcast();

  bool _started = false;
  bool _disposed = false;

  /// 原生推送的内存压力级别（`ComponentCallbacks2.TRIM_MEMORY_*`）。
  Stream<int> get events => _events.stream;

  /// 注册推送处理器（幂等）。
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// 取走原生缓冲区里尚未送达的事件（应用恢复前台时调用）。
  Future<List<int>> drain() async {
    if (_disposed) return const <int>[];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('drainEvents');
      if (raw == null) return const <int>[];
      return raw.whereType<int>().toList(growable: false);
    } on MissingPluginException {
      // 非 Android 平台 / 原生未注册：静默降级。
      return const <int>[];
    } on PlatformException {
      return const <int>[];
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _channel.setMethodCallHandler(null);
      _started = false;
    }
    await _events.close();
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method != 'onTrimMemory') return null;
    final level = call.arguments;
    if (level is int && !_events.isClosed) {
      _events.add(level);
    }
    return null;
  }
}
