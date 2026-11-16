/// Android 安全令牌存储（Dart 侧，接口见 [SecureTokenStore]）。
///
/// 实现方式：**冻结的平台通道**（`docs/android/MODULE_CONTRACT.md` §9.2）
///
/// ```
/// MethodChannel('com.jihuatai.planner/secure_store')
///   Future<String?> read(String key)                    // 无值返回 null
///   Future<void>    write(String key, String value)
///   Future<void>    delete(String key)
///   Future<bool>    isAvailable()
/// ```
///
/// 原生侧由 每日面板模块 用 Android Keystore（AES-256-GCM）+ 应用私有
/// `SharedPreferences` 实现；Dart 侧只做编码、大小校验与错误归一化。
///
/// 安全约束：
/// - **绝不**降级为明文文件 / SharedPreferences / 内存存储；
/// - 所有失败统一抛 [CloudException]，异常 message 不包含 token 内容；
/// - key 命名与 Windows 实现保持一致：调用方传 `JihuaTai/cloud-session` 这类
///   业务 key，本类再补 `JihuaTai/` 命名空间（与 `WindowsCredentialStore` 的
///   `targetPrefix` 语义相同），原生侧按收到的完整 key 落盘。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/cloud/cloud_types.dart';
import 'secure_token_store.dart';

/// 基于 Android Keystore 平台通道的令牌存储。
final class AndroidSecureTokenStore implements SecureTokenStore {
  AndroidSecureTokenStore({
    MethodChannel? channel,
    this.keyPrefix = defaultKeyPrefix,
    this.maxValueBytes = defaultMaxValueBytes,
    this.timeout = const Duration(seconds: 15),
  }) : _channel = channel ?? const MethodChannel(channelName);

  /// 与原生侧约定的通道名（**冻结**，不得改动）。
  static const String channelName = 'com.jihuatai.planner/secure_store';

  /// 与 Windows 凭据管理器一致的命名空间前缀。
  static const String defaultKeyPrefix = 'JihuaTai';

  /// 单条令牌上限（与原生侧约定 ≤ 8KB）。
  static const int defaultMaxValueBytes = 8 * 1024;

  final MethodChannel _channel;
  final String keyPrefix;
  final int maxValueBytes;
  final Duration timeout;

  bool _available = false;
  bool _probed = false;
  CloudException? _unavailable;

  @override
  bool get isAvailable => _available;

  /// 原生通道不可用时的原因（供组合根写日志，不含敏感信息）。
  CloudException? get unavailableReason => _unavailable;

  /// 探测原生通道是否可用；幂等，可重复调用。
  ///
  /// `isAvailable` 是同步 getter，但通道调用是异步的，因此组合根必须先
  /// `await probe()` 再交给账号服务使用。
  Future<bool> probe() async {
    if (_probed) return _available;
    _probed = true;
    try {
      final result = await _invoke<bool>('isAvailable', const <String, Object?>{});
      _available = result == true;
      if (!_available) {
        _unavailable = const CloudException(
          CloudErrorKind.unknown,
          '设备安全存储不可用：原生 Keystore 通道报告 isAvailable=false',
        );
      }
    } on CloudException catch (error) {
      _available = false;
      _unavailable = error;
    }
    return _available;
  }

  @override
  Future<String?> read(String key) async {
    _ensureAvailable();
    final value = await _invoke<Object?>('read', <String, Object?>{
      'key': _nativeKey(key),
    });
    if (value == null) return null;
    if (value is String) return value;
    throw const CloudException(
      CloudErrorKind.protocol,
      '安全存储返回了非文本内容，已拒绝使用',
    );
  }

  @override
  Future<void> write(String key, String value) async {
    _ensureAvailable();
    final size = utf8.encode(value).length;
    if (size > maxValueBytes) {
      throw CloudException(
        CloudErrorKind.protocol,
        '登录信息过大（$size 字节，上限 $maxValueBytes），无法写入安全存储',
      );
    }
    await _invoke<Object?>('write', <String, Object?>{
      'key': _nativeKey(key),
      'value': value,
    });
  }

  @override
  Future<void> delete(String key) async {
    _ensureAvailable();
    await _invoke<Object?>('delete', <String, Object?>{'key': _nativeKey(key)});
  }

  String _nativeKey(String key) {
    // 原生侧（`SecureStorePlugin.kt`）负责把收到的 key 存成 `JihuaTai/<key>`；
    // 冻结的账号服务传入的 key 已经带命名空间（`JihuaTai/cloud-session`），
    // 这里去掉重复的那一层，保证最终存储名恰好是 `JihuaTai/cloud-session`
    // （MODULE_CONTRACT §9.2 的命名约定），避免落成 `JihuaTai/JihuaTai/...`。
    if (key.startsWith('$keyPrefix/')) {
      return key.substring(keyPrefix.length + 1);
    }
    return key;
  }

  void _ensureAvailable() {
    if (!_available) {
      throw _unavailable ??
          const CloudException(
            CloudErrorKind.unknown,
            '设备安全存储不可用，无法保存或读取登录令牌',
          );
    }
  }

  /// 统一调用通道并把底层异常翻译成 [CloudException]。
  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments).timeout(timeout);
    } on TimeoutException {
      throw const CloudException(
        CloudErrorKind.timeout,
        '系统安全存储响应超时，请重试',
        retryable: true,
      );
    } on MissingPluginException {
      throw const CloudException(
        CloudErrorKind.unknown,
        '当前安装包未提供 Android 安全存储原生实现，无法保存登录令牌',
      );
    } on PlatformException catch (error) {
      throw CloudException(
        CloudErrorKind.unknown,
        '系统安全存储操作失败（${error.code}）',
        retryable: false,
        cause: error,
      );
    }
  }
}
