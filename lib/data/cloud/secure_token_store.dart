/// 安全令牌存储契约。
///
/// 生产实现是 [WindowsCredentialStore]（Windows 凭据管理器 / DPAPI）；
/// 测试使用 [MemoryTokenStore]。禁止把 token 写进 SQLite、普通 JSON 配置或日志。
library;

import 'dart:async';

abstract interface class SecureTokenStore {
  bool get isAvailable;

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 纯内存实现，只用于测试。
final class MemoryTokenStore implements SecureTokenStore {
  final Map<String, String> _values = <String, String>{};

  @override
  bool get isAvailable => true;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
