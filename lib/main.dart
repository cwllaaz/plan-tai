import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/cloud_ui_preferences.dart';
import 'app/cloud_workspace.dart';
import 'app/startup_failure_app.dart';
import 'bootstrap/android_bootstrap.dart';
import 'core/testing/testing.dart';
import 'data/data.dart';
import 'features/cloud_account/cloud_account.dart';

/// 计划台入口。
///
/// **Android**：交给 [runAndroidApp]（应用私有目录 → 本地 SQLite → 移动 UI；
/// 云端账号在安全存储就绪后接入）。桌面端逻辑完全不变。
///
/// **正式模式（桌面，默认）**：打开 `%APPDATA%\计划台\data\app.db`，首次启动自动建库；
/// 如果用户此前选择“以云端为准”，则打开 `<data>/accounts/<ownerId>/app.db`。
/// **演示模式**：设置环境变量 `JIHUATAI_DEMO=1`，使用内存数据并在侧栏明确标注，
/// 且完全不初始化云服务，保证断网/无账号时也能完整使用本地功能。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 移动端与桌面端共用业务层，但启动组装不同：目录必须异步解析、
  // 窗口管理器不可用、界面是触屏布局。Android 之下不会执行任何桌面代码。
  if (Platform.isAndroid) {
    await runAndroidApp();
    return;
  }

  // 窗口初始化是原生能力的“锦上添花”：Linux 上窗口后端是编译出来的 native
  // library（window_manager → nativeapi），加载失败不能拖垮本地日历启动。
  try {
    _configureNativeWindow();
  } on Object catch (error) {
    stderr.writeln('窗口初始化失败，使用系统默认窗口：$error');
  }

  final demoMode =
      (Platform.environment['JIHUATAI_DEMO'] ?? '').trim() == '1';
  if (demoMode) {
    final repository = InMemoryPlannerRepository();
    await seedDemoData(repository);
    runApp(PlannerApp(repository: repository, isDemoData: true));
    return;
  }

  try {
    final dataDirectory = PlannerPaths.defaultDataDirectory();
    final workspace = CloudWorkspaceStore(dataDirectory);
    final databasePath =
        workspace.activeDatabasePath() ?? PlannerPaths.defaultDatabasePath();
    final repository = SqlitePlannerRepository.open(
      databasePath: databasePath,
    );

    final cloud = _tryBuildCloudServices(
      repository: repository,
      dataDirectory: dataDirectory,
    );

    runApp(
      PlannerApp(
        repository: repository,
        isDemoData: false,
        databasePath: repository.database.path,
        cloudServices: cloud?.services,
        cloudController: cloud?.controller,
        dataDirectory: dataDirectory,
      ),
    );
  } on LocalDatabaseException catch (error) {
    runApp(StartupFailureApp(message: error.message));
  } on Object catch (error) {
    runApp(StartupFailureApp(message: '无法打开本地数据库：$error'));
  }
}

/// 组装真实云服务：账号（系统安全存储）+ 同步引擎 + UI 控制器。
///
/// 任何一步失败都不应该阻止本地日历启动：捕获异常后返回 null，
/// 应用退化为纯离线模式（顶栏显示“演示模式不连接云端”），本地数据不受影响。
({CloudServices services, CloudAccountController controller})?
_tryBuildCloudServices({
  required SqlitePlannerRepository repository,
  required String dataDirectory,
}) {
  try {
    final tokenStore = createPlatformTokenStore();
    if (!tokenStore.isAvailable) {
      // 没有安全令牌存储时不再装配云服务（与 Android bootstrap 的契约一致）：
      // 宁可云入口不出现，也不让用户在“输入密码后才失败”或让 token 落明文。
      stderr.writeln('安全令牌存储不可用（${Platform.operatingSystem}），云同步降级为离线模式。');
      return null;
    }
    final account = PocketBaseAccountService(tokenStore: tokenStore);
    final api = PlannerApi();
    final sync = SqliteCloudSyncService(
      repository: repository,
      account: account,
      credentials: account,
      api: api,
      layout: WorkspaceLayout(dataDirectory),
      autoStart: true,
    );
    final services = CloudServices(account: account, sync: sync);
    final controller = CloudAccountController(
      services: services,
      preferences: FileCloudUiPreferences(dataDirectory),
    );
    return (services: services, controller: controller);
  } on Object catch (error, stack) {
    // 只记录本地日志，绝不把 token 写进去；失败时保持离线可用。
    stderr.writeln('云同步初始化失败，已降级为离线模式：$error');
    stderr.writeln(stack);
    return null;
  }
}

/// 原生窗口：1440×900 居中，最小 1100×700（月历 7 列 + 420 抽屉的最小可用宽度）。
///
/// 只在桌面平台调用；Android 在 [main] 里就已转交 [runAndroidApp]，不会到这里。
void _configureNativeWindow() {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
  final window = WindowManager.instance.getCurrent();
  if (window == null) return;
  window
    ..title = '计划台 · 项目与日程'
    ..minimumSize = const Size(1100, 700).toNative()
    ..setSize(const Size(1440, 900).toNative(), false)
    ..center()
    ..show()
    ..focus();
}
