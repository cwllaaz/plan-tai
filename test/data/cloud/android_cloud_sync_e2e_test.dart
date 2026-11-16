/// Android ⇄ 云端 ⇄ Windows 跨端同步 E2E（FakePlannerServer + 真实同步引擎）。
///
/// 覆盖任务要求的跨端场景：
/// 1. Windows 上传 → Android 首次登录拉取（且不覆盖云端）
/// 2. Android 修改 → Windows 获取
/// 3. 两设备修改不同任务
/// 4. 两设备离线修改同一任务 → 冲突 → 解决
/// 5. 删除传播
/// 6. 断网本地继续 + 重启后待同步保留 + 联网补传
/// 7. 重复同步不产生重复数据
/// 8. Token 失效 → 重新登录
/// 9. 账号 A / B 数据隔离
/// 10. 明文 HTTP 拒绝、服务端协议版本检查
///
/// **注意**：服务端是 `FakePlannerServer`（实现了 `docs/sync/API_CONTRACT.md` 的
/// 客户端所需语义），不是真实 PocketBase。真实服务器 E2E 仍需在有服务器与
/// Android 真机时手工执行（见交付说明"未验证项"）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

import 'android_cloud_test_support.dart';
import 'fake_planner_server.dart';

const String _emailA = 'account-a@example.com';
const String _password = 'password-123456';
const String _ownerA = 'usr_account_a';
const String _emailB = 'account-b@example.com';
const String _ownerB = 'usr_account_b';

