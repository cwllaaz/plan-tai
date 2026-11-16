/// 真实 PocketBase 服务器上的双客户端双向同步验收。
///
/// 默认跳过（避免普通 `flutter test` 依赖本机服务）；准备方式：
///
/// ```powershell
/// # 1) 全新数据目录启动 PocketBase（见 server/README.md）
/// # 2) 建好两个普通用户，然后：
/// $env:JIHUATAI_E2E='1'
/// $env:JIHUATAI_E2E_SERVER='http://127.0.0.1:8090'
/// $env:JIHUATAI_E2E_USER='sync-test@jihuatai.local'
/// $env:JIHUATAI_E2E_PASS='TestPass12345'
/// $env:JIHUATAI_E2E_USER2='sync-other@jihuatai.local'
/// $env:JIHUATAI_E2E_PASS2='TestPass12345'
/// flutter test test/integration/real_server_sync_test.dart
/// ```
///
/// 两个客户端使用完全隔离的数据目录（各自 app.db + 绑定文件），
/// 但登录同一个云端账号——这正是「同一账号、两台设备」的真实拓扑。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/cloud/cloud.dart';
import 'package:jihuatai/data/sqlite_planner_repository.dart';
import 'package:jihuatai/data/sync/sync.dart';

/// 一个独立客户端：自己的数据目录、自己的 SQLite 库、自己的设备 ID。
final class _Client {
  _Client(this.databasePath, this.repo, this.account, this.sync);

  final String databasePath;
  final SqlitePlannerRepository repo;
  final PocketBaseAccountService account;
  final SqliteCloudSyncService sync;

  static Future<_Client> open({
    required String databasePath,
    required String serverUrl,
    required String email,
    required String password,
    bool login = true,
  }) async {
    final repo = SqlitePlannerRepository.open(databasePath: databasePath);
    final account = PocketBaseAccountService(tokenStore: MemoryTokenStore());
    if (login) {
      await account.connectServer(Uri.parse(serverUrl));
      await account.login(username: email, password: password);
    }
    final sync = SqliteCloudSyncService(
      repository: repo,
      account: account,
      credentials: account,
      api: PlannerApi(),
      autoStart: false,
      debounce: const Duration(milliseconds: 10),
      startupDelay: const Duration(days: 1),
      periodicInterval: const Duration(days: 1),
    );
    return _Client(databasePath, repo, account, sync);
  }

  Future<void> close() async {
    await sync.close();
    await account.close();
    await repo.close();
  }
}

