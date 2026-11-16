/// 云服务层统一出口（每日面板模块）。
///
/// UI 只依赖 `lib/core/cloud/cloud_services.dart` 的接口；
/// 应用装配层（Agent D）用本文件构造真实实现：
///
/// ```dart
/// final account = PocketBaseAccountService(
///   tokenStore: WindowsCredentialStore(),
/// );
/// final sync = SqliteCloudSyncService(
///   repository: repository,
///   account: account,
///   credentials: account,
///   api: PlannerApi(),
/// );
/// ```
library;

export 'cloud_credentials.dart';
export 'http_json.dart';
export 'linux_credential_store.dart';
export 'planner_api.dart';
export 'platform_token_store.dart';
export 'pocketbase_account_service.dart';
export 'secure_token_store.dart';
export 'windows_credential_store.dart';
