/// 安全令牌存储的平台工厂。
///
/// 装配层只调用 [createPlatformTokenStore]，不再硬编码 Windows 实现：
/// - Windows → [WindowsCredentialStore]（凭据管理器 / DPAPI）；
/// - Linux   → [LinuxCredentialStore]（Secret Service / libsecret `secret-tool`）；
/// - 其它平台 → [UnsupportedTokenStore]（明确不可用，云入口不装配）。
///
/// 契约：不可用时必须让上层“不注入云服务”，而不是退回明文存储。
library;

import 'dart:io';

import '../../core/cloud/cloud_types.dart';
import 'linux_credential_store.dart';
import 'secure_token_store.dart';
import 'windows_credential_store.dart';

/// 按当前平台构造安全令牌存储。
SecureTokenStore createPlatformTokenStore() {
  if (Platform.isWindows) return WindowsCredentialStore();
  if (Platform.isLinux) return LinuxCredentialStore();
  return const UnsupportedTokenStore();
}

/// 没有安全存储实现的平台：任何读写都明确失败，绝不落明文。
final class UnsupportedTokenStore implements SecureTokenStore {
  const UnsupportedTokenStore();

  @override
  bool get isAvailable => false;

  @override
  Future<String?> read(String key) async => throw _unsupported();

  @override
  Future<void> write(String key, String value) async => throw _unsupported();

  @override
  Future<void> delete(String key) async => throw _unsupported();

  CloudException _unsupported() => const CloudException(
    CloudErrorKind.unknown,
    '当前平台没有可用的安全令牌存储，云同步不可用；本地功能不受影响。',
  );
}
