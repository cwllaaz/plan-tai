import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

void main() {
  group('每日任务', () {
    testWidgets('选中日任务列表显示演示数据并统计完成率', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      // 11 月 14 日的任务在下方摘要里可见（可滚动）。
      expect(find.text('信息架构草案评审'), findsWidgets);
      expect(find.textContaining('完成 1 项'), findsWidgets);
    });

    testWidgets('勾选完成会写回仓储', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      final tasks = await repository.tasksInRange(
        LocalDateRange.singleDay(testToday),
      );
      final target = tasks.firstWhere(
        (PlannerTask task) => task.title == '信息架构草案评审',
      );
      expect(target.isDone, isFalse);

      await tapVisibleKey(tester, 'mobile-task-toggle-${target.id}');
      final updated = await repository.findTask(target.id);
      expect(updated, isNotNull);
      expect(updated!.isDone, isTrue);
      expect(updated.completedAt, isNotNull);

      // 再点一次取消完成。
      await tapVisibleKey(tester, 'mobile-task-toggle-${target.id}');
      final reverted = await repository.findTask(target.id);
      expect(reverted!.isDone, isFalse);
    });

    testWidgets('新建任务：输入标题保存后出现在当天列表', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapVisibleKey(tester, 'mobile-add-task');
      expect(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        '把手动新建的任务写进列表',
      );
      await tester.pumpAndSettle();
      await tapVisibleKey(tester, 'mobile-task-editor-save');

      final tasks = await repository.tasksInRange(
        LocalDateRange.singleDay(testToday),
      );
      expect(
        tasks.where((PlannerTask task) => task.title == '把手动新建的任务写进列表'),
        hasLength(1),
      );
      expect(find.text('把手动新建的任务写进列表'), findsWidgets);
    });

    testWidgets('标题为空时就地报错，不关闭面板', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapVisibleKey(tester, 'mobile-add-task');
      await tapVisibleKey(tester, 'mobile-task-editor-save');
      expect(find.text('请填写任务标题'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        findsOneWidget,
      );
    });

    testWidgets('编辑任务标题与优先级后写回仓储', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      final tasks = await repository.tasksInRange(
        LocalDateRange.singleDay(testToday),
      );
      final target = tasks.firstWhere(
        (PlannerTask task) => task.title == '信息架构草案评审',
      );

      await tapVisibleKey(tester, 'mobile-task-${target.id}');
      await tester.enterText(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        '信息架构评审（已改名）',
      );
      await tester.pumpAndSettle();
      await tapVisibleKey(tester, 'mobile-task-editor-priority-3');
      await tapVisibleKey(tester, 'mobile-task-editor-save');

      final updated = await repository.findTask(target.id);
      expect(updated!.title, '信息架构评审（已改名）');
      expect(updated.priority, TaskPriority.urgent);
    });

    testWidgets('删除任务后可以撤销恢复', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      final tasks = await repository.tasksInRange(
        LocalDateRange.singleDay(testToday),
      );
      final target = tasks.firstWhere(
        (PlannerTask task) => task.title == '信息架构草案评审',
      );

      await tapVisibleKey(tester, 'mobile-task-${target.id}');
      await tapVisibleKey(tester, 'mobile-task-editor-delete');
      await tapKey(tester, 'mobile-confirm-ok');

      expect(await repository.findTask(target.id), isNull);
      expect(find.textContaining('已删除'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();

      final restored = await repository.tasksInRange(
        LocalDateRange.singleDay(testToday),
      );
      expect(
        restored.where((PlannerTask task) => task.title == '信息架构草案评审'),
        hasLength(1),
      );
    });

    testWidgets('每日备注 600ms 防抖自动保存', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-day-expand');
      final noteField = find.byKey(const ValueKey<String>('day-note-field'));
      await tester.scrollUntilVisible(
        noteField,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.enterText(noteField, '手机端写下的当日备注');
      await settleFor(tester, const Duration(milliseconds: 750));

      final note = await repository.findDailyNote(testToday);
      expect(note, isNotNull);
      expect(note!.body, '手机端写下的当日备注');
    });

    testWidgets('切日期时未保存的备注会先落库', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-day-expand');
      final noteField = find.byKey(const ValueKey<String>('day-note-field'));
      await tester.scrollUntilVisible(
        noteField,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.enterText(noteField, '来不及等防抖就切走');
      // 不等待 600ms，直接切到后一天。
      await tapKey(tester, 'mobile-day-next');
      await settleFor(tester, const Duration(milliseconds: 100));

      final note = await repository.findDailyNote(testToday);
      expect(note?.body, '来不及等防抖就切走');
    });

    testWidgets('未安排时间的任务单独分组', (WidgetTester tester) async {
      final repository = InMemoryPlannerRepository();
      await repository.createTask(
        PlannerTaskDraft(title: '没有固定时间的任务', scheduledDate: testToday),
      );
      await repository.createTask(
        PlannerTaskDraft(
          title: '九点整的会议',
          scheduledDate: testToday,
          timeSlot: TimeSlot.at(hour: 9),
        ),
      );
      await pumpMobileApp(tester, repository: repository);

      expect(find.text('未安排时间'), findsOneWidget);
      expect(find.text('没有固定时间的任务'), findsWidgets);
      expect(find.text('九点整的会议'), findsWidgets);
    });

    testWidgets('空任务状态显示引导文案', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapDayCell(tester, LocalDate(2026, 11, 25));
      expect(find.text('这一天还没有任务'), findsOneWidget);
    });

    testWidgets('键盘弹出时编辑面板不溢出', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapVisibleKey(tester, 'mobile-add-task');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('有未保存改动时取消会二次确认', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapVisibleKey(tester, 'mobile-add-task');
      await tester.enterText(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        '写了一半就返回',
      );
      await tester.pumpAndSettle();
      await tapVisibleKey(tester, 'mobile-task-editor-cancel');
      expect(find.text('放弃这次编辑？'), findsOneWidget);

      // 取消放弃：面板仍在，草稿还在。
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        findsOneWidget,
      );
    });
  });
}
