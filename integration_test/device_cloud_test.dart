// 计划台 Android · 真实 PocketBase 云端端到端验收（模拟器/真机）。
//
// 由宿主脚本 `scripts/android/e2e_real_server_device.ps1` 分阶段驱动，
// 每个阶段是一次独立的 `flutter test integration_test/... -d emulator-5554`
// （相当于用户关闭再打开应用），阶段间由宿主脚本完成：
//   Windows 对端创建/修改/删除数据、启停 PocketBase、重启应用。
//
// 阶段（--dart-define=E2E_PHASE=...）：
//   login-bind      首次登录真实服务器 → 关联云端数据 → 下载（不覆盖本机/不丢记录）
//   modify          在 App 内修改任务标题/完成状态/每日备注 → 上传
//   verify-windows  拉取 Windows 对端的删除、项目颜色、跨日期阶段、备注改动
//   offline         服务器已停：离线继续编辑 → 操作进入 outbox
//   conflict        服务器恢复且 Windows 对端已改同一记录 → 冲突不静默丢失 → 保留本机并收敛
//
// 断言全部基于真实 SQLite（应用私有目录/账号工作区）+ 真实 HTTP，不使用任何模拟数据。

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jihuatai/app/cloud_workspace.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/main.dart' as app;
import 'package:jihuatai/platform/app_paths.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const String _phase = String.fromEnvironment(
  'E2E_PHASE',
  defaultValue: 'login-bind',
);
const String _server = String.fromEnvironment(
  'E2E_SERVER',
  defaultValue: 'http://127.0.0.1:8090',
);
const String _account = String.fromEnvironment(
  'E2E_ACCOUNT',
  defaultValue: 'android-sync@jihuatai.local',
);
const String _password = String.fromEnvironment(
  'E2E_PASSWORD',
  defaultValue: 'TestPass12345',
);
const String _task = String.fromEnvironment(
  'E2E_TASK',
  defaultValue: 'Windows创建任务',
);
const String _task2 = String.fromEnvironment(
  'E2E_TASK2',
  defaultValue: 'Windows待删任务',
);
const String _project = String.fromEnvironment(
  'E2E_PROJECT',
  defaultValue: '跨端项目',
);
const String _span = String.fromEnvironment(
  'E2E_SPAN',
  defaultValue: '跨端阶段',
);
const String _note = String.fromEnvironment(
  'E2E_NOTE',
  defaultValue: 'Windows每日备注',
);
String _baseDir = '';

const String _androidSuffix = '-Android改';
const String _offlineSuffix = '-离线改';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实云端 E2E · 阶段 $_phase', (WidgetTester tester) async {
    debugPrint('[E2E-CLOUD] phase=$_phase server=$_server account=$_account');
    final today = LocalDate.today();

    await app.main();
    await _waitFor(tester, _key('mobile-tab-calendar'), seconds: 120);
    _baseDir = await AppPaths.resolveBaseDirectory();
    expect(tester.takeException(), isNull, reason: '启动异常');

    switch (_phase) {
      case 'login-bind':
        await _loginAndBind(tester);
      case 'modify':
        await _modifyAndUpload(tester, today);
      case 'verify-windows':
        await _verifyWindowsChanges(tester, today);
      case 'offline':
        await _offlineModify(tester, today);
      case 'conflict':
        await _resolveConflict(tester, today);
      default:
        fail('未知阶段：$_phase');
    }
    debugPrint('[E2E-CLOUD] PASS phase=$_phase');
  });
}

// ---------------------------------------------------------------------------
// 阶段实现
// ---------------------------------------------------------------------------

