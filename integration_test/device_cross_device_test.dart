// 计划台 Android · 真实云端「跨端 ↔ 离线 ↔ 冲突」单次运行端到端验收。
//
// 为什么是单次运行：`flutter test integration_test -d <device>` 在测试结束后会卸载应用，
// 应用私有目录（真实 SQLite + Keystore 令牌）随之清空。因此本测试在**一次应用进程**内
// 完成完整用户旅程；与宿主脚本之间通过应用私有目录里的两个信号文件协调：
//   - 测试写 `files/e2e_test_signal`（宿主用 adb run-as 读）；
//   - 宿主写 `files/e2e_host_signal`（测试轮询读）。
// 宿主同时扮演「Windows 对端」并控制 PocketBase 启停，从而在同一设备上真实复现：
//   Windows 创建上传 → Android 登录下载 → Android 修改上传 → Windows 拉取并删除/改色/改阶段/改备注
//   → Android 拉取 → 双端离线改同一记录 → 冲突不静默丢失 → 保留本机收敛
//   → 服务器停机后 Android 离线修改 → 恢复后补传 → Windows 最终一致 + 幂等。
//
// 运行由 `scripts/android/e2e_real_server_device.ps1` 自动完成（不要手动单独跑本文件）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jihuatai/app/cloud_workspace.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/main.dart' as app;
import 'package:jihuatai/platform/app_paths.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

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
const String _task = 'Windows创建任务';
const String _task2 = 'Windows待删任务';
const String _project = '跨端项目';
const String _span = '跨端阶段';
const String _note = 'Windows每日备注';
const String _androidTitle = '$_task-Android改';
const String _localConflictTitle = '$_task-本地冲突版';
const String _offlineTitle = '$_task-离线改';

