import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';

void main() {
  final clock = DateTime.utc(2026, 11, 15, 6, 0, 0);

  group('FakeCloudAccountService', () {
    test('连接必须 https（localhost 例外），握手声明同步能力', () async {
      final service = FakeCloudAccountService(clock: () => clock);
      addTearDown(service.close);

      await expectLater(
        service.connectServer(Uri.parse('http://example.com')),
        throwsA(
          isA<CloudException>().having(
            (error) => error.kind,
            'kind',
            CloudErrorKind.protocol,
          ),
        ),
      );

      final handshake = await service.connectServer(
        Uri.parse('https://planner.example.com'),
      );
      expect(handshake.supportsSync, isTrue);
      expect(handshake.protocolVersion, 1);

      final local = await service.connectServer(
        Uri.parse('http://localhost:8090'),
      );
      expect(local.baseUrl.host, 'localhost');
    });

    test('登录成功/失败、账号流与退出登录', () async {
      final service = FakeCloudAccountService(clock: () => clock);
      addTearDown(service.close);
      await service.connectServer(Uri.parse('https://planner.example.com'));

      final emitted = <CloudAccount?>[];
      final subscription = service.observeAccount().listen(emitted.add);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, <CloudAccount?>[null]);

      await expectLater(
        service.login(username: 'demo@example.com', password: 'wrong'),
        throwsA(
          isA<CloudException>().having(
            (error) => error.kind,
            'kind',
            CloudErrorKind.unauthorized,
          ),
        ),
      );

      final account = await service.login(
        username: 'demo@example.com',
        password: 'demo1234',
      );
      expect(account.ownerId, 'fake-owner-demo@example.com');
      expect(service.currentAccount(), account);
      await Future<void>.delayed(Duration.zero);
      expect(emitted.last, account);

      await service.logout();
      expect(service.currentAccount(), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(emitted.last, isNull);
      await subscription.cancel();
    });

    test('restoreSession 只恢复已保存的会话', () async {
      final service = FakeCloudAccountService(clock: () => clock);
      addTearDown(service.close);
      expect(await service.restoreSession(), isNull);

      final account = CloudAccount(
        ownerId: 'owner-1',
        email: 'a@example.com',
        serverUrl: Uri.parse('https://planner.example.com'),
        authenticatedAt: clock,
      );
      service.seedSession(account);
      expect(await service.restoreSession(), account);

      service.expireSession();
      expect(service.currentAccount(), isNull);
    });
  });

  group('FakeSyncService', () {
    late FakeCloudAccountService accounts;
    late FakeSyncService sync;

    setUp(() async {
      accounts = FakeCloudAccountService(clock: () => clock);
      await accounts.connectServer(Uri.parse('https://planner.example.com'));
      final account = await accounts.login(
        username: 'demo@example.com',
        password: 'demo1234',
      );
      sync = FakeSyncService(account: account, clock: () => clock);
    });

    tearDown(() async {
      await sync.close();
      await accounts.close();
    });

    test('状态流先推当前值，syncNow 经历 syncing 后回到 idle', () async {
      final seen = <SyncPhase>[];
      final subscription = sync.observeSyncStatus().listen(
        (status) => seen.add(status.phase),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.first, SyncPhase.idle);

      final result = await sync.syncNow();
      await Future<void>.delayed(Duration.zero);
      expect(result.outcome, SyncOutcome.noChanges);
      expect(seen, contains(SyncPhase.syncing));
      expect(sync.status.phase, SyncPhase.idle);
      expect(sync.status.lastSyncedAt, clock);
      expect(sync.syncModes, <SyncMode>[SyncMode.incremental]);
      await subscription.cancel();
    });

    test('离线 / 未登录返回明确结果', () async {
      sync.setOffline(true);
      expect((await sync.syncNow()).outcome, SyncOutcome.offline);

      sync.setAccount(null);
      expect((await sync.syncNow()).outcome, SyncOutcome.authRequired);
    });

    test('冲突可以列出并解决，manual 必须给载荷', () async {
      sync.seedConflict(
        SyncConflict(
          id: 'c1',
          entityType: CloudEntityType.task,
          entityId: 'task-1',
          baseRevision: 1,
          serverRevision: 2,
          kind: ConflictKind.updateUpdate,
          detectedAt: clock,
          localPayload: const <String, Object?>{'title': '本地'},
          serverPayload: const <String, Object?>{'title': '服务端'},
        ),
      );
      expect((await sync.listConflicts()).single.id, 'c1');
      expect(sync.status.phase, SyncPhase.needsAttention);

      await expectLater(
        sync.resolveConflict('c1', ConflictResolution.manual),
        throwsA(isA<CloudException>()),
      );

      final result = await sync.resolveConflict(
        'c1',
        ConflictResolution.manual,
        mergedPayload: const <String, Object?>{'title': '合并'},
      );
      expect(result.outcome, SyncOutcome.success);
      expect(await sync.listConflicts(), isEmpty);
      expect(sync.status.conflictCount, 0);
      expect(sync.status.phase, SyncPhase.idle);
    });

    test('冲突结果会把未解决数量反映到状态里', () async {
      sync.setNextResult(
        SyncResult(
          outcome: SyncOutcome.conflict,
          finishedAt: clock,
          conflicts: 1,
        ),
      );
      final result = await sync.syncNow();
      expect(result.outcome, SyncOutcome.conflict);
      expect(sync.status.phase, SyncPhase.needsAttention);
      expect(sync.status.conflictCount, 1);
    });

    test('绑定检查只读；云端非空时禁止上传', () async {
      sync.setBindingInspection(
        const BindingInspection(
          situation: BindingSituation.bothHaveData,
          canUpload: false,
          requiresBackup: true,
          recommendedChoice: BindingChoice.useCloudAndArchiveLocal,
          message: '本机 7 条，云端 3 条',
          localLiveRecords: 7,
          cloudRecords: 3,
        ),
      );
      final inspection = await sync.inspectBinding();
      expect(inspection.situation, BindingSituation.bothHaveData);
      expect(inspection.canUpload, isFalse);

      await expectLater(
        sync.applyBinding(BindingChoice.uploadLocalToAccount),
        throwsA(
          isA<CloudException>().having(
            (error) => error.kind,
            'kind',
            CloudErrorKind.conflict,
          ),
        ),
      );
    });

    test('自动同步开关持久化在状态里', () async {
      await sync.enableAutoSync(true);
      expect(sync.status.autoSyncEnabled, isTrue);
      expect(sync.status.autoUploadEnabled, isTrue);
      expect(sync.status.autoDownloadEnabled, isTrue);
      await sync.enableAutoSync(false);
      expect(sync.status.autoSyncEnabled, isFalse);
    });

    test('上传与下载可以是两个独立动作', () async {
      await sync.uploadNow();
      expect(sync.uploadCalls, 1);
      expect(sync.downloadCalls, 0);
      expect(sync.status.lastUploadedAt, clock);
      expect(sync.status.lastDownloadedAt, isNull);

      await sync.downloadNow();
      expect(sync.uploadCalls, 1);
      expect(sync.downloadCalls, 1);
      expect(sync.status.lastDownloadedAt, clock);
      expect(sync.status.lastUploadedAt, clock);
    });

    test('自动上传/自动下载可以分别开关', () async {
      await sync.enableAutoUpload(true);
      expect(sync.status.autoUploadEnabled, isTrue);
      expect(sync.status.autoDownloadEnabled, isFalse);

      await sync.enableAutoDownload(true);
      expect(sync.status.autoUploadEnabled, isTrue);
      expect(sync.status.autoDownloadEnabled, isTrue);

      await sync.enableAutoUpload(false);
      expect(sync.status.autoUploadEnabled, isFalse);
      expect(sync.status.autoDownloadEnabled, isTrue);
    });
  });
}