/// 首次登录 → 关联云端（新设备选择「以云端为准」）→ 下载全部记录。
Future<void> _loginAndBind(WidgetTester tester) async {
  await _openCloudPage(tester);
  await _waitFor(
    tester,
    _key('mobile-cloud-signin-submit'),
    seconds: 60,
  );
  await tester.enterText(_key('mobile-cloud-server-field'), _server);
  await tester.enterText(_key('mobile-cloud-account-field'), _account);
  await tester.enterText(_key('mobile-cloud-password-field'), _password);
  await tester.pump(const Duration(milliseconds: 200));
  await _tap(tester, _key('mobile-cloud-signin-submit'));

  // 登录成功后：新设备 + 云端已有数据 → 需要确认数据归属。
  await _waitUntil(
    tester,
    () =>
        _key('cloud-binding-confirm').evaluate().isNotEmpty ||
        _key('mobile-cloud-account-value').evaluate().isNotEmpty,
    seconds: 120,
    reason: '登录后应出现数据归属确认或账号信息',
  );
  if (_key('cloud-binding-confirm').evaluate().isNotEmpty) {
    await _tap(tester, _key('cloud-binding-confirm'));
    await _waitUntil(
      tester,
      () => find.textContaining('重启').evaluate().isNotEmpty ||
          _key('mobile-cloud-account-value').evaluate().isNotEmpty,
      seconds: 180,
      reason: '关联云端数据应在下载完成后提示重启',
    );
  }

  // 下载结果直接查账号工作区库（真实落库），并核对四类数据。
  // 注意：首次关联后数据库会切到 accounts/<ownerId>/app.db，指针可能稍后才落盘，
  // 因此这里每轮都重新解析数据库路径。
  String? dbPath;
  await _waitUntil(
    tester,
    () {
      final path = _dbPathSync();
      if (_taskIdByTitle(path, _task) == null) return false;
      dbPath = path;
      return true;
    },
    seconds: 180,
    reason: '云端任务应下载到本地 SQLite',
  );
  final resolvedDb = dbPath!;
  final taskId = _taskIdByTitle(resolvedDb, _task)!;
  expect(_projectIdByName(resolvedDb, _project), isNotNull, reason: '项目应下载');
  expect(_spanIdByTitle(resolvedDb, _span), isNotNull, reason: '跨日期阶段应下载');
  expect(
    _noteBody(resolvedDb, _dateIso(0)),
    contains(_note),
    reason: '每日备注应下载',
  );
  final color = _projectColor(resolvedDb, _project);
  debugPrint('[E2E-CLOUD] downloaded task=$taskId project=$_project color=$color '
      'db=$resolvedDb');
  expect(_outboxCount(resolvedDb), 0, reason: '仅下载不应产生待上传操作');
}

/// 在真实 App 内修改任务标题、完成状态、每日备注 → 立即同步 → outbox 清空。
Future<void> _modifyAndUpload(WidgetTester tester, LocalDate today) async {
  final dbPath = await _dbPath();
  final taskId = _taskIdByTitle(dbPath, _task);
  expect(taskId, isNotNull, reason: '上一阶段应已下载任务 $taskId');

  // UI 上确认今天列表中能看到云端任务。
  await _tap(tester, _key('mobile-day-${today.iso}'));
  await _waitFor(tester, find.text(_task), seconds: 60);
  expect(tester.takeException(), isNull);

  // 修改标题。
  await _tap(tester, _key('mobile-task-$taskId'));
  await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
  const newTitle = '$_task$_androidSuffix';
  await tester.enterText(_key('mobile-task-editor-title'), newTitle);
  await tester.pumpAndSettle();
  await _tap(tester, _key('mobile-task-editor-save'));
  await _waitUntil(
    tester,
    () => _taskTitleById(dbPath, taskId!) == newTitle,
    seconds: 30,
    reason: '修改后的标题应落库',
  );

  // 完成状态。
  await _tap(tester, _key('mobile-task-toggle-$taskId'));
  await _waitUntil(
    tester,
    () => _taskDone(dbPath, taskId!),
    seconds: 30,
    reason: '完成状态应落库',
  );

  // 每日备注（完整当日面板）。
  await _doubleTapDay(tester, today);
  await _waitFor(tester, _key('mobile-note-${today.iso}'), seconds: 30);
  final noteField = find
      .descendant(
        of: _key('mobile-note-${today.iso}'),
        matching: find.byType(TextField),
      )
      .first;
  await tester.ensureVisible(noteField);
  await tester.pumpAndSettle();
  const newNote = '$_note$_androidSuffix';
  await tester.enterText(noteField, newNote);
  await tester.pump(const Duration(milliseconds: 1200));
  await tester.pumpAndSettle();
  await _waitUntil(
    tester,
    () => (_noteBody(dbPath, today.iso) ?? '').contains(newNote),
    seconds: 30,
    reason: '备注自动保存应落库',
  );
  await _tap(tester, _key('mobile-day-close'));
  await tester.pumpAndSettle();

  // 立即同步并等待 outbox 清空；再同步一次验证幂等。
  await _openCloudPage(tester);
  await _syncNow(tester);
  await _waitUntil(
    tester,
    () => _outboxCount(dbPath) == 0,
    seconds: 180,
    reason: '同步后待上传操作应清空',
  );
  expect(_conflictCount(dbPath), 0, reason: '正常同步不应产生冲突');
  await _syncNow(tester);
  await _waitUntil(
    tester,
    () => _outboxCount(dbPath) == 0,
    seconds: 120,
    reason: '重复同步不应产生新的待上传操作',
  );
  debugPrint('[E2E-CLOUD] uploaded title=$newTitle note=$newNote');
}

