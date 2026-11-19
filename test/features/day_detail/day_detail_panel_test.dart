import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/contracts/contracts.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/core/theme/theme.dart';
import 'package:jihuatai/features/day_detail/day_detail_panel.dart';
import 'package:material_ui/material_ui.dart';

final LocalDate _today = LocalDate(2026, 11, 14);

// -----------------------------------------------------------------------------
// 测试脚手架
// -----------------------------------------------------------------------------

class _PanelHarness extends StatefulWidget {
  const _PanelHarness({
    super.key,
    required this.repository,
    required this.today,
    required this.initialDate,
  });

  final PlannerRepository repository;
  final LocalDate today;
  final LocalDate initialDate;

  @override
  State<_PanelHarness> createState() => _PanelHarnessState();
}

class _PanelHarnessState extends State<_PanelHarness> {
  late LocalDate _date = widget.initialDate;
  bool _open = true;

  /// 模拟外壳重新打开抽屉（面板会重新走一遍初始化 + 订阅）。
  void reopen() => setState(() => _open = true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 420,
          height: double.infinity,
          child: _open
              ? DayDetailPanel(
                  repository: widget.repository,
                  date: _date,
                  today: widget.today,
                  onClose: () => setState(() => _open = false),
                  onDateChange: (LocalDate date) =>
                      setState(() => _date = date),
                )
              : const Center(child: Text('面板已关闭')),
        ),
      ),
    );
  }
}

