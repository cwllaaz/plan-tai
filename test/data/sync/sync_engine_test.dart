import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

import '../cloud/fake_planner_server.dart';
import 'support/sync_test_env.dart';

const String _ownerA = 'usr_owner_a';
const String _emailA = 'a@example.com';
const String _password = 'password-123456';

Map<String, Object?> _projectPayload(String name, {DateTime? createdAt}) =>
    <String, Object?>{
      'createdAt': encodeInstant(createdAt ?? DateTime.utc(2026, 11, 15, 5)),
      'name': name,
      'description': '',
      'color': '#3E63DD',
      'status': 'active',
      'sortOrder': 0,
    };

void main() {
  late FakePlannerServer server;

  setUp(() async {
    server = await FakePlannerServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  group('本地写入与队列', () {
    test('业务写入与 outbox 同事务：队列写失败则整体回滚', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      env.database.handle.execute(
        'CREATE TRIGGER fail_outbox BEFORE INSERT ON sync_outbox '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        () => env.repository.createTask(
          PlannerTaskDraft(
            title: '不应写入',
            scheduledDate: LocalDate.parse('2026-11-16'),
          ),
        ),
        throwsA(isA<LocalDatabaseException>()),
      );
      expect(await env.repository.watchAllTasks().first, isEmpty);
      final outbox = env.database.handle
          .select('SELECT COUNT(*) AS c FROM sync_outbox')
          .first['c'];
      expect(outbox, 0);
    });

    test('本地新建→修改→删除合并为一条稳定的待上传操作', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: '原始标题',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      final firstOp = env.repository.outbox.all().single;
      final updated = await env.repository.updateTask(
        task.copyWith(title: '改后标题'),
      );
      final merged = env.repository.outbox.all().single;
      expect(merged.opId, firstOp.opId, reason: '未发送的连续修改必须复用 opId');
      expect(merged.operation, OutboxOperation.create);
      expect(merged.payload['title'], '改后标题');
      await env.repository.deleteTask(updated.id);
      expect(env.repository.outbox.all(), isEmpty, reason: '从未上传的创建+删除无需上传');
    });
  });

  group('push / pull 基础', () {
    test('TC-01 新增任务上传后 outbox 清空、server_revision=1', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final project = await env.repository.createProject(
        const ProjectDraft(name: '项目 A'),
      );
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          projectId: project.id,
          title: '写同步引擎',
          scheduledDate: LocalDate.parse('2026-11-16'),
          timeSlot: TimeSlot(startMinute: 540, durationMinutes: 90),
          priority: TaskPriority.high,
        ),
      );
      final result = await env.sync.syncNow();
      expect(result.outcome, SyncOutcome.success);
      expect(env.repository.outbox.count(), 0);
      final row = env.database.handle.select(
        'SELECT server_revision FROM planner_tasks WHERE id = ?',
        <Object?>[task.id],
      ).single;
      expect(row['server_revision'], 1);
      expect(server.liveCount(_ownerA), 2);
      expect(server.payloadOf(_ownerA, 'task', task.id)!['title'], '写同步引擎');

      final again = await env.sync.syncNow();
      expect(again.outcome, SyncOutcome.noChanges);
      expect(server.liveCount(_ownerA), 2, reason: '重复同步不能产生重复实体');
    });

    test('TC-02/03 修改与删除都同步，删除是墓碑', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final project = await env.repository.createProject(
        const ProjectDraft(name: '项目'),
      );
      await env.sync.syncNow();
      final renamed = await env.repository.updateProject(
        (await env.repository.findProject(project.id))!.copyWith(name: '改名'),
      );
      await env.sync.syncNow();
      final remote = server.entity(_ownerA, 'project', project.id)!;
      expect(remote.revision, 2);
      expect(remote.payload!['name'], '改名');
      expect(remote.deleted, isFalse);

      await env.repository.deleteProject(renamed.id);
      await env.sync.syncNow();
      final tombstone = server.entity(_ownerA, 'project', project.id)!;
      expect(tombstone.deleted, isTrue);
      expect(tombstone.payload, isNull);
      expect(await env.repository.findProject(project.id), isNull);
      expect(env.repository.outbox.count(), 0);
    });

    test('TC-04 服务端已处理但响应丢失：同一 opId 重试返回 duplicate', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      server.dropNextPushResponse = true;
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: '响应丢失',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      final first = await env.sync.syncNow();
      expect(first.outcome, SyncOutcome.offline);
      expect(env.repository.outbox.count(), 1, reason: '未收到确认必须保留队列');
      expect(server.liveCount(_ownerA), 1);

      final second = await env.sync.syncNow();
      expect(second.outcome, SyncOutcome.success);
      expect(env.repository.outbox.count(), 0);
      expect(server.liveCount(_ownerA), 1, reason: 'opId 幂等，不能重复建实体');
      expect(server.opLogCount(_ownerA), 1);

      final row = env.database.handle.select(
        'SELECT server_revision FROM planner_tasks WHERE id = ?',
        <Object?>[task.id],
      ).single;
      expect(row['server_revision'], 1);
    });

    test('TC-06 下载多页增量数据（limit=2、5 条）', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      server.pageSize = 2;
      for (var i = 0; i < 5; i++) {
        server.seedEntity(
          ownerId: _ownerA,
          type: 'project',
          id: '0192f0a1-0000-7000-8000-00000000000$i',
          payload: _projectPayload('云端项目 $i'),
        );
      }
      final result = await env.sync.syncNow(mode: SyncMode.full);
      expect(result.outcome, SyncOutcome.success, reason: result.message);
      expect(await env.repository.watchProjects().first, hasLength(5));
      expect(server.pullRequestCount, greaterThanOrEqualTo(3));
      expect(env.repository.outbox.count(), 0, reason: 'pull 不得生成 outbox');
    });

    test('TC-07 拉取中途失败：该页回滚、游标不前进，下一次继续', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      server.pageSize = 1;
      for (var i = 0; i < 3; i++) {
        server.seedEntity(
          ownerId: _ownerA,
          type: 'project',
          id: '0192f0a1-0000-7000-8000-00000000001$i',
          payload: _projectPayload('项目 $i'),
        );
      }
      server.corruptPushPage = 2;
      final failed = await env.sync.syncNow(mode: SyncMode.full);
      expect(failed.outcome, SyncOutcome.error);
      expect(
        await env.repository.watchProjects().first,
        hasLength(1),
        reason: '只有第一页提交成功，坏页整体回滚',
      );

      server.corruptPushPage = 0;
      final recovered = await env.sync.syncNow(mode: SyncMode.full);
      expect(recovered.outcome, SyncOutcome.success);
      expect(await env.repository.watchProjects().first, hasLength(3));
    });

    test('TC-08 服务端游标持久化：重启后只拉新增变化', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      server.seedEntity(
        ownerId: _ownerA,
        type: 'project',
        id: '0192f0a1-0000-7000-8000-000000000021',
        payload: _projectPayload('第一条'),
      );
      await env.sync.syncNow(mode: SyncMode.full);
      final cursor = server.pullCursors.last;

      server.seedEntity(
        ownerId: _ownerA,
        type: 'project',
        id: '0192f0a1-0000-7000-8000-000000000022',
        payload: _projectPayload('第二条'),
      );
      await env.sync.close();
      final second = SqliteCloudSyncService(
        repository: env.repository,
        account: env.accountService,
        credentials: env.accountService,
        api: PlannerApi(),
        autoStart: false,
      );
      addTearDown(second.close);
      final result = await second.syncNow();
      expect(result.outcome, SyncOutcome.success);
      expect(server.pullCursors.last, cursor, reason: '必须从持久化游标继续');
      expect(await env.repository.watchProjects().first, hasLength(2));
    });
  });

  group('重启与离线', () {
    test('TC-11 软件重启后继续上传重启前的待同步操作', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: '重启前',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await env.sync.close();
      await env.repository.close();

      final database = PlannerDatabase.open(path: env.databasePath);
      final repository = SqlitePlannerRepository(database);
      final second = SqliteCloudSyncService(
        repository: repository,
        account: env.accountService,
        credentials: env.accountService,
        api: PlannerApi(),
        autoStart: false,
      );
      addTearDown(() async {
        await second.close();
        await repository.close();
      });
      final result = await second.syncNow();
      expect(result.outcome, SyncOutcome.success);
      expect(server.payloadOf(_ownerA, 'task', task.id)!['title'], '重启前');
      expect(repository.outbox.count(), 0);
    });

    test('TC-14 无网络时本地功能完全正常，队列保留', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      server.offline = true;
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: '离线任务',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      expect((await env.repository.findTask(task.id))!.title, '离线任务');
      final updated = await env.repository.updateTask(
        task.copyWith(title: '离线改名'),
      );
      expect((await env.repository.findTask(task.id))!.title, '离线改名');
      final result = await env.sync.syncNow();
      expect(result.outcome, SyncOutcome.offline);
      expect(env.sync.status.phase, SyncPhase.offline);
      expect(env.repository.outbox.count(), greaterThan(0));

      server.offline = false;
      final recovered = await env.sync.syncNow();
      expect(recovered.outcome, SyncOutcome.success);
      expect(server.payloadOf(_ownerA, 'task', updated.id)!['title'], '离线改名');
      expect(env.repository.outbox.count(), 0);
    });
  });

  group('冲突', () {
    test('TC-05 两设备修改同一任务：保留本地后以服务端版本为 base 重推', () async {
      final deviceA = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(deviceA.dispose);
      final deviceB = await SyncTestEnv.create(
        server: server,
        addAccount: false,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(deviceB.dispose);

      final task = await deviceA.repository.createTask(
        PlannerTaskDraft(
          title: '初始',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await deviceA.sync.syncNow();
      await deviceB.sync.syncNow();
      expect((await deviceB.repository.findTask(task.id))!.title, '初始');

      await deviceA.repository.updateTask(
        (await deviceA.repository.findTask(task.id))!.copyWith(title: 'A 版'),
      );
      await deviceA.sync.syncNow();

      await deviceB.repository.updateTask(
        (await deviceB.repository.findTask(task.id))!.copyWith(title: 'B 版'),
      );
      final conflicted = await deviceB.sync.syncNow();
      expect(conflicted.outcome, SyncOutcome.conflict);
      final conflicts = await deviceB.sync.listConflicts();
      expect(conflicts, hasLength(1));
      expect(conflicts.single.kind, ConflictKind.updateUpdate);
      expect(conflicts.single.serverPayload?['title'], 'A 版');
      expect(
        (await deviceB.repository.findTask(task.id))!.title,
        'B 版',
        reason: '冲突未解决前本地内容不得被覆盖',
      );

      final resolved = await deviceB.sync.resolveConflict(
        conflicts.single.id,
        ConflictResolution.keepLocal,
      );
      expect(resolved.outcome, SyncOutcome.success);
      expect(await deviceB.sync.listConflicts(), isEmpty);
      expect(server.payloadOf(_ownerA, 'task', task.id)!['title'], 'B 版');

      await deviceA.sync.syncNow();
      expect((await deviceA.repository.findTask(task.id))!.title, 'B 版');
    });

    test('TC-05b 保留服务端版本：本地变 A 版，冲突清除', () async {
      final deviceA = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(deviceA.dispose);
      final deviceB = await SyncTestEnv.create(
        server: server,
        addAccount: false,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(deviceB.dispose);
      final task = await deviceA.repository.createTask(
        PlannerTaskDraft(
          title: '初始',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await deviceA.sync.syncNow();
      await deviceB.sync.syncNow();
      await deviceA.repository.updateTask(
        (await deviceA.repository.findTask(task.id))!.copyWith(title: 'A 版'),
      );
      await deviceA.sync.syncNow();
      await deviceB.repository.updateTask(
        (await deviceB.repository.findTask(task.id))!.copyWith(title: 'B 版'),
      );
      await deviceB.sync.syncNow();
      final conflict = (await deviceB.sync.listConflicts()).single;
      await deviceB.sync.resolveConflict(
        conflict.id,
        ConflictResolution.keepServer,
      );
      expect((await deviceB.repository.findTask(task.id))!.title, 'A 版');
      expect(await deviceB.sync.listConflicts(), isEmpty);
      expect(server.opLogCount(_ownerA), greaterThanOrEqualTo(2));
    });

    test('TC-06 修改已被删除的任务：保留本地 → 新 ID 副本，旧 ID 保持墓碑', () async {
      final deviceA = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(deviceA.dispose);
      final deviceB = await SyncTestEnv.create(
        server: server,
        addAccount: false,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(deviceB.dispose);
      final task = await deviceA.repository.createTask(
        PlannerTaskDraft(
          title: '会被删除',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await deviceA.sync.syncNow();
      await deviceB.sync.syncNow();
      await deviceA.repository.deleteTask(task.id);
      await deviceA.sync.syncNow();

      await deviceB.repository.updateTask(
        (await deviceB.repository.findTask(task.id))!.copyWith(title: 'B 想保留'),
      );
      final conflicted = await deviceB.sync.syncNow();
      expect(conflicted.outcome, SyncOutcome.conflict);
      final conflict = (await deviceB.sync.listConflicts()).single;
      expect(conflict.kind, ConflictKind.updateDelete);
      expect(conflict.serverDeleted, isTrue);
      expect(conflict.serverPayload, isNull);

      final resolved = await deviceB.sync.resolveConflict(
        conflict.id,
        ConflictResolution.keepLocal,
      );
      expect(resolved.outcome, SyncOutcome.success);
      final live = await deviceB.repository.watchAllTasks().first;
      expect(live, hasLength(1));
      expect(live.single.title, 'B 想保留');
      expect(live.single.id, isNot(task.id));
      expect(server.entity(_ownerA, 'task', task.id)!.deleted, isTrue);
      expect(server.liveCount(_ownerA), 1);
    });

    test('TC-12 本地与云端已有相同记录：一致则合并，不一致则本地差异重推', () async {
      const projectId = '0192f0a1-0000-7000-8000-000000000031';
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
        idGenerator: () => projectId,
      );
      addTearDown(env.dispose);
      final local = await env.repository.createProject(
        const ProjectDraft(name: '同一条记录'),
      );
      // 模拟 V1 升级：有实体但没有 outbox 操作。
      for (final entry in env.repository.outbox.all()) {
        env.repository.outbox.remove(entry.opId);
      }
      server.seedEntity(
        ownerId: _ownerA,
        type: 'project',
        id: projectId,
        payload: syncPayloadOf(CloudEntityType.project, local),
      );
      final merged = await env.sync.syncNow(mode: SyncMode.full);
      expect(merged.outcome, SyncOutcome.success);
      expect(env.repository.outbox.count(), 0);
      expect(server.liveCount(_ownerA), 1);
      final row = env.database.handle.select(
        'SELECT server_revision FROM projects WHERE id = ?',
        <Object?>[projectId],
      ).single;
      expect(row['server_revision'], 1);

      // 模拟 V1 升级：本地有内容但从未上传（serverRevision=0、无 outbox）。
      env.database.handle.execute(
        'UPDATE projects SET server_revision = 0 WHERE id = ?',
        <Object?>[projectId],
      );
      server.seedEntity(
        ownerId: _ownerA,
        type: 'project',
        id: projectId,
        revision: 3,
        payload: <String, Object?>{
          ..._projectPayload('云端版本', createdAt: local.createdAt),
        },
      );
      final reconciled = await env.sync.syncNow(mode: SyncMode.full);
      expect(reconciled.outcome, SyncOutcome.success);
      expect(server.payloadOf(_ownerA, 'project', projectId)!['name'], '同一条记录');
      expect((await env.repository.findProject(projectId))!.name, '同一条记录');
    });
  });

  group('首次绑定与账号隔离', () {
    test('inspectBinding 只统计云端存活记录，不把历史变更算作记录', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: 'created then deleted',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await env.sync.uploadNow();
      await env.repository.deleteTask(task.id);
      await env.sync.uploadNow();

      expect(server.liveCount(_ownerA), 0);
      final inspection = await env.sync.inspectBinding();
      expect(inspection.cloudRecords, 0);
    });

    test('TC-07 首次绑定：上传前备份，本地数据全部 applied', () async {
      final env = await SyncTestEnv.create(
        server: server,
        bind: false,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final project = await env.repository.createProject(
        const ProjectDraft(name: '本地项目'),
      );
      await env.repository.createTask(
        PlannerTaskDraft(
          projectId: project.id,
          title: '本地任务',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      final inspection = await env.sync.inspectBinding();
      expect(inspection.situation, BindingSituation.localDataCloudEmpty);
      expect(inspection.canUpload, isTrue);
      expect(inspection.localLiveRecords, 2);
      expect(inspection.cloudRecords, 0);

      final report = await env.sync.applyBinding(
        BindingChoice.uploadLocalToAccount,
      );
      expect(report.changed, isTrue);
      expect(report.requiresRestart, isFalse);
      expect(report.backupPath, isNotNull);
      expect(File(report.backupPath!).existsSync(), isTrue);
      expect(server.liveCount(_ownerA), 2);
      expect(env.repository.outbox.count(), 0);
      final binding = AccountBindingStore(
        WorkspaceLayout.bindingPathForDatabase(env.databasePath),
      ).read()!;
      expect(binding.state, BindingState.bound);
      expect(binding.ownerId, _ownerA);
      expect(
        Directory(p.join(env.directory.path, 'backups'))
            .listSync()
            .whereType<File>(),
        isNotEmpty,
        reason: '必须同时有 SQLite 快照与 JSON 备份',
      );
    });

    test('TC-23 云端非空时拒绝上传本地数据', () async {
      final env = await SyncTestEnv.create(
        server: server,
        bind: false,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      await env.repository.createProject(const ProjectDraft(name: '本地项目'));
      server.seedEntity(
        ownerId: _ownerA,
        type: 'project',
        id: '0192f0a1-0000-7000-8000-000000000041',
        payload: _projectPayload('云端项目'),
      );
      final inspection = await env.sync.inspectBinding();
      expect(inspection.situation, BindingSituation.bothHaveData);
      expect(inspection.canUpload, isFalse);
      await expectLater(
        () => env.sync.applyBinding(BindingChoice.uploadLocalToAccount),
        throwsA(isA<CloudException>()),
      );
      expect(server.pushRequestCount, 0);
      expect(server.liveCount(_ownerA), 1);
    });

    test('TC-22 已绑定 A 的库登录 B：拒绝上传，新建独立工作区', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final project = await env.repository.createProject(
        const ProjectDraft(name: 'A 的数据'),
      );
      await env.sync.syncNow();
      final pushesBefore = server.pushRequestCount;

      server.addAccount(
        email: 'b@example.com',
        password: _password,
        ownerId: 'usr_owner_b',
      );
      final accountB = PocketBaseAccountService(tokenStore: MemoryTokenStore());
      addTearDown(accountB.close);
      await accountB.connectServer(server.baseUrl);
      await accountB.login(username: 'b@example.com', password: _password);
      final syncB = SqliteCloudSyncService(
        repository: env.repository,
        account: accountB,
        credentials: accountB,
        api: PlannerApi(),
        autoStart: false,
      );
      addTearDown(syncB.close);

      final inspection = await syncB.inspectBinding();
      expect(inspection.situation, BindingSituation.boundOtherAccount);
      expect(inspection.canUpload, isFalse);
      final blocked = await syncB.syncNow();
      expect(blocked.outcome, SyncOutcome.bindingRequired);
      expect(server.pushRequestCount, pushesBefore, reason: 'B 不得上传 A 的数据');
      expect(server.liveCount(_ownerA), 1);
      expect(server.liveCount('usr_owner_b'), 0);

      final report = await syncB.applyBinding(BindingChoice.keepLocalUnbound);
      expect(report.requiresRestart, isTrue);
      final workspaceDb = File(
        p.join(env.directory.path, 'accounts', 'usr_owner_b', 'app.db'),
      );
      expect(workspaceDb.existsSync(), isTrue);
      expect(
        (await env.repository.findProject(project.id))!.name,
        'A 的数据',
        reason: 'A 的库必须原样保留',
      );
    });

    test('全新安装、云端有数据：以云端为准创建账号工作区', () async {
      final env = await SyncTestEnv.create(
        server: server,
        bind: false,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      server.seedEntity(
        ownerId: _ownerA,
        type: 'project',
        id: '0192f0a1-0000-7000-8000-000000000051',
        payload: _projectPayload('云端已有'),
      );
      final inspection = await env.sync.inspectBinding();
      expect(inspection.situation, BindingSituation.freshInstallCloudHasData);
      final report = await env.sync.applyBinding(
        BindingChoice.useCloudAndArchiveLocal,
      );
      expect(report.requiresRestart, isTrue);
      expect(
        File(p.join(env.directory.path, 'accounts', _ownerA, 'app.db'))
            .existsSync(),
        isTrue,
      );
      expect(await env.repository.watchProjects().first, isEmpty);
    });
  });

  group('恢复备份', () {
    test('恢复备份后先进入 needs_reconcile，增量同步不会把旧数据灌回云端', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final project = await env.repository.createProject(
        const ProjectDraft(name: '恢复前项目'),
      );
      await env.sync.syncNow();
      final opsBefore = server.opLogCount(_ownerA);

      final backups = BackupService(env.repository);
      final jsonPath = await backups.exportJson();
      final preview = await backups.inspect(jsonPath);
      await backups.restore(preview, confirmOverwrite: true);

      final incremental = await env.sync.syncNow();
      expect(incremental.outcome, SyncOutcome.error);
      expect(
        env.sync.status.phase,
        SyncPhase.needsAttention,
        reason: '恢复后必须先对账',
      );
      expect(server.opLogCount(_ownerA), opsBefore, reason: '禁止自动重新上传');

      final full = await env.sync.syncNow(mode: SyncMode.full);
      expect(full.outcome, SyncOutcome.success);
      expect(server.liveCount(_ownerA), 1);
      expect((await env.repository.findProject(project.id))!.name, '恢复前项目');
    });
  });

  group('自动同步', () {
    test('自动同步开关持久化，本地改动后自动上传', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      await env.sync.enableAutoSync(true);
      expect(env.sync.status.autoSyncEnabled, isTrue);
      await env.repository.createTask(
        PlannerTaskDraft(
          title: '自动同步任务',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(server.liveCount(_ownerA), 1);
      expect(env.repository.outbox.count(), 0);

      await env.sync.enableAutoSync(false);
      expect(env.sync.status.autoSyncEnabled, isFalse);
      final stored = env.database.handle
          .select('SELECT auto_sync FROM sync_state WHERE id = 1')
          .single['auto_sync'];
      expect(stored, 0, reason: '开关必须持久化到 sync_state');
    });
  });

  group('upload/download separation', () {
    test('uploadNow pushes only and does not pull', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      await env.repository.createTask(
        PlannerTaskDraft(
          title: 'upload only',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );

      final result = await env.sync.uploadNow();
      expect(result.outcome, SyncOutcome.success);
      expect(result.pushed, 1);
      expect(result.pulled, 0);
      expect(server.liveCount(_ownerA), 1);
      expect(env.repository.outbox.count(), 0);
      expect(env.sync.status.lastUploadedAt, isNotNull);
      expect(env.sync.status.lastDownloadedAt, isNull);
    });

    test('downloadNow pulls only and keeps local outbox', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      await env.repository.createTask(
        PlannerTaskDraft(
          title: 'local pending',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );

      final result = await env.sync.downloadNow();
      expect(result.pushed, 0);
      expect(env.repository.outbox.count(), 1);
      expect(server.liveCount(_ownerA), 0);
      expect(env.sync.status.lastDownloadedAt, isNotNull);
    });

    test('auto upload and auto download persist independently', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);

      await env.sync.enableAutoUpload(true);
      await env.sync.enableAutoDownload(false);
      expect(env.sync.status.autoUploadEnabled, isTrue);
      expect(env.sync.status.autoDownloadEnabled, isFalse);

      final upload = env.database.handle
          .select("SELECT value FROM settings WHERE key = 'sync_auto_upload'")
          .single['value'];
      final download = env.database.handle
          .select("SELECT value FROM settings WHERE key = 'sync_auto_download'")
          .single['value'];
      expect(upload, '1');
      expect(download, '0');
    });
    test('force download overwrites local pending edit', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: 'server version',
          scheduledDate: LocalDate.parse('2026-11-16'),
        ),
      );
      await env.sync.uploadNow();
      await env.repository.updateTask(task.copyWith(title: 'local edit'));
      expect(env.repository.outbox.count(), 1);

      final result = await env.sync.downloadNow(overwriteLocal: true);
      expect(result.pushed, 0);
      expect(result.pulled, greaterThanOrEqualTo(1));
      expect(env.repository.outbox.count(), 0);
      expect((await env.repository.findTask(task.id))!.title, 'server version');
    });

    test(
      'force download restores local delete that was not uploaded',
      () async {
        final env = await SyncTestEnv.create(
          server: server,
          ownerId: _ownerA,
          email: _emailA,
          password: _password,
        );
        addTearDown(env.dispose);
        final task = await env.repository.createTask(
          PlannerTaskDraft(
            title: 'restore me',
            scheduledDate: LocalDate.parse('2026-11-16'),
          ),
        );
        await env.sync.uploadNow();
        await env.repository.deleteTask(task.id);
        expect(env.repository.outbox.count(), 1);
        expect(await env.repository.findTask(task.id), isNull);

        final result = await env.sync.downloadNow(overwriteLocal: true);
        expect(result.pushed, 0);
        expect(env.repository.outbox.count(), 0);
        final restored = await env.repository.findTask(task.id);
        expect(restored, isNotNull);
        expect(restored!.title, 'restore me');
      },
    );
    test('force download removes local-only records and pending ops', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final localOnly = await env.repository.createTask(
        PlannerTaskDraft(
          title: 'local only',
          scheduledDate: LocalDate.parse('2026-11-17'),
        ),
      );
      expect(env.repository.outbox.count(), 1);

      final result = await env.sync.downloadNow(overwriteLocal: true);
      expect(result.outcome, isNot(SyncOutcome.error));
      expect(env.repository.outbox.count(), 0);
      expect(env.sync.status.pendingOperations, 0);
      expect(await env.repository.findTask(localOnly.id), isNull);
    });

    test('force download clears every local-only entity type', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final project = await env.repository.createProject(
        const ProjectDraft(name: '仅本机项目'),
      );
      final span = await env.repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '仅本机阶段',
          startDate: LocalDate.parse('2026-11-18'),
          endDate: LocalDate.parse('2026-11-20'),
        ),
      );
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: '仅本机任务',
          projectId: project.id,
          spanId: span.id,
          scheduledDate: LocalDate.parse('2026-11-19'),
        ),
      );
      final noteDate = LocalDate.parse('2026-11-19');
      await env.repository.saveDailyNote(noteDate, body: '仅本机备注');
      expect(env.repository.outbox.count(), greaterThanOrEqualTo(4));

      final result = await env.sync.downloadNow(overwriteLocal: true);
      expect(result.outcome, isNot(SyncOutcome.error));
      expect(env.repository.outbox.count(), 0);
      expect(env.sync.status.pendingOperations, 0);
      expect(await env.repository.findProject(project.id), isNull);
      expect(await env.repository.findSpan(span.id), isNull);
      expect(await env.repository.findTask(task.id), isNull);
      expect(await env.repository.findDailyNote(noteDate), isNull);
      expect(await env.repository.watchAllTasks().first, isEmpty);
    });

    test(
      'force download applies cloud and drops local-only in one pass',
      () async {
        final env = await SyncTestEnv.create(
          server: server,
          ownerId: _ownerA,
          email: _emailA,
          password: _password,
        );
        addTearDown(env.dispose);
        final shared = await env.repository.createTask(
          PlannerTaskDraft(
            title: 'server version',
            scheduledDate: LocalDate.parse('2026-11-16'),
          ),
        );
        await env.sync.uploadNow();
        await env.repository.updateTask(shared.copyWith(title: 'local edit'));
        final localOnly = await env.repository.createTask(
          PlannerTaskDraft(
            title: 'local extra',
            scheduledDate: LocalDate.parse('2026-11-17'),
          ),
        );
        expect(env.repository.outbox.count(), 2);

        final result = await env.sync.downloadNow(overwriteLocal: true);
        expect(result.outcome, isNot(SyncOutcome.error));
        expect(env.repository.outbox.count(), 0);
        expect(
          (await env.repository.findTask(shared.id))!.title,
          'server version',
        );
        expect(await env.repository.findTask(localOnly.id), isNull);
      },
    );

    test(
      'force download advances the pull cursor for later increments',
      () async {
        final env = await SyncTestEnv.create(
          server: server,
          ownerId: _ownerA,
          email: _emailA,
          password: _password,
        );
        addTearDown(env.dispose);
        await env.repository.createTask(
          PlannerTaskDraft(
            title: 'server task',
            scheduledDate: LocalDate.parse('2026-11-17'),
          ),
        );
        await env.sync.uploadNow();

        await env.sync.downloadNow(overwriteLocal: true);
        final row = env.database.handle
            .select('SELECT cursor FROM sync_state WHERE id = 1')
            .single;
        expect(row['cursor'], isNotNull);

        server.pullCursors.clear();
        await env.sync.downloadNow();
        expect(server.pullCursors, isNotEmpty);
        expect(server.pullCursors.first, isNotNull);
      },
    );
    test('force download still works when backup cannot be created', () async {
      final env = await SyncTestEnv.create(
        server: server,
        ownerId: _ownerA,
        email: _emailA,
        password: _password,
      );
      addTearDown(env.dispose);
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: 'backup-blocked',
          scheduledDate: LocalDate.parse('2026-11-18'),
        ),
      );
      await env.sync.uploadNow();
      await env.repository.deleteTask(task.id);

      final layout = WorkspaceLayout(p.dirname(env.databasePath));
      final backups = Directory(layout.backupsDirectory);
      backups.createSync(recursive: true);
      backups.deleteSync();
      File(backups.path).writeAsStringSync('blocked');

      final result = await env.sync.downloadNow(overwriteLocal: true);
      expect(result.outcome, isNot(SyncOutcome.error));
      expect((await env.repository.findTask(task.id))?.title, 'backup-blocked');
    });
  });
}
