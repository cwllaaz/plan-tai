/// 跨操作系统（Windows ↔ Ubuntu）真实 PocketBase 双向同步验收。
///
/// 这是阶段 2 的「真实跨设备」测试：每一步用**独立进程 / 独立操作系统**运行，
/// 通过同一台真实 PocketBase 服务器交换数据，步骤之间用状态文件传递实体 ID。
///
/// 步骤（按顺序在人肉/脚本编排下执行）：
///   1. windows-seed        （Windows）创建项目/跨天阶段/任务/备注并首次绑定上传
///   2. ubuntu-modify       （Ubuntu）下载 Windows 数据并校验；改时间、建跨天阶段、
///                          完成任务、离线新增任务（队列）后上传
///   3. windows-verify      （Windows）复用 seed 本地库：离线改同一任务制造冲突并验证
///                          冲突保留 + 本地版本不丢；解决冲突后上传；删除任务；校验 Ubuntu 新增任务
///   4. ubuntu-final        （Ubuntu）下载并校验 Windows 的修改/删除；重复同步幂等；
///                          切换账号不串号
///
/// 运行方式（在仓库根目录）：
/// ```powershell
/// $env:JIHUATAI_E2E='1'
/// $env:JIHUATAI_E2E_SERVER='http://127.0.0.1:8090'
/// $env:JIHUATAI_E2E_USER='sync-test@jihuatai.local'
/// $env:JIHUATAI_E2E_PASS='TestPass12345'
/// $env:JIHUATAI_E2E_USER2='sync-other@jihuatai.local'
/// $env:JIHUATAI_E2E_PASS2='TestPass12345'
/// $env:JIHUATAI_E2E_STEP='windows-seed'
/// flutter test test/integration/cross_os_sync_test.dart
/// ```
/// 每一步成功后会把状态写入 `build/e2e-cross/state.json`；跨 OS 执行时把该文件
/// 复制到另一端的仓库同路径即可。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/cloud/cloud.dart';
import 'package:jihuatai/data/sqlite_planner_repository.dart';
import 'package:jihuatai/data/sync/sync.dart';

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
  }) async {
    final repo = SqlitePlannerRepository.open(databasePath: databasePath);
    final account = PocketBaseAccountService(tokenStore: MemoryTokenStore());
    await account.connectServer(Uri.parse(serverUrl));
    await account.login(username: email, password: password);
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

String _dir(String step) =>
    '${Directory.current.path}${Platform.pathSeparator}build'
    '${Platform.pathSeparator}e2e-cross${Platform.pathSeparator}$step';

String get _statePath =>
    Platform.environment['JIHUATAI_E2E_STATE'] ??
    '${Directory.current.path}${Platform.pathSeparator}build'
        '${Platform.pathSeparator}e2e-cross${Platform.pathSeparator}state.json';

Map<String, Object?> _readState() {
  final file = File(_statePath);
  if (!file.existsSync()) return <String, Object?>{};
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void _writeState(Map<String, Object?> state) {
  final file = File(_statePath)..parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(state),
    flush: true,
  );
}

Map<String, String> _ids(Map<String, Object?> state) =>
    (state['ids'] as Map<String, Object?>? ?? <String, Object?>{})
        .map((k, v) => MapEntry(k, '$v'));

/// 首次登录「云端有数据」：走与真实 App 相同的绑定向导 → 新建账号工作区 → 全量下载。
Future<_Client> _openWorkspaceFromCloud({
  required String baseDir,
  required String serverUrl,
  required String email,
  required String password,
}) async {
  final dataDir = Directory(baseDir)..createSync(recursive: true);
  final localDb =
      '${dataDir.path}${Platform.pathSeparator}app.db';
  final probe = await _Client.open(
    databasePath: localDb,
    serverUrl: serverUrl,
    email: email,
    password: password,
  );
  final inspection = await probe.sync.inspectBinding();
  expect(
    inspection.situation,
    BindingSituation.freshInstallCloudHasData,
    reason: '云端正本步骤开始时应当已有数据',
  );
  final bound = await probe.sync.applyBinding(
    BindingChoice.useCloudAndArchiveLocal,
  );
  expect(bound.requiresRestart, isTrue);
  final ownerId = probe.account.currentAccount()!.ownerId;
  await probe.close();

  final workspaceDb = '${dataDir.path}${Platform.pathSeparator}accounts'
      '${Platform.pathSeparator}$ownerId${Platform.pathSeparator}app.db';
  return _Client.open(
    databasePath: workspaceDb,
    serverUrl: serverUrl,
    email: email,
    password: password,
  );
}

void main() {
  final enabled = Platform.environment['JIHUATAI_E2E'] == '1';
  final step = Platform.environment['JIHUATAI_E2E_STEP'] ?? '';
  final server =
      Platform.environment['JIHUATAI_E2E_SERVER'] ?? 'http://127.0.0.1:8090';
  final email = Platform.environment['JIHUATAI_E2E_USER'] ?? '';
  final password = Platform.environment['JIHUATAI_E2E_PASS'] ?? '';

  group('跨 OS 真实双向同步 · step=$step', () {
    test('执行跨 OS 步骤：$step', () async {
      switch (step) {
        case 'windows-seed':
          await _windowsSeed(server, email, password);
          break;
        case 'ubuntu-modify':
          await _ubuntuModify(server, email, password);
          break;
        case 'windows-verify':
          await _windowsVerify(server, email, password);
          break;
        case 'ubuntu-final':
          await _ubuntuFinal(server, email, password);
          break;
        default:
          fail('未知或缺失 JIHUATAI_E2E_STEP：$step');
      }
    });
  }, skip: enabled ? false : '设置 JIHUATAI_E2E=1 后运行（需要真实 PocketBase）');
}

// ---------------------------------------------------------------- steps

/// Windows：创建本地数据 → 首次绑定上传（任务 A 的 Windows 侧起点）。
Future<void> _windowsSeed(String server, String email, String password) async {
  final base = _dir('win-seed');
  if (Directory(base).existsSync()) Directory(base).deleteSync(recursive: true);
  final db = '$base${Platform.pathSeparator}app.db';

  final client = await _Client.open(
    databasePath: db,
    serverUrl: server,
    email: email,
    password: password,
  );
  try {
    final project = await client.repo.createProject(
      const ProjectDraft(name: '跨OS项目', color: ProjectColor.blue),
    );
    final span = await client.repo.createSpan(
      PlanSpanDraft(
        projectId: project.id,
        title: '跨OS阶段',
        startDate: LocalDate(2026, 11, 16),
        endDate: LocalDate(2026, 11, 20),
      ),
    );
    final task1 = await client.repo.createTask(
      PlannerTaskDraft(
        title: 'Windows创建的任务',
        projectId: project.id,
        spanId: span.id,
        scheduledDate: LocalDate(2026, 11, 16),
        timeSlot: TimeSlot(startMinute: 9 * 60, durationMinutes: 60),
        priority: TaskPriority.high,
      ),
    );
    final task2 = await client.repo.createTask(
      PlannerTaskDraft(
        title: 'Windows的第二个任务',
        projectId: project.id,
        scheduledDate: LocalDate(2026, 11, 17),
      ),
    );
    await client.repo.saveDailyNote(
      LocalDate(2026, 11, 16),
      body: 'Windows备注',
      focusItems: const <String>['跨OS同步'],
    );

    final inspection = await client.sync.inspectBinding();
    expect(inspection.situation, BindingSituation.localDataCloudEmpty);
    final bound = await client.sync.applyBinding(
      BindingChoice.uploadLocalToAccount,
    );
    expect(bound.changed, isTrue, reason: bound.message);
    expect(bound.requiresRestart, isFalse, reason: bound.message);
    final result = await client.sync.syncNow();
    expect(result.isSuccess, isTrue, reason: result.message ?? '');
    expect(client.sync.status.pendingOperations, 0);

    _writeState(<String, Object?>{
      'step': 'windows-seed',
      'runId': DateTime.now().toUtc().toIso8601String(),
      'server': server,
      'user': email,
      'ownerId': client.account.currentAccount()!.ownerId,
      'winSeedBase': base,
      'winSeedDb': db,
      'ids': <String, String>{
        'projectId': project.id,
        'spanId': span.id,
        'task1Id': task1.id,
        'task2Id': task2.id,
      },
    });
  } finally {
    await client.close();
  }
}

/// Ubuntu：下载 Windows 数据并校验（B/C 前置）；然后修改并上传（B/C/D/E 的 Ubuntu 侧）。
Future<void> _ubuntuModify(String server, String email, String password) async {
  final state = _readState();
  final ids = _ids(state);
  expect(ids['task1Id'], isNotNull, reason: '缺少 windows-seed 状态文件');

  final base = _dir('ubuntu-modify');
  if (Directory(base).existsSync()) Directory(base).deleteSync(recursive: true);
  final client = await _openWorkspaceFromCloud(
    baseDir: base,
    serverUrl: server,
    email: email,
    password: password,
  );
  try {
    final full = await client.sync.syncNow(mode: SyncMode.full);
    expect(full.isSuccess, isTrue, reason: full.message ?? '');

    // A：Windows 上传的数据在 Ubuntu 下载后完整可见。
    final project = await client.repo.findProject(ids['projectId']!);
    expect(project?.name, '跨OS项目');
    expect(project?.color, ProjectColor.blue);
    expect((await client.repo.findSpan(ids['spanId']!))?.title, '跨OS阶段');
    final task1 = await client.repo.findTask(ids['task1Id']!);
    expect(task1?.title, 'Windows创建的任务');
    expect(task1?.timeSlot?.startMinute, 9 * 60);
    expect(task1?.priority, TaskPriority.high);
    expect((await client.repo.findTask(ids['task2Id']!))?.title, 'Windows的第二个任务');
    final note = await client.repo.findDailyNote(LocalDate(2026, 11, 16));
    expect(note?.body, 'Windows备注');
    expect(note?.focusItems, <String>['跨OS同步']);

    // B：Ubuntu 修改时间（本地先写，随后上传）。
    final changedTime = await client.repo.updateTask(
      task1!.copyWith(timeSlot: TimeSlot(startMinute: 13 * 60, durationMinutes: 30)),
    );
    expect(changedTime.timeSlot?.startMinute, 13 * 60);

    // C：Ubuntu 新建一个跨日期阶段。
    final span2 = await client.repo.createSpan(
      PlanSpanDraft(
        projectId: ids['projectId']!,
        title: 'Ubuntu新建的跨天阶段',
        startDate: LocalDate(2026, 11, 21),
        endDate: LocalDate(2026, 11, 23),
      ),
    );

    // D：Ubuntu 完成任务（Windows 应看到完成状态）。
    final task2 = await client.repo.findTask(ids['task2Id']!);
    await client.repo.updateTask(task2!.copyWith(status: TaskStatus.done));

    // E：Ubuntu 离线新增任务（此时尚未调用 sync，操作在 outbox 中），随后联网上传。
    final task3 = await client.repo.createTask(
      PlannerTaskDraft(
        title: 'Ubuntu离线新增任务',
        projectId: ids['projectId']!,
        scheduledDate: LocalDate(2026, 11, 18),
      ),
    );
    await client.repo.saveDailyNote(
      LocalDate(2026, 11, 18),
      body: 'Ubuntu备注',
      focusItems: const <String>['离线队列'],
    );

    final pushed = await client.sync.syncNow();
    expect(pushed.isSuccess, isTrue, reason: pushed.message ?? '');
    expect(client.sync.status.pendingOperations, 0);

    state['step'] = 'ubuntu-modify';
    state['ubuntuBase'] = base;
    state['ubuntuWorkspaceDb'] = client.databasePath;
    state['ids'] = <String, String>{
      ...ids,
      'span2Id': span2.id,
      'task3Id': task3.id,
    };
    _writeState(state);
  } finally {
    await client.close();
  }
}

/// Windows：复用 seed 本地库制造跨 OS 冲突（G），解决冲突、删除任务（H）、
/// 校验 Ubuntu 的修改（B/C/D/E 的 Windows 侧）。
Future<void> _windowsVerify(String server, String email, String password) async {
  final state = _readState();
  final ids = _ids(state);

  // 第一步：全新 Windows 客户端（等价“另一台 Windows 设备”）下载 Ubuntu 的改动，
  // 验证 B/C/D/E：时间、跨天阶段、完成状态、Ubuntu 离线新增任务、备注都能在 Windows 侧看到。
  final downloadBase = _dir('win-verify-download');
  if (Directory(downloadBase).existsSync()) {
    Directory(downloadBase).deleteSync(recursive: true);
  }
  final downloader = await _openWorkspaceFromCloud(
    baseDir: downloadBase,
    serverUrl: server,
    email: email,
    password: password,
  );
  try {
    final pulled = await downloader.sync.syncNow(mode: SyncMode.full);
    expect(pulled.isSuccess, isTrue, reason: pulled.message ?? '');
    final task1 = await downloader.repo.findTask(ids['task1Id']!);
    expect(task1?.timeSlot?.startMinute, 13 * 60,
        reason: 'Ubuntu 修改的时间应被 Windows 下载');
    expect(
      (await downloader.repo.findSpan(ids['span2Id']!))?.title,
      'Ubuntu新建的跨天阶段',
    );
    expect(
      (await downloader.repo.findTask(ids['task2Id']!))?.status,
      TaskStatus.done,
    );
    expect(
      (await downloader.repo.findTask(ids['task3Id']!))?.title,
      'Ubuntu离线新增任务',
    );
    expect(
      (await downloader.repo.findDailyNote(LocalDate(2026, 11, 18)))?.body,
      'Ubuntu备注',
    );
  } finally {
    await downloader.close();
  }

  // 第二步：复用 seed 本地库（baseRevision 过期）制造跨 OS 冲突 G。
  final db = state['winSeedDb'] as String?;
  expect(db, isNotNull, reason: '缺少 windows-seed 本地库路径');
  final client = await _Client.open(
    databasePath: db!,
    serverUrl: server,
    email: email,
    password: password,
  );
  try {
    var task1 = await client.repo.findTask(ids['task1Id']!);
    if (task1?.title != 'Windows离线冲突版本') {
      await client.repo.updateTask(task1!.copyWith(title: 'Windows离线冲突版本'));
    }
    var conflicts = await client.sync.listConflicts();
    final existing = conflicts.where((c) => c.entityId == ids['task1Id']).toList();
    if (existing.isEmpty) {
      final conflicted = await client.sync.syncNow();
      expect(conflicted.outcome, SyncOutcome.conflict,
          reason: '跨 OS 冲突应被检测到，而不是静默覆盖');
      conflicts = await client.sync.listConflicts();
    }
    final conflict = conflicts.firstWhere(
      (c) => c.entityId == ids['task1Id'],
      orElse: () => throw StateError('未产生预期的跨 OS 冲突'),
    );
    expect(conflict.localPayload?['title'], 'Windows离线冲突版本');
    expect(conflict.serverPayload?['title'], 'Windows创建的任务');
    // 本机修改未被静默覆盖（冲突期间本机版本保持不变）。
    expect(
      (await client.repo.findTask(ids['task1Id']!))?.title,
      'Windows离线冲突版本',
    );

    // 解决冲突：保留本机版本（整条记录以本机为准；时间回退为本机的 09:00，
    // 这是 V2 既有“保留本机/保留云端”二选一语义，不是静默覆盖）。
    await client.sync.resolveConflict(
      conflict.id,
      ConflictResolution.keepLocal,
    );
    final resolved = await client.sync.syncNow();
    expect(resolved.isSuccess, isTrue, reason: resolved.message ?? '');
    task1 = await client.repo.findTask(ids['task1Id']!);
    expect(task1?.title, 'Windows离线冲突版本');
    expect(task1?.timeSlot?.startMinute, 9 * 60,
        reason: 'keepLocal 以本机整条记录为准，覆盖云端时间字段');

    // D（反向）：Windows 把 Ubuntu 离线新增的任务标记完成，Ubuntu 下一阶段应看到完成状态。
    final task3 = await client.repo.findTask(ids['task3Id']!);
    await client.repo.updateTask(task3!.copyWith(status: TaskStatus.done));

    // H：Windows 删除第二个任务，Ubuntu 下一阶段应同步到删除。
    await client.repo.deleteTask(ids['task2Id']!);
    final afterDelete = await client.sync.syncNow();
    expect(afterDelete.isSuccess, isTrue, reason: afterDelete.message ?? '');

    state['step'] = 'windows-verify';
    state['winAfterVerifyDb'] = client.databasePath;
    _writeState(state);
  } finally {
    await client.close();
  }
}
/// Ubuntu：下载 Windows 的冲突解决结果与删除（H）；重复同步幂等（I）；
/// 切换账号不串号（K）。
Future<void> _ubuntuFinal(String server, String email, String password) async {
  final state = _readState();
  final ids = _ids(state);
  final db = state['ubuntuWorkspaceDb'] as String?;
  expect(db, isNotNull, reason: '缺少 ubuntu-modify 工作区路径');

  final client = await _Client.open(
    databasePath: db!,
    serverUrl: server,
    email: email,
    password: password,
  );
  try {
    final pulled = await client.sync.syncNow(mode: SyncMode.full);
    expect(pulled.isSuccess, isTrue, reason: pulled.message ?? '');
    // Windows 解决冲突后保留自己的版本（keepLocal），Ubuntu 应拿到该版本。
    expect(
      (await client.repo.findTask(ids['task1Id']!))?.title,
      'Windows离线冲突版本',
    );
    expect(
      (await client.repo.findTask(ids['task1Id']!))?.timeSlot?.startMinute,
      9 * 60,
      reason: 'Windows 冲突解决选择 keepLocal 后整条记录以 Windows 版本为准',
    );
    expect(
      (await client.repo.findSpan(ids['span2Id']!))?.title,
      'Ubuntu新建的跨天阶段',
    );
    // H：删除同步到 Ubuntu。
    expect(await client.repo.findTask(ids['task2Id']!), isNull);
    expect((await client.repo.findTask(ids['task3Id']!))?.title, 'Ubuntu离线新增任务');
    expect(
      (await client.repo.findTask(ids['task3Id']!))?.status,
      TaskStatus.done,
      reason: 'Windows 把任务标记完成后，Ubuntu 应同步到完成状态',
    );

    // I：重复同步不产生重复记录。
    final before = (await client.repo.watchAllTasks().first).length;
    final again1 = await client.sync.syncNow();
    final again2 = await client.sync.syncNow();
    expect(again1.isSuccess, isTrue);
    expect(again2.isSuccess, isTrue);
    expect((await client.repo.watchAllTasks().first).length, before);
    expect(
      (await client.repo.watchProjects().first).length,
      1,
      reason: '重复同步不应产生重复项目',
    );

    // K：切换账号 —— 第二个账号看不到第一个账号的数据。
    final otherEmail = Platform.environment['JIHUATAI_E2E_USER2'];
    final otherPassword = Platform.environment['JIHUATAI_E2E_PASS2'];
    if (otherEmail != null && otherPassword != null) {
      final otherBase = _dir('ubuntu-other-account');
      if (Directory(otherBase).existsSync()) {
        Directory(otherBase).deleteSync(recursive: true);
      }
      final other = await _Client.open(
        databasePath: '$otherBase${Platform.pathSeparator}app.db',
        serverUrl: server,
        email: otherEmail,
        password: otherPassword,
      );
      try {
        final inspection = await other.sync.inspectBinding();
        expect(inspection.cloudRecords, 0, reason: '账号 B 云端应为空');
        expect(inspection.situation, BindingSituation.freshInstallCloudEmpty);
        final bound = await other.sync.applyBinding(
          BindingChoice.keepLocalUnbound,
        );
        expect(bound.changed, isTrue);
        final ownerId = other.account.currentAccount()!.ownerId;
        final otherWorkspace =
            '$otherBase${Platform.pathSeparator}accounts'
            '${Platform.pathSeparator}$ownerId${Platform.pathSeparator}app.db';
        await other.close();
        final other2 = await _Client.open(
          databasePath: otherWorkspace,
          serverUrl: server,
          email: otherEmail,
          password: otherPassword,
        );
        try {
          final full = await other2.sync.syncNow(mode: SyncMode.full);
          expect(full.isSuccess, isTrue, reason: full.message ?? '');
          expect(await other2.repo.watchAllTasks().first, isEmpty);
          expect(await other2.repo.watchProjects().first, isEmpty);
          expect(await other2.sync.listConflicts(), isEmpty);
        } finally {
          await other2.close();
        }
      } finally {
        await other.close();
      }
    }

    state['step'] = 'ubuntu-final';
    state['completed'] = true;
    _writeState(state);
  } finally {
    await client.close();
  }
}
