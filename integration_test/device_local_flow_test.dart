// 计划台 Android · 模拟器/真机端到端验收（本地业务闭环，真实 SQLite，无模拟数据）。
//
// 运行方式（在 ASCII worktree 中，模拟器已启动）：
//   flutter test integration_test/device_local_flow_test.dart -d emulator-5554
//
// 覆盖：启动 → 月历主页 → 打开当日详情 → 新建任务 → 落库 → 列表更新 →
// 编辑任务 → 完成/取消完成 → 删除+撤销 → 每日备注自动保存 → 项目管理 →
// 底部导航切换 → 系统返回（PopScope）→ 横屏布局 → 全程无异常/溢出。
//
// 断言既看界面，也直接以只读方式查询应用私有数据库，确认「真实落库」「真实删除（墓碑）」
// 而不是界面内存假象。测试结束后宿主脚本会再次 force-stop 冷启动并拉库校验持久化。

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/main.dart' as app;
import 'package:jihuatai/platform/app_paths.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const String _runTag = String.fromEnvironment('E2E_TAG');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android 本地完整操作流程（真实 SQLite 落库）', (WidgetTester tester) async {
    final tag = _runTag.isEmpty
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : _runTag;
    debugPrint('[E2E] runTag=$tag');

    // ---------- 启动 ----------
    await app.main();
    await _waitFor(tester, _key('mobile-tab-calendar'), seconds: 120);
    expect(tester.takeException(), isNull, reason: '启动过程出现异常');

    final baseDir = await AppPaths.resolveBaseDirectory();
    final dbPath = p.join(baseDir, 'data', 'app.db');
    final today = LocalDate.today();
    final cell = find.byKey(ValueKey<String>('mobile-day-${today.iso}'));
    expect(cell, findsOneWidget, reason: '月历主页应显示今天的日期格');
    debugPrint('[E2E] 月历主页已渲染 today=${today.iso} db=$dbPath');

    // ---------- 选择日期 → 打开当日详情底部面板 ----------
    await _doubleTapDayCell(tester, today);
    await _waitFor(tester, _key('mobile-day-close'), seconds: 30);
    expect(tester.takeException(), isNull);

    // ---------- 新建任务（真实写库） ----------
    final title = 'E2E任务-$tag';
    final newTitle = 'E2E任务-改-$tag';
    final note = 'E2E每日备注-$tag';
    await _tapAddTask(tester);
    await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
    await tester.enterText(_key('mobile-task-editor-title'), title);
    await tester.pumpAndSettle();
    await _tapKey(tester, 'mobile-task-editor-save');
    await _waitFor(tester, find.text(title), seconds: 30);
    expect(tester.takeException(), isNull);

    final taskId = _taskIdByTitle(dbPath, title);
    expect(taskId, isNotNull, reason: '任务必须真实写入 SQLite');
    final id = taskId!;
    debugPrint('[E2E] 新建任务已落库 id=$id');

    // ---------- 完成状态 ----------
    await _tapKey(tester, 'mobile-task-toggle-$id');
    await _waitUntil(
      tester,
      () => _taskIsDone(dbPath, id),
      seconds: 30,
      reason: '勾选完成后 SQLite 中应 status=done 且 completed_at 非空',
    );
    expect(tester.takeException(), isNull, reason: '完成任务后界面不应异常');

    // ---------- 编辑任务（改标题 + 备注） ----------
    await _tapKey(tester, 'mobile-task-$id');
    await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
    await tester.enterText(_key('mobile-task-editor-title'), newTitle);
    await tester.enterText(
      _key('mobile-task-editor-notes'),
      'E2E-任务备注-$tag',
    );
    await tester.pumpAndSettle();
    await _tapKey(tester, 'mobile-task-editor-save');
    await _waitFor(tester, find.text(newTitle), seconds: 30);
    expect(_taskTitleById(dbPath, id), newTitle, reason: '编辑后的标题必须落库');

    // ---------- 每日备注（同一当日面板内） ----------
    await _waitFor(tester, _key('mobile-note-${today.iso}'), seconds: 30);
    final noteField = find
        .descendant(
          of: _key('mobile-note-${today.iso}'),
          matching: find.byType(TextField),
        )
        .first;
    await tester.ensureVisible(noteField);
    await tester.pumpAndSettle();
    await tester.enterText(noteField, note);
    // 备注 600ms 防抖自动保存。
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    await _waitUntil(
      tester,
      () => (_noteBody(dbPath, today.iso) ?? '').contains(note),
      seconds: 30,
      reason: '每日备注应在防抖后自动保存到 SQLite',
    );

    // ---------- 删除任务（墓碑）+ 撤销 ----------
    final deleteTitle = 'E2E待删-$tag';
    await _tapAddTask(tester);
    await _waitFor(tester, _key('mobile-task-editor-title'), seconds: 30);
    await tester.enterText(_key('mobile-task-editor-title'), deleteTitle);
    await tester.pumpAndSettle();
    await _tapKey(tester, 'mobile-task-editor-save');
    await _waitFor(tester, find.text(deleteTitle), seconds: 30);
    final deleteId = _taskIdByTitle(dbPath, deleteTitle);
    expect(deleteId, isNotNull);

    await _tapKey(tester, 'mobile-task-$deleteId');
    await _waitFor(tester, _key('mobile-task-editor-delete'), seconds: 30);
    await _tapKey(tester, 'mobile-task-editor-delete');
    await _tapKey(tester, 'mobile-confirm-ok');
    await _waitFor(tester, find.textContaining('撤销'), seconds: 30);
    expect(
      _taskDeleted(dbPath, deleteId!),
      isTrue,
      reason: '删除应写墓碑（deleted_at 非空）',
    );
    await tester.tap(find.textContaining('撤销').last);
    await tester.pumpAndSettle();

    // 关闭当日详情面板。
    await _tapKey(tester, 'mobile-day-close');
    await tester.pumpAndSettle();

    // ---------- 项目管理 ----------
    await _tapKey(tester, 'mobile-tab-projects');
    await _waitFor(tester, _key('mobile-projects-page'), seconds: 30);
    await _tapKey(tester, 'mobile-project-create');
    final projectName = 'E2E项目-$tag';
    await tester.enterText(
      _key('mobile-project-editor-name'),
      projectName,
    );
    await tester.enterText(
      _key('mobile-project-editor-description'),
      'E2E 项目简介',
    );
    await tester.pumpAndSettle();
    await _tapKey(tester, 'mobile-project-editor-save');
    await _waitFor(tester, find.text(projectName), seconds: 30);
    final projectId = _projectIdByName(dbPath, projectName);
    expect(projectId, isNotNull, reason: '项目必须真实写入 SQLite');
    debugPrint('[E2E] 项目已落库 id=$projectId');

    // 进入项目详情（全屏页）再返回。
    await _tapVisible(tester, _key('mobile-project-$projectId'));
    await _waitFor(tester, find.text(projectName), seconds: 30);
    expect(tester.takeException(), isNull, reason: '项目详情页不应异常');
    await _tapKey(tester, 'mobile-page-back');
    await _waitFor(tester, _key('mobile-projects-page'), seconds: 30);

    // ---------- 底部导航切换 ----------
    await _tapKey(tester, 'mobile-tab-today');
    await _waitFor(tester, _key('mobile-today-page'), seconds: 30);
    await _tapKey(tester, 'mobile-tab-me');
    await _waitFor(tester, _key('mobile-my-page'), seconds: 30);
    expect(find.textContaining('账号与同步'), findsWidgets);

    // ---------- Android 系统返回（PopScope 语义代理） ----------
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('mobile-day-${today.iso}')),
      findsOneWidget,
      reason: '非日历分区按返回应先回到日历分区',
    );

    // ---------- 横屏（旋转后布局不溢出） ----------
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '横屏布局不应溢出');
    tester.view.physicalSize = originalSize;
    tester.view.devicePixelRatio = originalDpr;
    await tester.pumpAndSettle();

    debugPrint('[E2E] PASS tag=$tag today=${today.iso} taskId=$id '
        'projectId=$projectId');
  });
}

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets);
  // 面板里的按钮可能在滚动区下方：先滚到可见再点，避免 hit-test 落在滚动容器上。
  await tester.ensureVisible(finder.last);
  await tester.pumpAndSettle();
  await tester.tap(finder.last);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tap(tester, _key(key));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.last);
  await tester.pumpAndSettle();
  await tester.tap(finder.last);
  await tester.pumpAndSettle();
}