/// 拉取 Windows 对端的删除 / 项目颜色 / 跨日期阶段 / 备注改动。
Future<void> _verifyWindowsChanges(WidgetTester tester, LocalDate today) async {
  await _openCloudPage(tester);
  await _syncNow(tester);
  final dbPath = await _dbPath();

  await _waitUntil(
    tester,
    () =>
        _taskDeleted(dbPath, _task2) &&
        _projectColor(dbPath, _project) == '#E5484D' &&
        _spanStatus(dbPath, _span) == 'done' &&
        (_noteBody(dbPath, today.iso) ?? '').contains('Windows备注-改'),
    seconds: 180,
    reason: '应拉取到 Windows 对端的删除/颜色/阶段/备注改动',
  );

  // 界面上：被删任务不出现，备注可在当日面板读到。
  await _tap(tester, find.byTooltip('关闭'));
  await tester.pumpAndSettle();
  await _tap(tester, _key('mobile-day-${today.iso}'));
  expect(find.text(_task2), findsNothing, reason: '云端删除的任务不应再显示');
  await _doubleTapDay(tester, today);
  await _waitFor(tester, _key('mobile-note-${today.iso}'), seconds: 30);
  expect(
    find.descendant(
      of: _key('mobile-note-${today.iso}'),
      matching: find.textContaining('Windows备注-改'),
    ),
    findsWidgets,
    reason: '每日备注界面应显示云端新内容',
  );
  await _tap(tester, _key('mobile-day-close'));
  debugPrint('[E2E-CLOUD] windows changes verified');
}

/// 服务器已停止：离线编辑必须成功落库，并进入 outbox 等待恢复。
Future<void> _offlineModify(WidgetTester tester, LocalDate today) async {
  final dbPath = await _dbPath();
  // 上一阶段（modify）改过标题，这里按后缀定位当前任务。
  final current = _taskByTitleSuffix(dbPath, _androidSuffix);
  expect(current, isNotNull, reason: '应能找到 Android 修改后的任务');
  final id = current!['id'] as String;
  const offlineTitle = '$_task$_offlineSuffix';

  await _tap(tester, _key('mobile-day-${today.iso}'));
  await _waitFor(tester, find.textContaining(_androidSuffix), seconds: 60);
  await _tap(tester, _key('mobile-task-$id'));
  await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
  await tester.enterText(_key('mobile-task-editor-title'), offlineTitle);
  await tester.pumpAndSettle();
  await _tap(tester, _key('mobile-task-editor-save'));
  await _waitUntil(
    tester,
    () => _taskTitleById(dbPath, id) == offlineTitle,
    seconds: 30,
    reason: '离线编辑仍应成功落库',
  );
  expect(_outboxCount(dbPath), greaterThan(0), reason: '离线修改应进入待上传队列');
  debugPrint('[E2E-CLOUD] offline saved title=$offlineTitle pending=${_outboxCount(dbPath)}');
}

