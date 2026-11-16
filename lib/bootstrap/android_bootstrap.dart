import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../app/cloud_ui_preferences.dart';
import '../app/startup_failure_app.dart';
import '../data/cloud/android_cloud_bootstrap.dart';
import '../data/data.dart';
import '../features/cloud_account/cloud_account.dart';
import '../mobile/mobile_app.dart';
import '../platform/android_database_host.dart';
import '../platform/planner_lifecycle.dart';

/// Android 启动组装（组合根，由维护者维护）。
///
/// 顺序固定：应用私有目录 → 本地 SQLite → 云服务（可选）→ 移动 UI。
/// 任何一步失败都不能静默退出，也不能删除/重建用户数据：
/// 数据库问题走 [StartupFailureApp]；云初始化失败只降级为离线。
///
/// 桌面端的等价组装在 `lib/main.dart` 的 `_tryBuildCloudServices`，两边共用
/// 同一套仓储、数据库、同步引擎与账号工作区规则。
Future<void> runAndroidApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // 1) 应用私有目录 + 本地数据库：统一由平台适配层负责（私有目录注入、
    //    账号工作区指针、同进程幂等打开、落盘自检）。见 lib/platform/android_database_host.dart。
    final host = await AndroidDatabaseHost.open();

    // 2) 生命周期守护：后台/锁屏 checkpoint、回前台健康检查、低内存释放缓存。
    //    必须在 runApp 之前安装，才能覆盖首帧前的状态变化。
    PlannerLifecycleGuard.install(host: host);

    final repository = host.repository;
    final dataDirectory = host.dataDirectory;

    CloudServices? services;
    CloudAccountController? controller;
    try {
      services = await createAndroidCloudServices(
        repository: repository,
        dataDirectory: dataDirectory,
      );
      if (services != null) {
        controller = CloudAccountController(
          services: services,
          preferences: FileCloudUiPreferences(dataDirectory),
        );
      }
    } on Object catch (error, stack) {
      // 只写本地日志；绝不把 token 写进去。失败时保持本地功能可用。
      stderr.writeln('Android 云同步初始化失败，已降级为离线模式：$error');
      stderr.writeln(stack);
      unawaited(services?.close() ?? Future<void>.value());
      services = null;
      controller = null;
    }

    runApp(
      MobileApp(
        repository: repository,
        databasePath: repository.database.path,
        dataDirectory: dataDirectory,
        cloudServices: services,
        cloudController: controller,
      ),
    );
  } on LocalDatabaseException catch (error) {
    runApp(StartupFailureApp(message: error.message));
  } on Object catch (error) {
    runApp(StartupFailureApp(message: '无法启动计划台 Android 版：$error'));
  }
}