void main() {
  final enabled = Platform.environment['JIHUATAI_E2E'] == '1';

  group('真实服务器 · 双客户端双向同步', () {
    final root = Directory(
      '${Directory.current.path}${Platform.pathSeparator}build'
      '${Platform.pathSeparator}e2e-${DateTime.now().millisecondsSinceEpoch}',
    );
    final server = Platform.environment['JIHUATAI_E2E_SERVER'] ??
        'http://127.0.0.1:8090';
    final email =
        Platform.environment['JIHUATAI_E2E_USER'] ?? 'sync-test@jihuatai.local';
    final password =
        Platform.environment['JIHUATAI_E2E_PASS'] ?? 'TestPass12345';

    late _Client a;
    late _Client b;
    late String projectId;
    late String spanId;
    late String taskId;

    setUpAll(() async {
      root.createSync(recursive: true);

      // 客户端 A：先有本地数据（模拟 V1 老用户），再登录并首次绑定上传。
      a = await _Client.open(
        databasePath: '${root.path}${Platform.pathSeparator}A'
        '${Platform.pathSeparator}app.db',
        serverUrl: server,
        email: email,
        password: password,
      );
      final project = await a.repo.createProject(
        const ProjectDraft(name: '同步验收项目', color: ProjectColor.blue),
      );
      projectId = project.id;
      final span = await a.repo.createSpan(
        PlanSpanDraft(
          projectId: projectId,
          title: '跨月阶段',
          startDate: LocalDate(2026, 10, 28),
          endDate: LocalDate(2026, 11, 5),
        ),
      );
      spanId = span.id;
      final task = await a.repo.createTask(
        PlannerTaskDraft(
          title: '写同步协议',
          projectId: projectId,
          spanId: spanId,
          scheduledDate: LocalDate(2026, 11, 16),
          timeSlot: TimeSlot(startMinute: 9 * 60, durationMinutes: 90),
          priority: TaskPriority.high,
        ),
      );
      taskId = task.id;
      await a.repo.createTask(
        PlannerTaskDraft(
          title: '离线也要能用',
          projectId: projectId,
          scheduledDate: LocalDate(2026, 11, 17),
        ),
      );
      await a.repo.saveDailyNote(
        LocalDate(2026, 11, 16),
        body: '今日备注',
        focusItems: const <String>['同步协议', '冲突处理'],
      );
    });

    tearDownAll(() async {
      await b.close();
      await a.close();
    });

    test('1. 本地既有数据首次绑定：上传不丢记录', () async {
      final inspection = await a.sync.inspectBinding();
      expect(inspection.situation, BindingSituation.localDataCloudEmpty);
      expect(inspection.canUpload, isTrue);
      expect(inspection.localLiveRecords, greaterThanOrEqualTo(5));

      final result = await a.sync.applyBinding(
        BindingChoice.uploadLocalToAccount,
      );
      expect(result.changed, isTrue);
      expect(result.requiresRestart, isFalse, reason: result.message);

      final status = a.sync.status;
      expect(status.phase, SyncPhase.idle, reason: status.lastError ?? '');
      expect(status.pendingOperations, 0);
      expect(await a.sync.listConflicts(), isEmpty);
    });

    test('2. 新设备首次登录：云端有数据，应新建工作区并全量下载', () async {
      b = await _Client.open(
        databasePath: '${root.path}${Platform.pathSeparator}B'
        '${Platform.pathSeparator}app.db',
        serverUrl: server,
        email: email,
        password: password,
      );
      final inspection = await b.sync.inspectBinding();
      expect(inspection.situation, BindingSituation.freshInstallCloudHasData);
      expect(inspection.cloudRecords, greaterThan(0));

      final result = await b.sync.applyBinding(
        BindingChoice.useCloudAndArchiveLocal,
      );
      expect(result.requiresRestart, isTrue, reason: result.message);

      // 重启语义：关闭当前库，改开账号工作区（本地库在 B/ 下，accounts 是同级目录）。
      final ownerId = b.account.currentAccount()!.ownerId;
      final workspaceDb =
          '${root.path}${Platform.pathSeparator}B'
          '${Platform.pathSeparator}accounts${Platform.pathSeparator}$ownerId'
          '${Platform.pathSeparator}app.db';
      await b.close();
      b = await _Client.open(
        databasePath: workspaceDb,
        serverUrl: server,
        email: email,
        password: password,
      );

      final pulled = await b.sync.syncNow(mode: SyncMode.full);
      expect(pulled.isSuccess, isTrue, reason: pulled.message ?? '');

      final task = await b.repo.findTask(taskId);
      expect(task, isNotNull);
      expect(task!.title, '写同步协议');
      expect(task.timeSlot?.startMinute, 9 * 60);
      expect(task.priority, TaskPriority.high);
      expect((await b.repo.findSpan(spanId))?.title, '跨月阶段');
      expect((await b.repo.watchProjects().first).length, 1);
      expect((await b.repo.watchAllTasks().first).length, 2);
      final note = await b.repo.findDailyNote(LocalDate(2026, 11, 16));
      expect(note?.body, '今日备注');
      expect(note?.focusItems, <String>['同步协议', '冲突处理']);
    });

    test('3. B 改时间并同步 → A 同步后拿到新时间', () async {
      var task = await b.repo.findTask(taskId);
      task = await b.repo.updateTask(
        task!.copyWith(
          timeSlot: TimeSlot(startMinute: 13 * 60, durationMinutes: 30),
        ),
      );
      expect(task.timeSlot!.startMinute, 13 * 60);
      final pushResult = await b.sync.syncNow();
      expect(pushResult.isSuccess, isTrue, reason: pushResult.message ?? '');

      final pullResult = await a.sync.syncNow();
      expect(pullResult.isSuccess, isTrue, reason: pullResult.message ?? '');
      final onA = await a.repo.findTask(taskId);
      expect(onA?.timeSlot?.startMinute, 13 * 60);
      expect(onA?.timeSlot?.durationMinutes, 30);
    });

    test('4. 两端离线改同一任务：冲突被保留，不丢任一版本', () async {
      var onA = await a.repo.findTask(taskId);
      var onB = await b.repo.findTask(taskId);
      // 模拟两端在联网前各自修改。
      onA = await a.repo.updateTask(onA!.copyWith(title: 'A 的版本'));
      onB = await b.repo.updateTask(onB!.copyWith(title: 'B 的版本'));

      // A 先上传成功。
      final aSync = await a.sync.syncNow();
      expect(aSync.isSuccess, isTrue, reason: aSync.message ?? '');

      // B 的 baseRevision 已过期 → 冲突。
      final bSync = await b.sync.syncNow();
      expect(bSync.outcome, SyncOutcome.conflict);
      final conflicts = await b.sync.listConflicts();
      expect(conflicts, isNotEmpty);
      final conflict = conflicts.firstWhere((c) => c.entityId == taskId);
      expect(conflict.localPayload?['title'], 'B 的版本');
      expect(conflict.serverPayload?['title'], 'A 的版本');

      // 本地数据没有被静默覆盖。
      final stillLocal = await b.repo.findTask(taskId);
      expect(stillLocal?.title, 'B 的版本');

      // 保留本机 → 重新同步后服务端与 A 都应该拿到 B 的版本。
      await b.sync.resolveConflict(conflict.id, ConflictResolution.keepLocal);
      final resolved = await b.sync.syncNow();
      expect(resolved.isSuccess, isTrue, reason: resolved.message ?? '');
      await a.sync.syncNow();
      expect((await a.repo.findTask(taskId))?.title, 'B 的版本');
    });

    test('5. 删除同步：A 删任务 → B 同步后消失且不会复活', () async {
      await a.repo.deleteTask(taskId);
      final aSync = await a.sync.syncNow();
      expect(aSync.isSuccess, isTrue, reason: aSync.message ?? '');

      final bSync = await b.sync.syncNow();
      expect(bSync.isSuccess, isTrue, reason: bSync.message ?? '');
      expect(await b.repo.findTask(taskId), isNull);
      expect(
        (await b.repo.watchAllTasks().first).any((t) => t.id == taskId),
        isFalse,
      );
      // 删除后再次同步不应把旧任务带回。
      await b.sync.syncNow();
      expect(await b.repo.findTask(taskId), isNull);
    });

    test('6. 同一次同步重跑：服务端不产生重复记录', () async {
      final before = await b.sync.syncNow();
      expect(before.isSuccess, isTrue);
      final countBefore = (await b.repo.watchAllTasks().first).length;
      final again = await b.sync.syncNow();
      expect(again.isSuccess, isTrue);
      expect((await b.repo.watchAllTasks().first).length, countBefore);
      final state = b.account.currentAccount();
      expect(state, isNotNull);
    });

    test('7. 跨月阶段、每日备注、完成状态都能同步', () async {
      final task = (await a.repo.watchAllTasks().first).firstWhere(
        (t) => t.title == '离线也要能用',
      );
      await a.repo.updateTask(
        task.copyWith(status: TaskStatus.done, notes: '改成已完成'),
      );
      await a.repo.saveDailyNote(
        LocalDate(2026, 10, 31),
        body: '跨月备注',
        focusItems: const <String>['月底收尾'],
      );
      await a.sync.syncNow();
      await b.sync.syncNow();

      final onB = (await b.repo.watchAllTasks().first).firstWhere(
        (t) => t.title == '离线也要能用',
      );
      expect(onB.status, TaskStatus.done);
      expect(onB.notes, '改成已完成');
      expect(
        (await b.repo.findDailyNote(LocalDate(2026, 10, 31)))?.body,
        '跨月备注',
      );
      expect((await b.repo.findSpan(spanId))?.endDate, LocalDate(2026, 11, 5));
    });

    test('8. 关闭重开：本地数据与游标完整，继续同步不重放', () async {
      final beforeClose = (await a.repo.watchAllTasks().first).length;
      await a.close();
      a = await _Client.open(
        databasePath: '${root.path}${Platform.pathSeparator}A'
        '${Platform.pathSeparator}app.db',
        serverUrl: server,
        email: email,
        password: password,
      );
      expect((await a.repo.watchAllTasks().first).length, beforeClose);
      final result = await a.sync.syncNow();
      expect(result.isSuccess, isTrue, reason: result.message ?? '');
      expect((await a.repo.watchAllTasks().first).length, beforeClose);
    });

    test('10. 协议层：删除项目级联、opId 幂等、客户端时钟偏差被忽略', () async {
      final account = a.account;
      final token = await account.requireToken();
      final baseUrl = account.baseUrl;
      final ownerId = account.currentAccount()!.ownerId;
      final api = PlannerApi();
      const deviceId = 'e2e-protocol-device';

      final projectId = Ids.newId();
      final spanId = Ids.newId();
      final taskId = Ids.newId();
      final projectOp = Ids.newId();
      final createdAt = DateTime.utc(2035, 1, 1).toIso8601String();

      Future<PushResponse> push(List<PushOp> ops) => api.push(
        baseUrl: baseUrl,
        token: token,
        deviceId: deviceId,
        ownerId: ownerId,
        ops: ops,
      );

      final created = await push(<PushOp>[
        PushOp(
          opId: projectOp,
          entityType: CloudEntityType.project,
          entityId: projectId,
          opType: 'create',
          baseRevision: 0,
          clientRevision: 1,
          clientUpdatedAt: DateTime.now().toUtc(),
          payload: <String, Object?>{
            'createdAt': createdAt,
            'name': '级联验收项目',
            'description': '',
            'color': '#3E63DD',
            'status': 'active',
            'sortOrder': 0,
          },
        ),
      ]);
      expect(created.results.first.status, 'applied');
      expect(created.results.first.serverRevision, 1);

      // 同 opId 重发：必须返回 duplicate，且版本不变（网络丢响应后的安全重试）。
      final duplicate = await push(<PushOp>[
        PushOp(
          opId: projectOp,
          entityType: CloudEntityType.project,
          entityId: projectId,
          opType: 'create',
          baseRevision: 0,
          clientRevision: 1,
          clientUpdatedAt: DateTime.now().toUtc(),
          payload: <String, Object?>{
            'createdAt': createdAt,
            'name': '级联验收项目',
            'description': '',
            'color': '#3E63DD',
            'status': 'active',
            'sortOrder': 0,
          },
        ),
      ]);
      expect(duplicate.results.first.status, 'duplicate');
      expect(duplicate.results.first.serverRevision, 1);

      final children = await push(<PushOp>[
        PushOp(
          opId: Ids.newId(),
          entityType: CloudEntityType.span,
          entityId: spanId,
          opType: 'create',
          baseRevision: 0,
          clientRevision: 1,
          clientUpdatedAt: DateTime.now().toUtc(),
          payload: <String, Object?>{
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'projectId': projectId,
            'title': '级联阶段',
            'startDate': '2026-12-01',
            'endDate': '2026-12-03',
            'status': 'planned',
            'description': '',
            'color': null,
            'sortOrder': 0,
          },
        ),
        PushOp(
          opId: Ids.newId(),
          entityType: CloudEntityType.task,
          entityId: taskId,
          opType: 'create',
          baseRevision: 0,
          clientRevision: 1,
          clientUpdatedAt: DateTime.now().toUtc(),
          payload: <String, Object?>{
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'projectId': projectId,
            'spanId': spanId,
            'title': '级联任务',
            'notes': '',
            'scheduledDate': '2026-12-02',
            'timeSlot': null,
            'priority': 'normal',
            'status': 'todo',
            'completedAt': null,
            'sortOrder': 0,
          },
        ),
      ]);
      expect(children.results.map((r) => r.status), everyElement('applied'));

      final deleted = await push(<PushOp>[
        PushOp(
          opId: Ids.newId(),
          entityType: CloudEntityType.project,
          entityId: projectId,
          opType: 'delete',
          baseRevision: 1,
          clientRevision: 2,
          clientUpdatedAt: DateTime.now().toUtc(),
        ),
      ]);
      expect(deleted.results.first.status, 'applied');
      expect(deleted.results.first.serverRevision, 2);

      final pulled = await api.pull(
        baseUrl: baseUrl,
        token: token,
        deviceId: deviceId,
        snapshot: false,
        limit: 500,
        cursor: 'c1_0000000000000000',
      );
      final byId = <String, List<PullChange>>{};
      for (final change in pulled.changes) {
        byId.putIfAbsent(change.entityId, () => <PullChange>[]).add(change);
      }
      for (final id in <String>[projectId, spanId, taskId]) {
        final changes = byId[id] ?? const <PullChange>[];
        expect(
          changes.any((c) => c.deleted),
          isTrue,
          reason: '删除项目应级联墓碑 $id',
        );
      }
      // 客户端时钟 2035 不影响服务端：createdAt 被钳制到服务器当前时间。
      final projectLive = (byId[projectId] ?? const <PullChange>[])
          .firstWhere((c) => !c.deleted);
      final pulledCreatedAt =
          DateTime.tryParse('${projectLive.payload?['createdAt']}') ??
          DateTime.utc(2035);
      expect(pulledCreatedAt.year, lessThan(2035));
      expect(pulled.snapshot, isFalse);
      expect(pulled.snapshotSeq, isNull);
    });

    test('9. 第二个账号看不到第一个账号的数据', () async {
      final otherEmail = Platform.environment['JIHUATAI_E2E_USER2'];
      final otherPassword = Platform.environment['JIHUATAI_E2E_PASS2'];
      if (otherEmail == null || otherPassword == null) {
        markTestSkipped('未设置 JIHUATAI_E2E_USER2/PASS2，跳过账号隔离用例');
        return;
      }
      final c = await _Client.open(
        databasePath: '${root.path}${Platform.pathSeparator}C'
        '${Platform.pathSeparator}app.db',
        serverUrl: server,
        email: otherEmail,
        password: otherPassword,
      );
      final inspection = await c.sync.inspectBinding();
      expect(inspection.cloudRecords, 0);
      expect(inspection.situation, BindingSituation.freshInstallCloudEmpty);
      final result = await c.sync.applyBinding(BindingChoice.keepLocalUnbound);
      expect(result.changed, isTrue);
      final ownerId = c.account.currentAccount()!.ownerId;
      final path =
          '${root.path}${Platform.pathSeparator}C'
          '${Platform.pathSeparator}accounts${Platform.pathSeparator}$ownerId'
          '${Platform.pathSeparator}app.db';
      await c.close();
      final c2 = await _Client.open(
        databasePath: path,
        serverUrl: server,
        email: otherEmail,
        password: otherPassword,
      );
      try {
        final full = await c2.sync.syncNow(mode: SyncMode.full);
        expect(full.isSuccess, isTrue, reason: full.message ?? '');
        expect(await c2.repo.watchAllTasks().first, isEmpty);
        expect(await c2.repo.watchProjects().first, isEmpty);
        expect(await c2.sync.listConflicts(), isEmpty);
      } finally {
        await c2.close();
      }
    });
  }, skip: enabled ? false : '设置 JIHUATAI_E2E=1 后运行（需要真实 PocketBase）');
}