/// 服务器恢复、Windows 对端已改同一记录：冲突必须保留两端版本，可保留本机后收敛。
Future<void> _resolveConflict(WidgetTester tester, LocalDate today) async {
  await _openCloudPage(tester);
  await _syncNow(tester);
  final dbPath = await _dbPath();
  await _waitUntil(
    tester,
    () => _conflictCount(dbPath) > 0,
    seconds: 180,
    reason: '两端改同一记录应产生冲突而不是静默覆盖',
  );
  final conflict = _firstConflict(dbPath);
  expect(conflict, isNotNull);
  final localPayload = conflict!['local_payload'] as String? ?? '';
  final serverPayload = conflict['server_payload'] as String? ?? '';
  expect(localPayload, contains(_offlineSuffix), reason: '本机版本必须保留');
  expect(serverPayload, isNotEmpty, reason: '云端版本必须保留');
  debugPrint('[E2E-CLOUD] conflict kept local+server id=${conflict['id']}');

  // UI 上处理冲突：保留本机版本。
  await _tapVisible(tester, _key('mobile-cloud-open-conflicts'));
  await _waitFor(tester, _key('mobile-cloud-conflict-page'), seconds: 60);
  final conflictId = conflict['id'] as String;
  await _tapVisible(tester, _key('mobile-cloud-conflict-keep-local-$conflictId'));
  await _waitUntil(
    tester,
    () => _conflictCount(dbPath) == 0,
    seconds: 120,
    reason: '保留本机后冲突应被解决',
  );
  await _tap(tester, _key('mobile-cloud-conflict-close'));
  await tester.pumpAndSettle();
  await _syncNow(tester);
  await _waitUntil(
    tester,
    () => _outboxCount(dbPath) == 0,
    seconds: 180,
    reason: '冲突处理后的操作应上传完成',
  );
  expect(_conflictCount(dbPath), 0, reason: '冲突应已收敛');
  final title = _taskTitleById(dbPath, conflict['entity_id'] as String);
  expect(title, contains(_offlineSuffix), reason: '保留本机后本地标题应保持');
  debugPrint('[E2E-CLOUD] conflict resolved keepLocal title=$title');
}

// ---------------------------------------------------------------------------
// UI 操作辅助
// ---------------------------------------------------------------------------

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _openCloudPage(WidgetTester tester) async {
  if (_key('mobile-cloud-page').evaluate().isNotEmpty) return;
  await _tap(tester, _key('mobile-cloud-entry'));
  await _waitFor(tester, _key('mobile-cloud-page'), seconds: 60);
}

Future<void> _syncNow(WidgetTester tester) async {
  final button = _key('mobile-cloud-sync-now');
  if (button.evaluate().isEmpty) {
    // 尚未关联账号时同步按钮可能不存在：交给断言暴露。
    expect(button, findsWidgets, reason: '账号页应有「立即同步」');
    return;
  }
  await tester.ensureVisible(button.first);
  await tester.pumpAndSettle();
  await tester.tap(button.first);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets, reason: '找不到可点击控件');
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder.first);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets, reason: '找不到可点击控件');
  await tester.tap(finder.first);
  // 云同步/登录过程中可能出现持续动画（进度圈），不要用 pumpAndSettle，
  // 否则会一直等到超时；用固定节拍推进，后续条件由 _waitUntil 轮询。
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _doubleTapDay(WidgetTester tester, LocalDate date) async {
  final cell = _key('mobile-day-${date.iso}');
  await tester.tap(cell.first);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(cell.first);
  await tester.pumpAndSettle();
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int seconds = 30,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 200));
      return;
    }
  }
  throw TestFailure('等待控件超时（${seconds}s）：$finder');
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate, {
  int seconds = 60,
  String reason = '',
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (predicate()) {
      await tester.pump(const Duration(milliseconds: 200));
      return;
    }
  }
  throw TestFailure('等待条件超时（${seconds}s）：$reason');
}

// ---------------------------------------------------------------------------
// 真实 SQLite 只读断言
// ---------------------------------------------------------------------------