String _baseDir = '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实云端跨端旅程（单次运行）', (WidgetTester tester) async {
    await app.main();
    await _waitFor(tester, _key('mobile-tab-calendar'), seconds: 120);
    _baseDir = await AppPaths.resolveBaseDirectory();
    expect(tester.takeException(), isNull, reason: '启动异常');
    final today = LocalDate.today();
    debugPrint('[E2E-X] 启动完成 base=$_baseDir today=${today.iso}');
    // 清掉可能残留的协调信号（上一次运行/宿主早到）。
    for (final file in <File>[_hostSignal, _testSignal]) {
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // 忽略：信号文件只是测试协调用，不影响业务数据。
      }
    }

    // ============ 1. 首次登录 + 关联云端 + 全量下载 ============
    await _openCloudPage(tester);
    await _waitFor(tester, _key('mobile-cloud-signin-submit'), seconds: 60);
    await tester.enterText(_key('mobile-cloud-server-field'), _server);
    await tester.enterText(_key('mobile-cloud-account-field'), _account);
    await tester.enterText(_key('mobile-cloud-password-field'), _password);
    await tester.pump(const Duration(milliseconds: 200));
    final submit = _key('mobile-cloud-signin-submit');
    bool loggedIn() =>
        _key('cloud-binding-confirm').evaluate().isNotEmpty ||
        _key('mobile-cloud-account-value').evaluate().isNotEmpty;
    final loginDeadline = DateTime.now().add(const Duration(seconds: 150));
    var submitted = 0;
    while (!loggedIn() && DateTime.now().isBefore(loginDeadline)) {
      if (_key('mobile-cloud-login-error').evaluate().isNotEmpty ||
          find.textContaining('登录失败').evaluate().isNotEmpty) {
        fail('登录失败（界面已显示错误），请检查真实服务器与网络');
      }
      await tester.ensureVisible(submit.last);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(submit.last, warnIfMissed: false);
      submitted++;
      await tester.pump(const Duration(seconds: 3));
    }
    debugPrint('[E2E-X] 登录提交次数=$submitted 已登录=${loggedIn()}');
    expect(loggedIn(), isTrue, reason: '登录后应出现数据归属确认或账号信息');
    if (_key('cloud-binding-confirm').evaluate().isNotEmpty) {
      await _tap(tester, _key('cloud-binding-confirm'));
      await _waitUntil(
        tester,
        () => find.textContaining('重启').evaluate().isNotEmpty,
        seconds: 180,
        reason: '首次关联云端应提示重启后全量下载',
      );
      // 首次关联会新建账号工作区并「重启后从云端全量拉取」：进程内重现重启。
      await _restartApp(tester);
    }

    // 重启后自动同步会把云端数据全量拉到账号工作区库；直接查真实 SQLite 核对。
    String? dbPath;
    await _waitUntil(
      tester,
      () {
        final path = _dbPathSync();
        if (_taskIdByTitle(path, _task) == null) return false;
        dbPath = path;
        return true;
      },
      seconds: 240,
      reason: '重启后云端任务应全量下载到本地 SQLite',
    );
    final db = dbPath!;
    expect(_projectIdByName(db, _project), isNotNull, reason: '项目应下载');
    expect(_spanIdByTitle(db, _span), isNotNull, reason: '跨日期阶段应下载');
    expect(_noteBody(db, today.iso), contains(_note), reason: '每日备注应下载');
    debugPrint('[E2E-X] 1 下载完成 db=$db color=${_projectColor(db, _project)}');
    final textVisible = find.text(_task).evaluate().isNotEmpty;
    debugPrint('[E2E-X] 1 月历界面可见任务=$textVisible');
    await _signal(tester, 'downloaded');

    // ============ 2. Android 修改（标题/完成/备注）并上传 ============
    final taskId = _taskIdByTitle(db, _task)!;
    await _tap(tester, _key('mobile-day-${today.iso}'));
    await _waitFor(tester, find.text(_task), seconds: 60);
    await _tap(tester, _key('mobile-task-$taskId'));
    await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
    await tester.enterText(_key('mobile-task-editor-title'), _androidTitle);
    await tester.pumpAndSettle();
    await _tap(tester, _key('mobile-task-editor-save'));
    await _waitUntil(
      tester,
      () => _taskTitleById(db, taskId) == _androidTitle,
      seconds: 30,
      reason: 'Android 修改标题应落库',
    );
    await _tap(tester, _key('mobile-task-toggle-$taskId'));
    await _waitUntil(
      tester,
      () => _taskDone(db, taskId),
      seconds: 30,
      reason: 'Android 完成状态应落库',
    );
    // 每日备注
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
    await tester.enterText(noteField, 'Windows每日备注-Android改');
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    await _waitUntil(
      tester,
      () => (_noteBody(db, today.iso) ?? '').contains('-Android改'),
      seconds: 30,
      reason: 'Android 备注应落库',
    );
    await _tap(tester, _key('mobile-day-close'));
    await tester.pumpAndSettle();
    await _openCloudPage(tester);
    await _syncNow(tester);
    await _waitUntil(
      tester,
      () => _outboxCount(db) == 0,
      seconds: 180,
      reason: 'Android 修改应上传完成',
    );
    expect(_conflictCount(db), 0, reason: '正常同步不应产生冲突');
    debugPrint('[E2E-X] 2 Android 修改已上传 title=$_androidTitle');
    await _signal(tester, 'uploaded');

    // ============ 3. 拉取 Windows 端的删除/颜色/阶段/备注改动 ============
    await _waitHostSignal(tester, 'peer-verify-done', seconds: 600);
    await _syncNow(tester);
    await _waitUntil(
      tester,
      () =>
          _taskDeleted(db, _task2) &&
          _projectColor(db, _project) == '#E5484D' &&
          _spanStatus(db, _span) == 'done' &&
          (_noteBody(db, today.iso) ?? '').contains('Windows备注-改'),
      seconds: 180,
      reason: '应拉取到 Windows 对端的删除/颜色/阶段/备注改动',
    );
    debugPrint('[E2E-X] 3 Windows 改动已拉取');
    // 关闭自动同步，保证接下来的本地修改先进入 outbox（避免立即上传导致无法制造真实冲突）。
    await _setAutoSync(tester, enabled: false);
    await _signal(tester, 'windows-verified');

    // ============ 4. 真实冲突：两端改同一记录 → 不静默丢失 → 保留本机收敛 ============
    await _waitHostSignal(tester, 'conflict-ready', seconds: 300);
    await _closeCloudPage(tester);
    await _tap(tester, _key('mobile-day-${today.iso}'));
    await _tap(tester, _key('mobile-task-$taskId'));
    await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
    await tester.enterText(_key('mobile-task-editor-title'), _localConflictTitle);
    await tester.pumpAndSettle();
    await _tap(tester, _key('mobile-task-editor-save'));
    await _waitUntil(
      tester,
      () => _taskTitleById(db, taskId) == _localConflictTitle,
      seconds: 30,
      reason: '本机冲突修改应落库',
    );
    expect(_outboxCount(db), greaterThan(0), reason: '自动同步关闭时本地修改应进入 outbox');
    await _openCloudPage(tester);
    await _syncNow(tester);
    await _waitUntil(
      tester,
      () => _conflictCount(db) > 0,
      seconds: 120,
      reason: '两端改同一记录应产生冲突而不是静默覆盖',
    );
    final conflict = _firstConflict(db);
    expect(conflict, isNotNull);
    expect(conflict!['local_payload'] as String? ?? '', contains('本地冲突版'),
        reason: '冲突必须保留本机版本');
    expect(conflict['server_payload'] as String? ?? '', contains('Windows冲突版'),
        reason: '冲突必须保留云端版本');
    final conflictId = conflict['id'] as String;
    debugPrint('[E2E-X] 4 冲突已保留 local+server id=$conflictId');

    await _tapVisible(tester, _key('mobile-cloud-open-conflicts'));
    await _waitFor(tester, _key('mobile-cloud-conflict-page'), seconds: 60);
    await _tapVisible(
      tester,
      _key('mobile-cloud-conflict-keep-local-$conflictId'),
    );
    await _waitUntil(
      tester,
      () => _conflictCount(db) == 0,
      seconds: 120,
      reason: '保留本机后冲突应被解决',
    );
    await _tap(tester, _key('mobile-cloud-conflict-close'));
    await tester.pumpAndSettle();
    await _syncNow(tester);
    await _waitUntil(
      tester,
      () => _outboxCount(db) == 0,
      seconds: 180,
      reason: '冲突解决后的操作应上传完成',
    );
    expect(_taskTitleById(db, taskId), _localConflictTitle);
    debugPrint('[E2E-X] 4 冲突已收敛 keepLocal');
    await _signal(tester, 'conflict-resolved');

    // ============ 5. 服务器停机：离线修改进入 outbox，恢复网络后补传 ============
    await _waitHostSignal(tester, 'conflict-verified', seconds: 300);
    await _waitHostSignal(tester, 'offline-ready', seconds: 300);
    await _closeCloudPage(tester);
    await _tap(tester, _key('mobile-day-${today.iso}'));
    await _tap(tester, _key('mobile-task-$taskId'));
    await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
    await tester.enterText(_key('mobile-task-editor-title'), _offlineTitle);
    await tester.pumpAndSettle();
    await _tap(tester, _key('mobile-task-editor-save'));
    await _waitUntil(
      tester,
      () => _taskTitleById(db, taskId) == _offlineTitle,
      seconds: 30,
      reason: '离线编辑仍应成功落库',
    );
    await _openCloudPage(tester);
    await _syncNow(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_outboxCount(db), greaterThan(0), reason: '服务器停机时修改应留在 outbox');
    debugPrint('[E2E-X] 5 离线修改已保存 pending=${_outboxCount(db)}');
    await _signal(tester, 'offline-saved');

    // 等宿主恢复服务器后重试同步（真实用户「网络恢复后自动/手动补传」）。
    await _waitHostSignal(tester, 'online-ready', seconds: 300);
    var synced = false;
    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (DateTime.now().isBefore(deadline)) {
      await _syncNow(tester);
      await tester.pump(const Duration(seconds: 2));
      if (_outboxCount(db) == 0) {
        synced = true;
        break;
      }
    }
    expect(synced, isTrue, reason: '网络恢复后离线修改应补传完成');
    expect(_taskTitleById(db, taskId), _offlineTitle);
    debugPrint('[E2E-X] 5 离线修改已补传 title=$_offlineTitle');
    await _signal(tester, 'offline-synced');

    // ============ 6. 等 Windows 对端最终核对 ============
    await _waitHostSignal(tester, 'all-done', seconds: 420);
    // 打开自动同步，恢复默认策略。
    await _setAutoSync(tester, enabled: true);
    debugPrint('[E2E-X] PASS 全流程完成');
  });
}