void main() {
  late FakePlannerServer server;

  setUp(() async {
    server = await FakePlannerServer.start();
    server.addAccount(email: _emailA, password: _password, ownerId: _ownerA);
    server.addAccount(email: _emailB, password: _password, ownerId: _ownerB);
  });

  tearDown(() async {
    await server.close();
  });

  Future<AndroidCloudTestDevice> newDevice() =>
      AndroidCloudTestDevice.open(server: server, tokenStore: RecordingTokenStore());

  /// Windows 端：本机已有数据 → 首次绑定「上传本机数据到账号」。
  Future<AndroidCloudTestDevice> boundDeviceWithSeedTask(String seedTitle) async {
    final device = await newDevice();
    await device.signIn(email: _emailA, password: _password);
    await device.addTask(seedTitle);
    final result = await device.services.sync.applyBinding(
      BindingChoice.uploadLocalToAccount,
    );
    expect(result.changed, isTrue);
    expect(result.requiresRestart, isFalse);
    return device;
  }

  /// Android 首次登录且云端已有数据 → 以云端为准建立账号工作区（需要重启）。
  Future<AndroidCloudTestDevice> androidFirstLoginDownload() async {
    final android = await newDevice();
    await android.signIn(email: _emailA, password: _password);
    final inspection = await android.services.sync.inspectBinding();
    expect(
      inspection.situation,
      BindingSituation.freshInstallCloudHasData,
      reason: 'Android 首次登录必须识别出"云端已有数据"，不能当成空库覆盖',
    );
    expect(inspection.cloudRecords, greaterThan(0));

    final binding = await android.services.sync.applyBinding(
      BindingChoice.useCloudAndArchiveLocal,
    );
    expect(binding.requiresRestart, isTrue);

    final accountDatabase = WorkspaceLayout(
      android.dataDirectory,
    ).accountDatabasePath(_ownerA);
    expect(File(accountDatabase).existsSync(), isTrue);

    final restarted = await android.restart(databasePath: accountDatabase);
    expect(await restarted.restoreSession(), isNotNull);
    final result = await restarted.services.sync.syncNow();
    expect(result.isSuccess, isTrue, reason: result.message ?? '首次全量下载失败');
    return restarted;
  }

  test('首次登录：Windows 数据下载到 Android，且云端数据不被清空/覆盖', () async {
    final windows = await boundDeviceWithSeedTask('Windows 端建的任务');
    expect(server.liveCount(_ownerA), 1);

    final android = await androidFirstLoginDownload();
    final tasks = await android.liveTasks();
    expect(tasks.map((task) => task.title), contains('Windows 端建的任务'));
    expect(server.liveCount(_ownerA), 1, reason: '下载不得删除或覆盖云端已有数据');

    await android.services.sync.syncNow();
    expect(server.liveCount(_ownerA), 1, reason: '重复同步不产生重复实体');

    await windows.dispose();
    await android.dispose();
  });

  test('Android 修改后上传，Windows 能获取', () async {
    final windows = await boundDeviceWithSeedTask('原始任务');
    final android = await androidFirstLoginDownload();
    final androidTask = (await android.liveTasks()).single;
    await android.renameTask(androidTask, 'Android 改过的标题');
    final push = await android.services.sync.syncNow();
    expect(push.isSuccess, isTrue);

    final pull = await windows.services.sync.syncNow();
    expect(pull.isSuccess, isTrue);
    final windowsTasks = await windows.liveTasks();
    expect(windowsTasks.map((task) => task.title), contains('Android 改过的标题'));

    await windows.dispose();
    await android.dispose();
  });

  test('Windows 修改后 Android 能获取', () async {
    final windows = await boundDeviceWithSeedTask('原始任务');
    final android = await androidFirstLoginDownload();
    final windowsTask = (await windows.liveTasks()).single;
    await windows.renameTask(windowsTask, 'Windows 改过的标题');
    await windows.services.sync.syncNow();

    final pull = await android.services.sync.syncNow();
    expect(pull.isSuccess, isTrue);
    expect(
      (await android.liveTasks()).map((task) => task.title),
      contains('Windows 改过的标题'),
    );

    await windows.dispose();
    await android.dispose();
  });

  test('两设备修改不同任务：互不覆盖，双向合并', () async {
    final windows = await boundDeviceWithSeedTask('初始任务');
    final android = await androidFirstLoginDownload();

    await windows.addTask('Windows 新任务');
    await android.addTask('Android 新任务');
    await windows.services.sync.syncNow();
    await android.services.sync.syncNow();
    await windows.services.sync.syncNow();
    await android.services.sync.syncNow();

    final windowsTitles = (await windows.liveTasks()).map((t) => t.title).toSet();
    final androidTitles = (await android.liveTasks()).map((t) => t.title).toSet();
    expect(windowsTitles, containsAll(<String>['Windows 新任务', 'Android 新任务']));
    expect(androidTitles, containsAll(<String>['Windows 新任务', 'Android 新任务']));

    await windows.dispose();
    await android.dispose();
  });

  test('两设备离线修改同一任务：识别冲突并可保留任一版本', () async {
    final windows = await boundDeviceWithSeedTask('同一任务');
    final android = await androidFirstLoginDownload();
    final windowsTask = (await windows.liveTasks()).single;
    final androidTask = (await android.liveTasks()).single;

    // 双方都在离线状态修改同一条记录。
    server.offline = true;
    await windows.renameTask(windowsTask, 'Windows 离线修改');
    final offlineResult = await windows.services.sync.syncNow();
    expect(offlineResult.outcome, SyncOutcome.offline);
    await android.renameTask(androidTask, 'Android 离线修改');
    final androidOffline = await android.services.sync.syncNow();
    expect(androidOffline.outcome, SyncOutcome.offline);

    // 恢复网络：Android 先上传，Windows 再上传就会撞版本。
    server.offline = false;
    final androidPush = await android.services.sync.syncNow();
    expect(androidPush.isSuccess, isTrue);
    final windowsPush = await windows.services.sync.syncNow();
    expect(windowsPush.outcome, SyncOutcome.conflict);
    final conflicts = await windows.services.sync.listConflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.entityId, windowsTask.id);
    expect(windows.services.sync.status.conflictCount, greaterThan(0));

    // 保留 Windows 本机版本 → 上传后 Android 也能看到。
    await windows.services.sync.resolveConflict(
      conflicts.single.id,
      ConflictResolution.keepLocal,
    );
    await windows.services.sync.syncNow();
    await android.services.sync.syncNow();
    expect(
      (await android.liveTasks()).map((t) => t.title),
      contains('Windows 离线修改'),
    );

    await windows.dispose();
    await android.dispose();
  });

  test('删除能传播：Windows 删除后 Android 记录消失', () async {
    final windows = await boundDeviceWithSeedTask('将被删除的任务');
    final android = await androidFirstLoginDownload();
    final windowsTask = (await windows.liveTasks()).single;

    await windows.repository.deleteTask(windowsTask.id);
    await windows.services.sync.syncNow();
    await android.services.sync.syncNow();

    expect(await android.repository.findTask(windowsTask.id), isNull);
    expect((await android.liveTasks()), isEmpty);
    expect(server.liveCount(_ownerA), 0);

    await windows.dispose();
    await android.dispose();
  });

  test('断网继续本地操作 + 重启后待同步保留 + 联网补传', () async {
    var device = await boundDeviceWithSeedTask('已有任务');
    server.offline = true;

    await device.addTask('断网时创建的任务');
    final offline = await device.services.sync.syncNow();
    expect(offline.outcome, SyncOutcome.offline);
    expect(device.services.sync.status.pendingOperations, greaterThan(0));

    // 模拟 Android 进程被杀后重新打开：数据目录与令牌存储不变。
    device = await device.restart();
    expect(await device.restoreSession(), isNotNull);
    expect(
      device.services.sync.status.pendingOperations,
      greaterThan(0),
      reason: '待同步操作必须持久化在 SQLite outbox，不依赖内存',
    );
    expect(
      (await device.liveTasks()).map((t) => t.title),
      contains('断网时创建的任务'),
    );

    server.offline = false;
    final retry = await device.services.sync.syncNow();
    expect(retry.isSuccess, isTrue);
    expect(retry.pushed, greaterThan(0));
    expect(device.services.sync.status.pendingOperations, 0);
    expect(server.liveCount(_ownerA), 2);

    await device.dispose();
  });

  test('重复同步幂等：不会产生重复数据，也不会重复计数', () async {
    final device = await boundDeviceWithSeedTask('幂等任务');
    final before = server.liveCount(_ownerA);

    final first = await device.services.sync.syncNow();
    expect(first.isSuccess, isTrue);
    expect(first.pushed, 0, reason: '已有改动在绑定时已上传');

    await device.addTask('再建一条');
    final second = await device.services.sync.syncNow();
    expect(second.pushed, 1);
    final third = await device.services.sync.syncNow();
    expect(third.pushed, 0);
    expect(server.liveCount(_ownerA), before + 1);
    expect((await device.liveTasks()).map((t) => t.title).toSet(), <String>{
      '幂等任务',
      '再建一条',
    });

    await device.dispose();
  });

  test('Token 失效：同步返回 authRequired，重新登录后可继续', () async {
    // 服务端把 token 有效期压到 2 秒：绑定完成后等待过期，再同步即触发 401。
    server.tokenTtlOverride = const Duration(seconds: 2);
    final device = await newDevice();
    await device.signIn(email: _emailA, password: _password);
    await device.addTask('失效前上传的任务');
    final binding = await device.services.sync.applyBinding(
      BindingChoice.uploadLocalToAccount,
    );
    expect(binding.changed, isTrue);
    expect(server.liveCount(_ownerA), 1);

    await Future<void>.delayed(const Duration(milliseconds: 2100));
    final expired = await device.services.sync.syncNow();
    expect(expired.outcome, SyncOutcome.authRequired);
    expect(device.services.sync.status.phase, SyncPhase.signedOut);
    expect(device.tokenStore.hasSession, isFalse, reason: '失效令牌必须清除');
    expect(
      (await device.liveTasks()).map((t) => t.title),
      contains('失效前上传的任务'),
      reason: '登录失效不能影响本地数据',
    );

    // 重新登录（服务端恢复正常 token 有效期）后可以继续同步。
    server.tokenTtlOverride = null;
    await device.signIn(email: _emailA, password: _password);
    final inspection = await device.services.sync.inspectBinding();
    expect(inspection.situation, BindingSituation.boundSameAccount);
    await device.addTask('重新登录后创建的任务');
    final result = await device.services.sync.syncNow();
    expect(result.isSuccess, isTrue);
    expect(server.liveCount(_ownerA), 2);

    await device.dispose();
  });

  test('登录状态恢复：重启后无需重新输入密码即可同步', () async {
    var device = await boundDeviceWithSeedTask('恢复会话任务');
    device = await device.restart();
    await device.restoreSession();
    expect(device.services.account.currentAccount()?.ownerId, _ownerA);
    final result = await device.services.sync.syncNow();
    expect(result.isSuccess, isTrue);
    await device.dispose();
  });

  test('账号 A / B 隔离：本机数据属于 A 时禁止上传给 B，B 看不到 A 的数据', () async {
    final device = await boundDeviceWithSeedTask('A 的机密任务');
    expect(server.liveCount(_ownerA), 1);
    final aWorkspace = device.databasePath;

    // 同一台设备切换账号：先退出 A，再登录 B。
    await device.services.account.logout();
    await device.signIn(email: _emailB, password: _password);
    final inspection = await device.services.sync.inspectBinding();
    expect(inspection.situation, BindingSituation.boundOtherAccount);
    expect(inspection.canUpload, isFalse);
    await expectLater(
      device.services.sync.applyBinding(BindingChoice.uploadLocalToAccount),
      throwsA(
        isA<CloudException>().having(
          (e) => e.kind,
          'kind',
          CloudErrorKind.conflict,
        ),
      ),
    );
    expect(server.liveCount(_ownerB), 0, reason: 'B 的云端不得出现 A 的数据');

    // B 建立自己的独立工作区 → 看不到 A 的任务。
    final binding = await device.services.sync.applyBinding(
      BindingChoice.keepLocalUnbound,
    );
    expect(binding.requiresRestart, isTrue);
    final bDatabase = WorkspaceLayout(
      device.dataDirectory,
    ).accountDatabasePath(_ownerB);
    expect(bDatabase, isNot(aWorkspace));
    final bDevice = await device.restart(databasePath: bDatabase);
    await bDevice.restoreSession();
    await bDevice.services.sync.syncNow();
    expect(await bDevice.liveTasks(), isEmpty);
    expect(server.liveCount(_ownerA), 1, reason: 'A 的云端数据必须原样保留');

    await bDevice.dispose();
  });

  test('明文 HTTP 服务器被拒绝（正式环境强制 HTTPS）', () async {
    final device = await newDevice();
    await expectLater(
      device.services.account.connectServer(Uri.parse('http://example.com')),
      throwsA(
        isA<CloudException>().having(
          (e) => e.kind,
          'kind',
          CloudErrorKind.protocol,
        ),
      ),
    );
    await device.dispose();
  });

  test('服务端协议版本不兼容时明确拒绝（版本检查）', () async {
    server.protocolVersionOverride = 2;
    final device = await newDevice();
    await expectLater(
      device.services.account.connectServer(server.baseUrl),
      throwsA(
        isA<CloudException>().having(
          (e) => e.kind,
          'kind',
          CloudErrorKind.protocol,
        ),
      ),
    );
    await device.dispose();
  });

  test('同步元数据：设备 ID 独立、ownerId 不混入他账号', () async {
    final deviceA = await boundDeviceWithSeedTask('设备元数据任务');
    final deviceB = await newDevice();
    await deviceB.signIn(email: _emailB, password: _password);
    expect(deviceA.repository.deviceId, isNot(deviceB.repository.deviceId));

    // A 的 session JSON 里 ownerId 只有 A。
    final sessionA = jsonDecode(
      deviceA.tokenStore.values['JihuaTai/cloud-session']!,
    ) as Map<String, Object?>;
    expect(sessionA['ownerId'], _ownerA);
    await deviceB.dispose();
    await deviceA.dispose();
  });

  test('本地数据库文件位于应用私有数据目录内（Android 路径规则）', () async {
    final device = await newDevice();
    final normalized = p.normalize(device.databasePath);
    expect(normalized, startsWith(p.normalize(device.dataDirectory)));
    await device.dispose();
  });
}
