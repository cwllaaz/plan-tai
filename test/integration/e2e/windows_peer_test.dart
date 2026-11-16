// 计划台跨端真实联调 · Windows 对端（真实仓储 + 真实同步引擎 + 真实 HTTP）。
//
// 由宿主脚本 `scripts/android/e2e_real_server_device.ps1` 分阶段调用，
// 模拟「同一账号下的另一台设备（Windows）」：
//   initial  → 创建项目/跨日期阶段/任务/每日备注并上传（Windows 安排机械臂项目）
//   verify   → 拉取 Android 修改，再删除任务、改项目颜色、改阶段状态、改备注并上传
//   conflict → 拉取后修改同一任务标题并上传（制造真实的 UPDATE_UPDATE 冲突）
//   final    → 拉取 Android 冲突解决结果，核对删除/颜色/阶段/备注/幂等
//
// 运行（由宿主脚本设置环境变量）：
//   $env:JIHUATAI_E2E_PEER='1'
//   $env:JIHUATAI_E2E_SERVER='http://127.0.0.1:8090'
//   $env:JIHUATAI_PEER_DIR='build/e2e-device/windows'
//   $env:JIHUATAI_PEER_PHASE='initial'
//   flutter test --no-pub test/integration/e2e/windows_peer_test.dart
//
// 未设置 JIHUATAI_E2E_PEER 时整组跳过，不依赖本机服务器。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/cloud/cloud.dart';
import 'package:jihuatai/data/sqlite_planner_repository.dart';
import 'package:jihuatai/data/sync/sync.dart';
import 'package:path/path.dart' as p;

const String _taskTitle = 'Windows创建任务';
const String _task2Title = 'Windows待删任务';
const String _projectName = '跨端项目';
const String _spanTitle = '跨端阶段';
const String _noteBody = 'Windows每日备注';

void main() {
  final enabled = Platform.environment['JIHUATAI_E2E_PEER'] == '1';
  final phase = Platform.environment['JIHUATAI_PEER_PHASE'] ?? 'initial';
  final server = Platform.environment['JIHUATAI_E2E_SERVER'] ??
      'http://127.0.0.1:8090';
  final email = Platform.environment['JIHUATAI_E2E_USER'] ??
      'android-sync@jihuatai.local';
  final password =
      Platform.environment['JIHUATAI_E2E_PASS'] ?? 'TestPass12345';
  final root = Platform.environment['JIHUATAI_PEER_DIR'] ??
      p.join(Directory.current.path, 'build', 'e2e-device', 'windows');

  group('Windows 对端 · 真实服务器', () {
    test('phase=$phase', skip: !enabled, () async {
      final peer = await _Peer.open(
        root: root,
        server: server,
        email: email,
        password: password,
      );
      try {
        switch (phase) {
          case 'initial':
            await _initial(peer, root);
          case 'verify':
            await _verify(peer, root);
          case 'conflict':
            await _conflict(peer, root);
          case 'final':
            await _final(peer);
          default:
            fail('未知阶段：$phase');
        }
      } finally {
        await peer.close();
      }
    });
  });
}

Future<void> _initial(_Peer peer, String root) async {
  final today = LocalDate.today();
  final project = await peer.repo.createProject(
    const ProjectDraft(name: _projectName, color: ProjectColor.blue),
  );
  final span = await peer.repo.createSpan(
    PlanSpanDraft(
      projectId: project.id,
      title: _spanTitle,
      startDate: today.addDays(-2),
      endDate: today.addDays(2),
      status: PlanSpanStatus.doing,
      description: '跨日期阶段说明',
    ),
  );
  final task = await peer.repo.createTask(
    PlannerTaskDraft(
      title: _taskTitle,
      projectId: project.id,
      spanId: span.id,
      scheduledDate: today,
      priority: TaskPriority.high,
      notes: 'Windows任务备注',
    ),
  );
  final task2 = await peer.repo.createTask(
    PlannerTaskDraft(
      title: _task2Title,
      projectId: project.id,
      scheduledDate: today,
    ),
  );
  await peer.repo.saveDailyNote(
    today,
    body: _noteBody,
    focusItems: const <String>['跨端', '同步'],
  );

  // 本机已有数据、云端为空：明确选择「上传本机到账号」后再推送。
  await peer.ensureBound();
  final result = await peer.sync.syncNow(mode: SyncMode.full);
  expect(result.isSuccess, isTrue, reason: result.message);
  expect(peer.sync.status.pendingOperations, 0);

  _writeState(root, <String, Object?>{
    'projectId': project.id,
    'spanId': span.id,
    'taskId': task.id,
    'task2Id': task2.id,
    'date': today.iso,
  });
  // ignore: avoid_print
  print('[PEER] initial uploaded project=${project.id} task=${task.id} '
      'task2=${task2.id} date=${today.iso}');
}