// ---------------------------------------------------------------------------
/// 进程内模拟「关闭并重新打开应用」：释放旧界面/旧数据库连接，再走一遍正式组合根，
/// 从而打开首次绑定后写入指针的账号工作区库（真实用户此时会重启 App）。
Future<void> _restartApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 500));
  await app.main();
  await _waitFor(tester, _key('mobile-tab-calendar'), seconds: 120);
  _baseDir = await AppPaths.resolveBaseDirectory();
  debugPrint('[E2E-X] 重启完成 base=$_baseDir db=${_dbPathSync()}');
}

/// 宿主信号（应用私有目录）

// ---------------------------------------------------------------------------

File get _hostSignal => File(p.join(_baseDir, 'e2e_host_signal'));
File get _testSignal => File(p.join(_baseDir, 'e2e_test_signal'));

Future<void> _signal(WidgetTester tester, String marker) async {
  await _testSignal.writeAsString(marker, flush: true);
  debugPrint('[E2E-X] signal -> $marker');
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _waitHostSignal(
  WidgetTester tester,
  String marker, {
  int seconds = 300,
}) async {
  await _waitUntil(
    tester,
    () {
      try {
        return _hostSignal.readAsStringSync().trim() == marker;
      } on FileSystemException {
        return false;
      }
    },
    seconds: seconds,
    reason: '等待宿主信号 $marker',
  );
  debugPrint('[E2E-X] host signal <- $marker');
}

// ---------------------------------------------------------------------------
// UI 辅助
// ---------------------------------------------------------------------------

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _openCloudPage(WidgetTester tester) async {
  if (_key('mobile-cloud-page').evaluate().isNotEmpty) return;
  await _tap(tester, _key('mobile-cloud-entry'));
  await _waitFor(tester, _key('mobile-cloud-page'), seconds: 60);
}

Future<void> _closeCloudPage(WidgetTester tester) async {
  if (_key('mobile-cloud-page').evaluate().isEmpty) return;
  await _tap(tester, find.byTooltip('关闭'));
  await tester.pumpAndSettle();
}

Future<void> _syncNow(WidgetTester tester) async {
  final button = _key('mobile-cloud-sync-now');
  expect(button, findsWidgets, reason: '账号页应有「立即同步」');
  await tester.ensureVisible(button.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(button.last);
  await tester.pump(const Duration(milliseconds: 800));
}

Future<void> _setAutoSync(WidgetTester tester, {required bool enabled}) async {
  final toggle = _key('mobile-cloud-auto-sync');
  if (toggle.evaluate().isEmpty) {
    await _openCloudPage(tester);
  }
  await tester.ensureVisible(toggle.last);
  await tester.pump(const Duration(milliseconds: 200));
  final db = _dbPathSync();
  final current = _autoSyncEnabled(db);
  if (current != enabled) {
    await tester.tap(toggle.last);
    await tester.pump(const Duration(milliseconds: 600));
  }
  await _waitUntil(
    tester,
    () => _autoSyncEnabled(_dbPathSync()) == enabled,
    seconds: 30,
    reason: '自动同步开关应写入 sync_state',
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets, reason: '找不到可点击控件');
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _doubleTapDay(WidgetTester tester, LocalDate date) async {
  final cell = _key('mobile-day-${date.iso}');
  await tester.tap(cell.first);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(cell.first);
  await tester.pump(const Duration(milliseconds: 400));
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
  final keys = find
      .byWidgetPredicate((Widget w) => w.key is ValueKey<String>)
      .evaluate()
      .map((Element e) => (e.widget.key! as ValueKey<String>).value)
      .toSet();
  final texts = find
      .byType(Text)
      .evaluate()
      .map((Element e) => (e.widget as Text).data)
      .whereType<String>()
      .toList();
  debugPrint('[E2E-DUMP] keys=$keys');
  debugPrint('[E2E-DUMP] texts=$texts');
  throw TestFailure('等待条件超时（${seconds}s）：$reason');
}

// ---------------------------------------------------------------------------
// 真实 SQLite 只读断言
// ---------------------------------------------------------------------------

String _dbPathSync() {
  final dataDirectory = p.join(_baseDir, 'data');
  final workspace = CloudWorkspaceStore(dataDirectory).activeDatabasePath();
  return workspace ?? p.join(dataDirectory, 'app.db');
}

Database _open(String path) => sqlite3.open(path);

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
      'SELECT COUNT(*) AS n FROM sync_outbox',
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

bool _autoSyncEnabled(String dbPath) {
  final db = _open(dbPath);
  try {
    final rows = db.select('SELECT auto_sync FROM sync_state WHERE id = 1');
    if (rows.isEmpty) return true;
    return (rows.first['auto_sync'] as int?) == 1;
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