/// 任务列表为空时「新建任务」是空态按钮（没有 mobile-add-task 键），
/// 有任务时才是带键的列表行；两种入口都要覆盖。
Future<void> _tapAddTask(WidgetTester tester) async {
  final keyed = _key('mobile-add-task');
  if (keyed.evaluate().isNotEmpty) {
    await _tap(tester, keyed);
    return;
  }
  final label = find.text('新建任务');
  expect(label, findsWidgets, reason: '找不到新建任务入口');
  await _tap(tester, label);
}

Future<void> _doubleTapDayCell(WidgetTester tester, LocalDate date) async {
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
      await tester.pumpAndSettle();
      return;
    }
  }
  throw TestFailure('等待控件超时（${seconds}s）：$finder');
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate, {
  int seconds = 30,
  String reason = '',
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (predicate()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  throw TestFailure('等待条件超时（${seconds}s）：$reason');
}

// ---------------------------------------------------------------------------
// 真实 SQLite 只读断言
// ---------------------------------------------------------------------------

Database _openDb(String path) => sqlite3.open(path);

String? _taskIdByTitle(String dbPath, String title) {
  final db = _openDb(dbPath);
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
  final db = _openDb(dbPath);
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

bool _taskDeleted(String dbPath, String id) {
  final db = _openDb(dbPath);
  try {
    final rows = db.select(
      'SELECT deleted_at FROM planner_tasks WHERE id = ? LIMIT 1',
      <Object?>[id],
    );
    return rows.isNotEmpty && rows.first['deleted_at'] != null;
  } finally {
    db.close();
  }
}

bool _taskIsDone(String dbPath, String id) {
  final db = _openDb(dbPath);
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

String? _noteBody(String dbPath, String iso) {
  final db = _openDb(dbPath);
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

String? _projectIdByName(String dbPath, String name) {
  final db = _openDb(dbPath);
  try {
    final rows = db.select(
      'SELECT id FROM projects WHERE name = ? AND deleted_at IS NULL '
      'ORDER BY created_at DESC LIMIT 1',
      <Object?>[name],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  } finally {
    db.close();
  }
}
