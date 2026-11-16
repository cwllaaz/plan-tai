/// 同步引擎测试环境：临时 SQLite + Fake HTTP Server + 真实认证/同步实现。
library;

import 'dart:io';

import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

import '../../cloud/fake_planner_server.dart';

final class SyncTestEnv {
  SyncTestEnv._({
    required this.directory,
    required this.database,
    required this.repository,
    required this.server,
    required this.accountService,
    required this.account,
    required this.sync,
  });

  final Directory directory;
  final PlannerDatabase database;
  final SqlitePlannerRepository repository;
  final FakePlannerServer server;
  final PocketBaseAccountService accountService;
  final CloudAccount account;
  final SqliteCloudSyncService sync;

  String get databasePath => database.path!;

  static Future<SyncTestEnv> create({
    FakePlannerServer? server,
    bool bind = true,
    bool addAccount = true,
    String ownerId = 'usr_test_owner',
    String email = 'sync-test@example.com',
    String password = 'password-123456',
    Duration debounce = const Duration(milliseconds: 30),
    DateTime Function()? clock,
    String Function()? idGenerator,
  }) async {
    final fake = server ?? await FakePlannerServer.start();
    if (addAccount) {
      fake.addAccount(
        email: email,
        password: password,
        ownerId: ownerId,
        name: '测试账号',
      );
    }
    final directory = Directory.systemTemp.createTempSync('jihuatai_sync_');
    final dbPath = p.join(directory.path, 'app.db');
    final database = PlannerDatabase.open(path: dbPath);
    final repository = SqlitePlannerRepository(
      database,
      clock: clock,
      idGenerator: idGenerator,
    );

    final accountService = PocketBaseAccountService(
      tokenStore: MemoryTokenStore(),
      clock: clock,
    );
    await accountService.connectServer(fake.baseUrl);
    final account = await accountService.login(
      username: email,
      password: password,
    );

    if (bind) {
      AccountBindingStore(
        WorkspaceLayout.bindingPathForDatabase(dbPath),
      ).write(
        WorkspaceBinding(
          ownerId: account.ownerId,
          email: account.email,
          displayName: account.displayName,
          serverUrl: account.serverUrl.toString(),
          boundAt: DateTime.now().toUtc(),
          state: BindingState.bound,
        ),
      );
    }

    final sync = SqliteCloudSyncService(
      repository: repository,
      account: accountService,
      credentials: accountService,
      api: PlannerApi(),
      clock: clock,
      debounce: debounce,
      startupDelay: const Duration(milliseconds: 20),
      periodicInterval: const Duration(seconds: 30),
      autoStart: false,
    );

    return SyncTestEnv._(
      directory: directory,
      database: database,
      repository: repository,
      server: fake,
      accountService: accountService,
      account: account,
      sync: sync,
    );
  }

  /// 关闭并删除临时目录；服务端由创建方负责关闭。
  Future<void> dispose() async {
    await sync.close();
    await repository.close();
    await accountService.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
