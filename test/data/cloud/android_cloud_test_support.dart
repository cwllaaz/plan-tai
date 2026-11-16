/// Android 云端测试支撑：用真实 `createAndroidCloudServices` 组装、真实 SQLite、
/// 真实同步引擎与 FakePlannerServer 模拟「一台 Android 设备 / 一台 Windows 设备」。
///
/// 为什么不用 FakeSyncService：跨端同步、离线队列、冲突、删除传播必须在**真实
/// 引擎 + 真实 HTTP 协议**上验证，否则测不到 outbox/游标/版本对账这些关键逻辑。
library;

import 'dart:io';

import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/cloud/android_cloud_bootstrap.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

import 'fake_planner_server.dart';

/// 可观察的令牌存储：测试用，模拟 Android Keystore 的持久化域。
///
/// 每个「设备」一份；模拟应用重启时复用同一实例，等价于 Keystore 在应用重启
/// 后仍然保存着登录令牌（Android 真实行为）。
final class RecordingTokenStore implements SecureTokenStore {
  RecordingTokenStore({this.available = true});

  bool available;

  final Map<String, String> values = <String, String>{};
  int writeCount = 0;
  int readCount = 0;
  int deleteCount = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<String?> read(String key) async {
    readCount++;
    if (!available) throw const CloudException(CloudErrorKind.unknown, '不可用');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    if (!available) throw const CloudException(CloudErrorKind.unknown, '不可用');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCount++;
    values.remove(key);
  }

  /// 是否保存了会话（只暴露"有没有"，不暴露 token 内容）。
  bool get hasSession => values.keys.any((key) => key.contains('cloud-session'));
}

/// 一台运行 Android 云的客户端设备（真实组装 + 真实同步引擎）。
final class AndroidCloudTestDevice {
  AndroidCloudTestDevice._({
    required this.server,
    required this.root,
    required this.dataDirectory,
    required this.repository,
    required this.services,
    required this.tokenStore,
  });

  final FakePlannerServer server;
  final Directory root;
  final String dataDirectory;
  final SqlitePlannerRepository repository;
  final CloudServices services;
  final RecordingTokenStore tokenStore;

  String get databasePath => repository.database.path!;

  /// 新建一台「设备」：按组合根的顺序打开数据库并组装云服务。
  static Future<AndroidCloudTestDevice> open({
    required FakePlannerServer server,
    required RecordingTokenStore tokenStore,
    Directory? root,
    String? databasePath,
    String? dataDirectory,
  }) async {
    final deviceRoot = root ?? Directory.systemTemp.createTempSync('jihuatai_android_');
    final dataDir = dataDirectory ?? p.join(deviceRoot.path, 'data');
    Directory(dataDir).createSync(recursive: true);
    final dbPath = databasePath ?? p.join(dataDir, 'app.db');
    Directory(p.dirname(dbPath)).createSync(recursive: true);

    final repository = SqlitePlannerRepository.open(databasePath: dbPath);
    final services = await createAndroidCloudServices(
      repository: repository,
      dataDirectory: dataDir,
      tokenStore: tokenStore,
      enableForegroundSync: false,
    );
    if (services == null) {
      await repository.close();
      throw StateError('测试环境：createAndroidCloudServices 返回了 null');
    }
    // 测试里全部显式同步，关闭自动同步避免定时器干扰断言。
    await services.sync.enableAutoSync(false);

    return AndroidCloudTestDevice._(
      server: server,
      root: deviceRoot,
      dataDirectory: dataDir,
      repository: repository,
      services: services,
      tokenStore: tokenStore,
    );
  }

  /// 模拟应用重启：关闭当前 SQLite 与云服务，用同一个数据目录与令牌存储重开。
  Future<AndroidCloudTestDevice> restart({String? databasePath}) async {
    final nextDbPath = databasePath ?? this.databasePath;
    await services.close();
    await repository.close();
    return AndroidCloudTestDevice.open(
      server: server,
      tokenStore: tokenStore,
      root: root,
      dataDirectory: dataDirectory,
      databasePath: nextDbPath,
    );
  }

  Future<CloudAccount> signIn({required String email, required String password}) async {
    await services.account.connectServer(server.baseUrl);
    return services.account.login(username: email, password: password);
  }

  /// 恢复已保存的会话（等价于应用启动时控制器 `initialize()` 的恢复步骤）。
  Future<CloudAccount?> restoreSession() => services.account.restoreSession();

  Future<PlannerTask> addTask(
    String title, {
    LocalDate? scheduledDate,
    String? projectId,
  }) {
    return repository.createTask(
      PlannerTaskDraft(
        title: title,
        scheduledDate: scheduledDate ?? LocalDate(2026, 11, 16),
        projectId: projectId,
      ),
    );
  }

  Future<PlannerTask> renameTask(PlannerTask task, String title) =>
      repository.updateTask(task.copyWith(title: title));

  Future<List<PlannerTask>> liveTasks() => repository.watchAllTasks().first;

  Future<void> dispose({bool deleteRoot = true}) async {
    await services.close();
    await repository.close();
    if (deleteRoot && root.existsSync()) root.deleteSync(recursive: true);
  }
}