Future<_PanelHarnessState> _pumpPanel(
  WidgetTester tester,
  PlannerRepository repository, {
  LocalDate? date,
  LocalDate? today,
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final key = GlobalKey<_PanelHarnessState>();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: _PanelHarness(
        key: key,
        repository: repository,
        today: today ?? _today,
        initialDate: date ?? _today,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

Future<PlannerTask> _addTask(
  PlannerRepository repository, {
  required String title,
  LocalDate? date,
  int? hour,
  int durationMinutes = 30,
  TaskPriority priority = TaskPriority.normal,
  TaskStatus status = TaskStatus.todo,
  String notes = '',
}) {
  return repository.createTask(
    PlannerTaskDraft(
      title: title,
      scheduledDate: date ?? _today,
      timeSlot: hour == null
          ? null
          : TimeSlot.at(hour: hour, durationMinutes: durationMinutes),
      priority: priority,
      status: status,
      notes: notes,
    ),
  );
}

TextField _noteField(WidgetTester tester) => tester.widget<TextField>(
  find.byKey(const ValueKey<String>('day-note-field')),
);

Finder _noteFinder() => find.byKey(const ValueKey<String>('day-note-field'));

/// 只让写操作失败的仓储装饰器：用来验证"保存失败时的反馈"。
class _FailingRepository implements PlannerRepository {
  _FailingRepository(this._inner, {this.failOn = const <String>{}});

  final PlannerRepository _inner;
  final Set<String> failOn;

  Never _fail() => throw const PlannerValidationException('写库失败：磁盘已满');

  @override
  Stream<List<Project>> watchProjects({bool includeArchived = false}) =>
      _inner.watchProjects(includeArchived: includeArchived);

  @override
  Future<Project?> findProject(String id) => _inner.findProject(id);

  @override
  Stream<List<PlannerTask>> watchTasksInRange(LocalDateRange range) =>
      _inner.watchTasksInRange(range);

  @override
  Stream<List<PlannerTask>> watchUnscheduledTasks() =>
      _inner.watchUnscheduledTasks();

  @override
  Stream<List<PlannerTask>> watchTasksForProject(String projectId) =>
      _inner.watchTasksForProject(projectId);

  @override
  Stream<List<PlannerTask>> watchAllTasks() => _inner.watchAllTasks();

  @override
  Stream<PlannerTask?> watchTask(String id) => _inner.watchTask(id);

  @override
  Future<PlannerTask?> findTask(String id) => _inner.findTask(id);

  @override
  Future<List<PlannerTask>> tasksInRange(LocalDateRange range) =>
      _inner.tasksInRange(range);

  @override
  Stream<List<PlanSpan>> watchSpansInRange(LocalDateRange range) =>
      _inner.watchSpansInRange(range);

  @override
  Stream<List<PlanSpan>> watchSpansForProject(String projectId) =>
      _inner.watchSpansForProject(projectId);

  @override
  Stream<PlanSpan?> watchSpan(String id) => _inner.watchSpan(id);

  @override
  Future<PlanSpan?> findSpan(String id) => _inner.findSpan(id);

  @override
  Stream<DailyNote?> watchDailyNote(LocalDate date) =>
      _inner.watchDailyNote(date);

  @override
  Future<DailyNote?> findDailyNote(LocalDate date) =>
      _inner.findDailyNote(date);

  @override
  Future<Project> createProject(ProjectDraft draft) async {
    if (failOn.contains('createProject')) _fail();
    return _inner.createProject(draft);
  }

  @override
  Future<Project> updateProject(Project project) async {
    if (failOn.contains('updateProject')) _fail();
    return _inner.updateProject(project);
  }

  @override
  Future<void> deleteProject(String id) async {
    if (failOn.contains('deleteProject')) _fail();
    return _inner.deleteProject(id);
  }

  @override
  Future<PlannerTask> createTask(PlannerTaskDraft draft) async {
    if (failOn.contains('createTask')) _fail();
    return _inner.createTask(draft);
  }

  @override
  Future<PlannerTask> updateTask(PlannerTask task) async {
    if (failOn.contains('updateTask')) _fail();
    return _inner.updateTask(task);
  }

  @override
  Future<void> deleteTask(String id) async {
    if (failOn.contains('deleteTask')) _fail();
    return _inner.deleteTask(id);
  }

  @override
  Future<PlanSpan> createSpan(PlanSpanDraft draft) async {
    if (failOn.contains('createSpan')) _fail();
    return _inner.createSpan(draft);
  }

  @override
  Future<PlanSpan> updateSpan(PlanSpan span) async {
    if (failOn.contains('updateSpan')) _fail();
    return _inner.updateSpan(span);
  }

  @override
  Future<void> deleteSpan(String id) async {
    if (failOn.contains('deleteSpan')) _fail();
    return _inner.deleteSpan(id);
  }

  @override
  Future<DailyNote> saveDailyNote(
    LocalDate date, {
    String body = '',
    List<String> focusItems = const <String>[],
  }) async {
    if (failOn.contains('saveDailyNote')) _fail();
    return _inner.saveDailyNote(date, body: body, focusItems: focusItems);
  }

  @override
  Future<void> close() => _inner.close();
}

// -----------------------------------------------------------------------------
// 用例
// -----------------------------------------------------------------------------

void main() {
  testWidgets('空日期：显示空态、0% 进度与新建入口', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _pumpPanel(tester, repository);

    expect(
      find.byKey(const ValueKey<String>('day-detail-empty')),
      findsOneWidget,
    );
    expect(find.text('今天还没有安排'), findsOneWidget);
    expect(find.text('完成 0/0'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('day-detail-empty-create')),
      findsOneWidget,
    );
    expect(find.text('还没有备注'), findsOneWidget);
  });

  testWidgets('一天 14 条任务：分组计数正确、列表可滚动且不溢出', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    for (var i = 0; i < 14; i++) {
      await _addTask(repository, title: '任务 $i', hour: i);
    }
    await _pumpPanel(tester, repository);

    expect(find.text('今日安排'), findsOneWidget);
    expect(find.text('14 项'), findsOneWidget);
    expect(find.text('完成 0/14'), findsOneWidget);
    expect(find.text('任务 0'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -1600));
    await tester.pumpAndSettle();
    expect(find.text('任务 13'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无时间任务沉到「未安排时间」分组', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _addTask(repository, title: '写周报', hour: 9);
    await _addTask(repository, title: '整理想法');
    await _addTask(repository, title: '预约体检');
    await _pumpPanel(tester, repository);

    expect(find.text('今日安排'), findsOneWidget);
    expect(find.text('未安排时间'), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    expect(find.text('整理想法'), findsOneWidget);
    expect(find.text('预约体检'), findsOneWidget);
  });

  testWidgets('修改任务标题写回仓储', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final task = await _addTask(repository, title: '旧标题', hour: 9);
    await _pumpPanel(tester, repository);

    await tester.tap(find.text('旧标题'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('task-editor-title')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('task-editor-title')),
      '新标题',
    );
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('新标题'), findsOneWidget);
    expect(find.text('旧标题'), findsNothing);
    expect((await repository.findTask(task.id))!.title, '新标题');
  });

  testWidgets('新建任务默认落在当前日期并可只填标题', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _pumpPanel(tester, repository);

    await tester.tap(
      find.byKey(const ValueKey<String>('day-detail-empty-create')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('task-editor-title')),
      '买菜',
    );
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('买菜'), findsOneWidget);
    final tasks = await repository.tasksInRange(
      LocalDateRange.singleDay(_today),
    );
    expect(tasks, hasLength(1));
    expect(tasks.single.title, '买菜');
    expect(tasks.single.scheduledDate, _today);
    expect(tasks.single.timeSlot, isNull);
  });

  testWidgets('勾选完成后进度与仓储同步，取消勾选可回退', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final task = await _addTask(repository, title: '今天要做', hour: 9);
    await _pumpPanel(tester, repository);

    final tile = find.byKey(ValueKey<String>('task-tile-${task.id}'));
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();

    expect((await repository.findTask(task.id))!.status, TaskStatus.done);
    expect(find.text('完成 1/1'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(
      find.descendant(of: tile, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect((await repository.findTask(task.id))!.status, TaskStatus.todo);
    expect(find.text('完成 0/1'), findsOneWidget);
  });

  testWidgets('删除任务提供撤销，撤销后任务回到当天', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final task = await _addTask(repository, title: '可删任务', hour: 9);
    await _pumpPanel(tester, repository);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('可删任务')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey<String>('task-delete-${task.id}')));
    await tester.pumpAndSettle();

    expect(find.text('可删任务'), findsNothing);
    expect(find.text('已删除「可删任务」'), findsOneWidget);
    expect(
      await repository.tasksInRange(LocalDateRange.singleDay(_today)),
      isEmpty,
    );

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(find.text('可删任务'), findsOneWidget);
    expect(
      await repository.tasksInRange(LocalDateRange.singleDay(_today)),
      hasLength(1),
    );

    // 提示条不应一直挂在界面上。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.textContaining('已恢复'), findsNothing);
  });

  testWidgets('编辑器内删除任务', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final task = await _addTask(repository, title: '编辑器删除', hour: 9);
    await _pumpPanel(tester, repository);

    await tester.tap(find.text('编辑器删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-delete')));
    await tester.pumpAndSettle();

    expect((await repository.findTask(task.id)), isNull);
    expect(find.text('编辑器删除'), findsNothing);
  });

  testWidgets('改项目与优先级、清空固定时间、改日期', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final project = await repository.createProject(
      const ProjectDraft(name: '产品官网改版'),
    );
    final task = await _addTask(repository, title: '可编辑任务', hour: 9);
    await _pumpPanel(tester, repository);

    await tester.tap(find.text('可编辑任务'));
    await tester.pumpAndSettle();

    // 优先级：普通 → 紧急
    await tester.tap(
      find.byKey(const ValueKey<String>('task-editor-priority')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧急').last);
    await tester.pumpAndSettle();

    // 项目：未归项目 → 产品官网改版
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-project')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('产品官网改版').last);
    await tester.pumpAndSettle();

    // 取消固定时间
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey<String>('task-editor-${task.id}')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('不排具体时间，当天完成即可'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('task-editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.findTask(task.id))!;
    expect(stored.priority, TaskPriority.urgent);
    expect(stored.projectId, project.id);
    expect(stored.timeSlot, isNull);
    expect(find.text('产品官网改版'), findsOneWidget);
  });

  testWidgets('把任务改到后一天后从列表消失并提示', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final task = await _addTask(repository, title: '要挪走的任务', hour: 9);
    await _pumpPanel(tester, repository);

    await tester.tap(find.text('要挪走的任务'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('task-editor-date-next')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('要挪走的任务'), findsNothing);
    expect(find.textContaining('已移到'), findsOneWidget);
    expect(
      (await repository.findTask(task.id))!.scheduledDate,
      _today.addDays(1),
    );
  });

  testWidgets('无效时间输入会被拦截且不写库', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _pumpPanel(tester, repository);

    await tester.tap(
      find.byKey(const ValueKey<String>('day-detail-empty-create')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('task-editor-title')),
      '带时间的任务',
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('task-editor-new')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('task-editor-start')),
      '10:00',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('task-editor-end')),
      '09:00',
    );
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('结束时间必须晚于开始时间'), findsOneWidget);
    expect(
      await repository.tasksInRange(LocalDateRange.singleDay(_today)),
      isEmpty,
    );
  });

  testWidgets('切换日期会加载新日期任务，且不把旧备注写到新日期', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _addTask(
      repository,
      title: '昨天的任务',
      date: _today.addDays(-1),
      hour: 9,
    );
    await _pumpPanel(tester, repository);

    await tester.enterText(_noteFinder(), '今天的笔记');
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();

    expect(find.text('昨天的任务'), findsOneWidget);
    expect(find.text('11月13日 周五'), findsOneWidget);
    expect((await repository.findDailyNote(_today))?.body, '今天的笔记');
    expect((await repository.findDailyNote(_today.addDays(-1))), isNull);
    expect(_noteField(tester).controller!.text, isEmpty);
  });

  testWidgets('每日备注防抖自动保存并显示已保存', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _pumpPanel(tester, repository);

    await tester.enterText(_noteFinder(), '今天把信息架构过完');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect((await repository.findDailyNote(_today))?.body, '今天把信息架构过完');
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('关闭时立即落库未保存的备注，重新打开后仍在', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _addTask(repository, title: '买牛奶', hour: 9);
    final harness = await _pumpPanel(tester, repository);

    await tester.enterText(_noteFinder(), '关闭前没等防抖');
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('面板已关闭'), findsOneWidget);
    expect((await repository.findDailyNote(_today))?.body, '关闭前没等防抖');

    harness.reopen();
    await tester.pumpAndSettle();

    expect(find.text('买牛奶'), findsOneWidget);
    expect(find.text('关闭前没等防抖'), findsOneWidget);
  });

  testWidgets('仓储写入失败时给出明确错误提示', (WidgetTester tester) async {
    final inner = InMemoryPlannerRepository();
    final repository = _FailingRepository(
      inner,
      failOn: <String>{'createTask'},
    );
    await _pumpPanel(tester, repository);

    await tester.tap(
      find.byKey(const ValueKey<String>('day-detail-empty-create')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('task-editor-title')),
      '写不进去的任务',
    );
    await tester.tap(find.byKey(const ValueKey<String>('task-editor-save')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('task-editor-error')),
      findsOneWidget,
    );
    expect(find.textContaining('写库失败'), findsOneWidget);
    expect(await inner.tasksInRange(LocalDateRange.singleDay(_today)), isEmpty);
  });

  testWidgets('备注保存失败时显示失败状态并可重试', (WidgetTester tester) async {
    final inner = InMemoryPlannerRepository();
    final repository = _FailingRepository(
      inner,
      failOn: <String>{'saveDailyNote'},
    );
    await _pumpPanel(tester, repository);

    await tester.enterText(_noteFinder(), '会失败的备注');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.text('保存失败 · 重试'), findsOneWidget);
    expect((await inner.findDailyNote(_today)), isNull);
  });

  testWidgets('已有备注在打开面板时回填', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await repository.saveDailyNote(
      _today,
      body: '上午评审，下午写方案。',
      focusItems: const <String>['信息架构', '权限方案'],
    );
    await _pumpPanel(tester, repository);

    expect(_noteField(tester).controller!.text, '上午评审，下午写方案。');
    expect(find.text('信息架构'), findsOneWidget);
    expect(find.text('权限方案'), findsOneWidget);
    expect(find.text('自动保存'), findsOneWidget);
  });

  testWidgets('跨到当天的阶段显示在头部，可滚动时间轴仍可用', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final project = await repository.createProject(
      const ProjectDraft(name: '客户交付 · 星河'),
    );
    await repository.createSpan(
      PlanSpanDraft(
        projectId: project.id,
        title: '权限模型联调',
        startDate: _today.addDays(-2),
        endDate: _today.addDays(2),
      ),
    );
    await _addTask(repository, title: '联调准备', hour: 10);
    await _pumpPanel(tester, repository);

    expect(find.text('权限模型联调'), findsOneWidget);
    expect(find.text('联调准备'), findsOneWidget);
  });

  testWidgets('编辑始终可见，删除只在悬停时出现', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    final task = await _addTask(repository, title: '悬停任务', hour: 9);
    await _pumpPanel(tester, repository);

    expect(
      find.byKey(ValueKey<String>('task-edit-${task.id}')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('task-delete-${task.id}')),
      findsNothing,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('悬停任务')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('task-edit-${task.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('task-delete-${task.id}')),
      findsOneWidget,
    );

    await gesture.moveTo(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('task-delete-${task.id}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('task-edit-${task.id}')),
      findsOneWidget,
    );
  });

  testWidgets('当日重点可新增并随备注一起保存', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    await _pumpPanel(tester, repository);

    await tester.tap(find.text('添加重点'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('day-note-focus-field')),
      '写完评审稿',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.text('写完评审稿'), findsOneWidget);
    final note = await repository.findDailyNote(_today);
    expect(note?.focusItems, <String>['写完评审稿']);
  });

  testWidgets('最小窗口高度下列表仍可滚动且不溢出', (WidgetTester tester) async {
    final repository = InMemoryPlannerRepository();
    for (var i = 0; i < 8; i++) {
      await _addTask(repository, title: '窄屏任务 $i', hour: i);
    }
    await _pumpPanel(tester, repository, size: const Size(420, 600));

    expect(tester.takeException(), isNull);
    expect(find.text('今日安排'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('窄屏任务 7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
