/// 界面层的轻量配置（**不保存任何密钥**）。
///
/// 目前只有一项：上次成功连接过的服务器地址，方便用户下次少填一次。
/// 密码、token 一律不写这里；token 由 `CloudAccountService` 的实现自己保管。
///
/// 为什么只有内存实现：数据层 的文件边界禁止 `dart:io` 与数据层 import，
/// 因此「落盘」交给 Agent D 注入一个 [CloudUiPreferences] 实现（可用数据层的
/// JSON/prefs 持久化）。默认的 [MemoryCloudUiPreferences] 只保证当前进程内可用，
/// 供测试、演示和 D 尚未注入时使用。
abstract interface class CloudUiPreferences {
  Future<String?> readServerAddress();

  Future<void> writeServerAddress(String? address);
}

/// 进程内配置，仅用于测试、演示与尚未注入持久化实现的场景。
final class MemoryCloudUiPreferences implements CloudUiPreferences {
  String? _serverAddress;

  @override
  Future<String?> readServerAddress() async => _serverAddress;

  @override
  Future<void> writeServerAddress(String? address) async {
    final text = address?.trim() ?? '';
    _serverAddress = text.isEmpty ? null : text;
  }
}