String _dateIso(int offsetDays) =>
    LocalDate.today().addDays(offsetDays).iso;

Future<String> _dbPath() async => _dbPathSync();

String _dbPathSync() {
  final dataDirectory = p.join(_baseDir, 'data');
  final workspace = CloudWorkspaceStore(dataDirectory).activeDatabasePath();
  return workspace ?? p.join(dataDirectory, 'app.db');
}

Database _open(String path) => sqlite3.open(path);

Map<String, Object?>? _taskByTitleSuffix(String dbPath, String suffix) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT id, title FROM planner_tasks WHERE deleted_at IS NULL '
      'AND title LIKE ? ORDER BY created_at DESC LIMIT 1',
      <Object?>['%$suffix'],
    );
    return rows.isEmpty ? null : rows.first;
  } finally {
    db.close();
  }
}

String? _taskIdByTitle(String dbPath, String title) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT id FROM planner_tasks WHERE title = ? AND deleted_at IS NULL '
      'ORDER BY created_at DESC LIMIT 1',
      <Object?>[title],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  } finally {
    db.close();
  }
}

String? _taskTitleById(String dbPath, String id) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT title FROM planner_tasks WHERE id = ? LIMIT 1',
      <Object?>[id],
    );
    return rows.isEmpty ? null : rows.first['title'] as String;
  } finally {
    db.close();
  }
}

bool _taskDone(String dbPath, String id) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT status, completed_at FROM planner_tasks WHERE id = ? LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return false;
    return rows.first['status'] == 'done' &&
        rows.first['completed_at'] != null;
  } finally {
    db.close();
  }
}

bool _taskDeleted(String dbPath, String title) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT deleted_at FROM planner_tasks WHERE title = ? '
      'ORDER BY created_at DESC LIMIT 1',
      <Object?>[title],
    );
    return rows.isNotEmpty && rows.first['deleted_at'] != null;
  } finally {
    db.close();
  }
}

String? _projectIdByName(String dbPath, String name) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT id FROM projects WHERE name = ? AND deleted_at IS NULL LIMIT 1',
      <Object?>[name],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  } finally {
    db.close();
  }
}

String? _projectColor(String dbPath, String name) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT color FROM projects WHERE name = ? AND deleted_at IS NULL LIMIT 1',
      <Object?>[name],
    );
    return rows.isEmpty ? null : rows.first['color'] as String;
  } finally {
    db.close();
  }
}

String? _spanIdByTitle(String dbPath, String title) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT id FROM plan_spans WHERE title = ? AND deleted_at IS NULL LIMIT 1',
      <Object?>[title],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  } finally {
    db.close();
  }
}

String? _spanStatus(String dbPath, String title) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT status FROM plan_spans WHERE title = ? AND deleted_at IS NULL LIMIT 1',
      <Object?>[title],
    );
    return rows.isEmpty ? null : rows.first['status'] as String;
  } finally {
    db.close();
  }
}

String? _noteBody(String dbPath, String iso) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT body FROM daily_notes WHERE date = ? AND deleted_at IS NULL LIMIT 1',
      <Object?>[iso],
    );
    return rows.isEmpty ? null : rows.first['body'] as String;
  } finally {
    db.close();
  }
}

int _outboxCount(String dbPath) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      "SELECT COUNT(*) AS n FROM sync_outbox WHERE state = 'pending'",
    );
    return (rows.first['n'] as int?) ?? 0;
  } finally {
    db.close();
  }
}

int _conflictCount(String dbPath) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT COUNT(*) AS n FROM sync_conflicts WHERE resolved_at IS NULL',
    );
    return (rows.first['n'] as int?) ?? 0;
  } finally {
    db.close();
  }
}

Map<String, Object?>? _firstConflict(String dbPath) {
  final db = _open(dbPath);
  try {
    final rows = db.select(
      'SELECT id, entity_id, local_payload, server_payload FROM sync_conflicts '
      'WHERE resolved_at IS NULL LIMIT 1',
    );
    return rows.isEmpty ? null : rows.first;
  } finally {
    db.close();
  }
}
