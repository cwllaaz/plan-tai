import 'dart:io';

import '../../core/cloud/cloud_services.dart';
import '../sqlite_planner_repository.dart';
import '../sync/account_binding.dart';
import '../sync/sqlite_cloud_sync_service.dart';
import 'android_cloud_preferences.dart';
import 'android_foreground_sync.dart';
import 'android_secure_token_store.dart';
import 'planner_api.dart';
import 'pocketbase_account_service.dart';
import 'secure_token_store.dart';

/// Android 云端账号 / 同步的组装入口（**接口已冻结**，由 数据层 实现）。
///
/// 为什么单独一个文件：Android 的安全令牌存储实现（Keystore）与桌面端的
/// Windows 凭据管理器完全不同，但上层同步引擎、HTTP 客户端、冲突处理应当
/// 100% 复用。这里只负责「换一个 [SecureTokenStore] 并把服务装起来」，
/// **不含**任何第二套 HTTP 客户端、同步引擎或冲突模型。
///
/// 组装内容与桌面 `lib/main.dart` 的 `_tryBuildCloudServices` 一一对应：
///
/// ```
/// AndroidSecureTokenStore（Keystore 通道）
///   → PocketBaseAccountService（账号 + 凭据）
///   → PlannerApi（协议客户端）
///   → SqliteCloudSyncService（同一 repository / 同一 SQLite）
///   → CloudServices（+ 前台自动同步驱动）
/// ```
///
/// 行为约定：
/// - 返回 null 表示本轮不启用云（应用退化为纯本地离线，**不得**用明文文件
///   或内存 token 代替安全存储）；
/// - 令牌只经 [SecureTokenStore]；日志只写结论，不含 token / 密码 / 响应体；
/// - 首次运行默认开启自动上传 + 自动下载（前台自动同步），用户在同步界面
///   关闭后不再被重置（记录在 `<data>/android_cloud.json`）；
/// - 同步状态、绑定流程、冲突处理全部由现有引擎提供，本文件不做业务判断。
///
/// [tokenStore] 与 [enableForegroundSync] 是为测试与集成预留的**向后兼容扩展**
/// （默认值与生产一致）；组合根调用时只传冻结签名里的两个必填参数。
Future<CloudServices?> createAndroidCloudServices({
  required SqlitePlannerRepository repository,
  required String dataDirectory,
  SecureTokenStore? tokenStore,
  bool enableForegroundSync = true,
  DateTime Function()? clock,
}) async {
  final store = tokenStore ?? AndroidSecureTokenStore();
  PocketBaseAccountService? account;
  SqliteCloudSyncService? sync;
  try {
    // 1) 先确认安全存储可用：不可用就不要假装"能登录"，直接离线。
    if (store is AndroidSecureTokenStore) {
      final available = await store.probe();
      if (!available) {
        final reason = store.unavailableReason;
        stderr.writeln(
          'Android 安全存储不可用，云端账号功能已关闭（本地功能正常）：'
          '${reason?.message ?? '未知原因'}',
        );
        return null;
      }
    } else if (!store.isAvailable) {
      stderr.writeln('注入的令牌存储不可用，云端账号功能已关闭（本地功能正常）');
      return null;
    }

    // 2) 账号服务与协议客户端（与桌面完全相同的实现）。
    account = PocketBaseAccountService(tokenStore: store);
    final api = PlannerApi();

    // 3) 同步引擎绑定同一个 SQLite 库与同一数据目录（账号工作区规则一致）。
    sync = SqliteCloudSyncService(
      repository: repository,
      account: account,
      credentials: account,
      api: api,
      layout: WorkspaceLayout(dataDirectory),
      clock: clock,
      autoStart: true,
    );

    // 4) 首次运行默认开启自动同步（前台策略）；用户的选择会被持久化，
    //    重启后保持，不会因默认策略被反复覆盖。
    try {
      final preferences = AndroidCloudPreferences(dataDirectory);
      await preferences.load();
      if (!preferences.autoSyncConfigured) {
        await sync.enableAutoSync(true);
        await preferences.markAutoSyncConfigured();
      }
    } on Object catch (error) {
      // 偏好文件失败不影响同步能力：退回只读状态继续。
      stderr.writeln('Android 云端偏好初始化失败（不影响同步）：$error');
    }

    final services = CloudServices(account: account, sync: sync);
    if (!enableForegroundSync) return services;
    return attachAndroidForegroundSync(
      services,
      clock: clock,
      registerLifecycleObserver: true,
    );
  } on Object catch (error, stack) {
    // 只写本地日志；绝不把 token 写进去。失败时保持本地功能可用。
    stderr.writeln('Android 云服务组装失败，已降级为离线模式：$error');
    stderr.writeln(stack);
    await sync?.close();
    await account?.close();
    return null;
  }
}
