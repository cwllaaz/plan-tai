/// 同步引擎获取凭据的内部接口（不属于冻结的公共契约）。
///
/// 公共 `CloudAccountService` 只暴露"账号是谁"，不暴露 token（避免 token 泄漏到
/// UI 层）。真实实现 `PocketBaseAccountService` 同时实现本接口，同步服务通过它
/// 取 token、在 401 时刷新一次。测试可以注入自己的 Fake。
library;

import '../../core/cloud/cloud_types.dart';

abstract interface class CloudCredentialsProvider {
  /// 当前已登录账号；未登录为 null。
  CloudAccount? currentAccount();

  /// 服务器地址；未连接/未登录时抛 [CloudException]。
  Uri get baseUrl;

  /// 取一个可用的 Bearer token；过期时先刷新。
  Future<String> requireToken();

  /// 收到 401 后强制刷新一次；失败时清空会话并抛 unauthorized。
  Future<String> refreshToken();
}