Future<void> _verify(_Peer peer, String root) async {
  final state = _readState(root);
  final taskId = state['taskId'] as String;
  final task2Id = state['task2Id'] as String;
  final projectId = state['projectId'] as String;
  final spanId = state['spanId'] as String;
  final date = LocalDate.parse(state['date'] as String);

  final pulled = await peer.sync.syncNow(mode: SyncMode.full);
  expect(pulled.isSuccess, isTrue, reason: pulled.message);

  // 先确认 Android 的修改已到达 Windows 端（标题 + 完成状态）。
  final task = await peer.repo.findTask(taskId);
  expect(task, isNotNull, reason: '任务应存在');
  expect(task!.title, contains('-Android改'), reason: '应拉取到 Android 改的标题');
  expect(task.isDone, isTrue, reason: '应拉取到 Android 的完成状态');

  // Windows 端再做一批改动：删除任务、项目颜色、跨日期阶段状态、每日备注。
  await peer.repo.deleteTask(task2Id);
  final project = await peer.repo.findProject(projectId);
  expect(project, isNotNull);
  await peer.repo.updateProject(project!.copyWith(color: ProjectColor.red));
  final span = await peer.repo.findSpan(spanId);
  expect(span, isNotNull);
  await peer.repo.updateSpan(span!.copyWith(status: PlanSpanStatus.done));
  await peer.repo.saveDailyNote(
    date,
    body: 'Windows备注-改',
    focusItems: const <String>['跨端', '同步'],
  );

  final result = await peer.sync.syncNow();
  expect(result.isSuccess, isTrue, reason: result.message);
  expect(peer.sync.status.pendingOperations, 0);
  // ignore: avoid_print
  print('[PEER] verify pulled android changes; uploaded delete/color/span/note');
}

Future<void> _conflict(_Peer peer, String root) async {
  final state = _readState(root);
  final taskId = state['taskId'] as String;

  final pulled = await peer.sync.syncNow(mode: SyncMode.full);
  expect(pulled.isSuccess, isTrue, reason: pulled.message);
  final task = await peer.repo.findTask(taskId);
  expect(task, isNotNull);
  final updated = await peer.repo.updateTask(
    task!.copyWith(title: 'Windows冲突版'),
  );
  expect(updated.title, 'Windows冲突版');
  final result = await peer.sync.syncNow();
  expect(result.isSuccess, isTrue, reason: result.message);
  expect(peer.sync.status.pendingOperations, 0);
  // ignore: avoid_print
  print('[PEER] conflict uploaded title=Windows冲突版');
}

Future<void> _final(_Peer peer) async {
  final pulled = await peer.sync.syncNow(mode: SyncMode.full);
  expect(pulled.isSuccess, isTrue, reason: pulled.message);
  final repo = peer.repo;
  final all = await repo.watchAllTasks().first;
  final matches =
      all.where((PlannerTask t) => t.title.startsWith(_taskTitle)).toList();
  expect(matches, hasLength(1), reason: '重复同步不应产生重复任务');
  final expectedTitle = Platform.environment['JIHUATAI_PEER_EXPECT_TITLE'] ?? '$_taskTitle-离线改';
  expect(matches.single.title, expectedTitle, reason: '冲突解决/离线补传后的标题应同步到对端');
  expect(matches.single.isDone, isTrue);

  final projects = await repo.watchProjects().first;
  final project = projects.firstWhere((Project x) => x.name == _projectName);
  expect(project.color, ProjectColor.red, reason: '项目颜色应保持一致');

  final spans = await repo.watchSpansForProject(project.id).first;
  expect(spans.single.status, PlanSpanStatus.done, reason: '跨日期阶段状态应一致');

  final note = await repo.findDailyNote(LocalDate.today());
  expect(note?.body, 'Windows备注-改', reason: '每日备注应一致');

  // 幂等：再同步一次，记录数不变。
  await peer.sync.syncNow();
  final again = await repo.watchAllTasks().first;
  expect(again.where((PlannerTask t) => t.title.startsWith(_taskTitle)).length, 1);
  // ignore: avoid_print
  print('[PEER] final PASS title=${matches.single.title} tasks=${all.length} '
      'projectColor=${project.color.hex} span=${spans.single.status.name}');
}

void _writeState(String root, Map<String, Object?> value) {
  final file = File(p.join(root, 'peer_state.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(value), flush: true);
}

Map<String, Object?> _readState(String root) {
  final file = File(p.join(root, 'peer_state.json'));
  expect(file.existsSync(), isTrue, reason: '缺少 peer_state.json（需先跑 initial）');
  return Map<String, Object?>.from(
    jsonDecode(file.readAsStringSync()) as Map<Object?, Object?>,
  );
}

/// 一个独立的 Windows 客户端：自己的数据库、设备 ID 与安全存储（测试用内存令牌）。
final class _Peer {
  _Peer(this.repo, this.account, this.sync);

  final SqlitePlannerRepository repo;
  final PocketBaseAccountService account;
  final SqliteCloudSyncService sync;

  static Future<_Peer> open({
    required String root,
    required String server,
    required String email,
    required String password,
  }) async {
    Directory(root).createSync(recursive: true);
    final repo = SqlitePlannerRepository.open(
      databasePath: p.join(root, 'app.db'),
    );
    final account = PocketBaseAccountService(tokenStore: MemoryTokenStore());
    await account.connectServer(Uri.parse(server));
    await account.login(username: email, password: password);
    final sync = SqliteCloudSyncService(
      repository: repo,
      account: account,
      credentials: account,
      api: PlannerApi(),
      layout: WorkspaceLayout(root),
      autoStart: false,
      debounce: const Duration(milliseconds: 10),
      startupDelay: const Duration(days: 1),
      periodicInterval: const Duration(days: 1),
    );
    return _Peer(repo, account, sync);
  }

  /// 首次登录：本机有数据、云端为空 → 明确选择「上传本机到账号」。
  Future<void> ensureBound() async {
    final inspection = await sync.inspectBinding();
    if (inspection.situation == BindingSituation.localDataCloudEmpty) {
      final result = await sync.applyBinding(
        BindingChoice.uploadLocalToAccount,
      );
      expect(result.changed, isTrue, reason: result.message);
    }
  }

  Future<void> close() async {
    await sync.close();
    await account.close();
    await repo.close();
  }
}
