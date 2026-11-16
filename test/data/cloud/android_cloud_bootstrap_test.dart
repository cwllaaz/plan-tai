/// `createAndroidCloudServices` 组装入口测试。
///
/// 覆盖：安全存储缺失/不可用 → 离线(null)、正常组装、默认自动同步策略的持久化、
/// 未登录安全降级、登录后 token 只进安全存储、服务器不可达、重启恢复会话。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/cloud/android_cloud_bootstrap.dart';
import 'package:jihuatai/data/cloud/android_cloud_preferences.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

import 'android_cloud_test_support.dart';
import 'fake_planner_server.dart';

void main() {
  late Directory root;
  late String dataDirectory;
  late SqlitePlannerRepository repository;
  late FakePlannerServer server;

  String databasePath() => p.join(dataDirectory, 'app.db');

  setUp(() async {
    root = Directory.systemTemp.createTempSync('jihuatai_android_boot_');
    dataDirectory = p.join(root.path, 'data');
    Directory(dataDirectory).createSync(recursive: true);
    repository = SqlitePlannerRepository.open(databasePath: databasePath());
    server = await FakePlannerServer.start();
    server.addAccount(
      email: 'android@example.com',
      password: 'password-123456',
      ownerId: 'usr_android',
      name: '安卓测试账号',
    );
  });

  tearDown(() async {
    await repository.close();
    await server.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<CloudServices?> create(
    SecureTokenStore store, {
    bool enableForegroundSync = false,
  }) => createAndroidCloudServices(
    repository: repository,
    dataDirectory: dataDirectory,
    tokenStore: store,
    enableForegroundSync: enableForegroundSync,
  );

  test('正常组装：返回可用的账号 + 同步服务，并默认开启自动同步', () async {
    final store = RecordingTokenStore();
    final services = await create(store);
    expect(services, isNotNull);
    expect(services!.account.currentAccount(), isNull);
    expect(services.sync.status.autoUploadEnabled, isTrue);
    expect(services.sync.status.autoDownloadEnabled, isTrue);

    final preferences = AndroidCloudPreferences(dataDirectory);
    await preferences.load();
    expect(preferences.autoSyncConfigured, isTrue);

    await services.close();
  });

  test('用户关闭自动同步后重启不被默认策略重置', () async {
    final store = RecordingTokenStore();
    final first = await create(store);
    await first!.sync.enableAutoSync(false);
    expect(first.sync.status.autoSyncEnabled, isFalse);
    await first.close();

    final second = await create(store);
    expect(second, isNotNull);
    expect(
      second!.sync.status.autoSyncEnabled,
      isFalse,
      reason: '已有"已配置"标记时不再套用默认开启策略',
    );
    await second.close();
  });

  test('安全存储不可用（如注入实现报告不可用）时返回 null，不伪造登录', () async {
    final store = RecordingTokenStore(available: false);
    final services = await create(store);
    expect(services, isNull);
  });

  test('未登录时同步返回 authRequired（不抛裸异常），本地数据仍可用', () async {
    final services = await create(RecordingTokenStore());
    final result = await services!.sync.syncNow();
    expect(result.outcome, SyncOutcome.authRequired);

    await expectLater(
      services.sync.inspectBinding(),
      throwsA(
        isA<CloudException>().having(
          (CloudException e) => e.kind,
          'kind',
          CloudErrorKind.unauthorized,
        ),
      ),
    );

    final task = await repository.createTask(
      const PlannerTaskDraft(title: '离线也能建任务'),
    );
    expect(task.title, '离线也能建任务');
    await services.close();
  });

  test('登录成功后 token 只进安全存储，不写数据库/普通配置', () async {
    final store = RecordingTokenStore();
    final services = await create(store);
    await services!.account.connectServer(server.baseUrl);
    final account = await services.account.login(
      username: 'android@example.com',
      password: 'password-123456',
    );
    expect(account.ownerId, 'usr_android');
    expect(store.hasSession, isTrue, reason: '会话必须写入 SecureTokenStore');

    final sessionJson = store.values['JihuaTai/cloud-session']!;
    final token = (jsonDecode(sessionJson) as Map<String, Object?>)['token']! as String;
    expect(token, isNotEmpty);

    // 数据库文件中不得出现 token。
    final databaseBytes = File(repository.database.path!).readAsBytesSync();
    final databaseText = String.fromCharCodes(databaseBytes);
    expect(databaseText, isNot(contains(token)));
    expect(databaseText, isNot(contains('password-123456')));

    // 数据目录里的普通 JSON（除安全存储本身）同样不得出现 token。
    for (final entity in Directory(dataDirectory).listSync(recursive: true)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.db') || entity.path.endsWith('.db-wal')) continue;
      final text = String.fromCharCodes(entity.readAsBytesSync());
      expect(text, isNot(contains(token)), reason: '${entity.path} 不应包含 token');
      expect(text, isNot(contains('password-123456')));
    }
    await services.close();
  });

  test('密码错误时登录失败，且不会写入令牌', () async {
    final store = RecordingTokenStore();
    final services = await create(store);
    await services!.account.connectServer(server.baseUrl);
    await expectLater(
      services.account.login(
        username: 'android@example.com',
        password: 'wrong-password',
      ),
      throwsA(
        isA<CloudException>().having(
          (CloudException e) => e.kind,
          'kind',
          CloudErrorKind.unauthorized,
        ),
      ),
    );
    expect(store.hasSession, isFalse);
    await services.close();
  });

  test('服务器不可达：登录抛 CloudException，服务对象仍可离线使用', () async {
    final deadServer = await FakePlannerServer.start();
    final deadUrl = deadServer.baseUrl;
    await deadServer.close();

    final services = await create(RecordingTokenStore());
    await expectLater(
      services!.account.connectServer(deadUrl),
      throwsA(isA<CloudException>()),
    );
    final result = await services.sync.syncNow();
    expect(result.outcome, SyncOutcome.authRequired);
    await services.close();
  });

  test('应用重启后从安全存储恢复会话（同一账号 / 同一服务器）', () async {
    final store = RecordingTokenStore();
    final first = await create(store);
    await first!.account.connectServer(server.baseUrl);
    final signedIn = await first.account.login(
      username: 'android@example.com',
      password: 'password-123456',
    );
    await first.close();

    // 模拟重启：新 repository + 新服务实例 + 同一安全存储。
    await repository.close();
    repository = SqlitePlannerRepository.open(databasePath: databasePath());
    final second = await create(store);
    final restored = await second!.account.restoreSession();
    expect(restored, isNotNull);
    expect(restored!.ownerId, signedIn.ownerId);
    expect(restored.serverUrl, signedIn.serverUrl);
    await second.close();
  });

  test('前台同步包装可正常关闭（组合根 enableForegroundSync=true）', () async {
    final services = await createAndroidCloudServices(
      repository: repository,
      dataDirectory: dataDirectory,
      tokenStore: RecordingTokenStore(),
      enableForegroundSync: true,
    );
    expect(services, isNotNull);
    await services!.close();
    expect(services.sync.status.phase, SyncPhase.signedOut);
  });

  test('默认开启的自动同步开关可被用户关闭并立即反映到状态', () async {
    final services = await create(RecordingTokenStore());
    expect(services!.sync.status.autoSyncEnabled, isTrue);
    await services.sync.enableAutoSync(false);
    expect(services.sync.status.autoSyncEnabled, isFalse);
    expect(services.sync.status.autoUploadEnabled, isFalse);
    expect(services.sync.status.autoDownloadEnabled, isFalse);
    await services.close();
  });

  test('AndroidCloudPreferences 与数据目录同级，不落到别处', () async {
    final preferences = AndroidCloudPreferences(dataDirectory);
    await create(RecordingTokenStore()).then((services) => services!.close());
    await preferences.load();
    expect(preferences.filePath, p.join(dataDirectory, 'android_cloud.json'));
    expect(File(preferences.filePath).existsSync(), isTrue);
  });

  test('MemoryTokenStore 注入同样可以组装（供上层集成测试使用）', () async {
    final services = await create(MemoryTokenStore());
    expect(services, isNotNull);
    await services!.close();
  });
}
