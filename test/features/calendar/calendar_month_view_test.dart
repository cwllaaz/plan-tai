import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/contracts/contracts.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/core/theme/theme.dart';
import 'package:jihuatai/features/calendar/calendar_month_view.dart';
import 'package:jihuatai/features/calendar/calendar_style.dart';
import 'package:jihuatai/features/calendar/month_grid.dart';
import 'package:jihuatai/features/calendar/span_bar.dart';
import 'package:material_ui/material_ui.dart';

/// 记录月历向上层抛出的回调，断言"什么时候只选中、什么时候才开面板"。
class CalendarEvents {
  final List<LocalDate> selected = <LocalDate>[];
  final List<LocalDate> opened = <LocalDate>[];
  final List<(LocalDate, LocalDate)> ranges = <(LocalDate, LocalDate)>[];
  final List<PlanSpan> openedSpans = <PlanSpan>[];
}

void main() {
  final today = LocalDate(2026, 11, 14); // 周六

  Future<CalendarEvents> pumpCalendar(
    WidgetTester tester, {
    required PlannerRepository repository,
    LocalDate? month,
    LocalDate? selectedDate,
    LocalDate? todayValue,
    Size canvasSize = const Size(1400, 840),
  }) async {
    final visibleMonth = month ?? LocalDate(2026, 11, 1);
    final todayDate = todayValue ?? today;
    final selected = selectedDate ?? todayDate;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = CalendarEvents();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: canvasSize.width,
              height: canvasSize.height,
              child: CalendarMonthView(
                repository: repository,
                month: visibleMonth,
                today: todayDate,
                selectedDate: selected,
                onSelectDate: events.selected.add,
                onOpenDay: events.opened.add,
                onRangeSelected: (start, end) =>
                    events.ranges.add((start, end)),
                onOpenSpan: events.openedSpans.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return events;
  }

  Finder dayCell(String iso) => find.byKey(ValueKey<String>('day-$iso'));

  BoxDecoration badgeDecoration(WidgetTester tester, String iso) {
    final container = tester.widget<Container>(
      find.byKey(ValueKey<String>('day-badge-$iso')),
    );
    return container.decoration! as BoxDecoration;
  }

  Color cellBackground(WidgetTester tester, String iso) {
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(of: dayCell(iso), matching: find.byType(DecoratedBox))
          .first,
    );
    return (box.decoration as BoxDecoration).color!;
  }

  /// 点格子左下角的空白区（避开日期数字与任务行）。
  Offset emptySpot(WidgetTester tester, String iso) =>
      tester.getRect(dayCell(iso)).bottomLeft + const Offset(36, -10);

  Future<void> doubleTap(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(position);
    await tester.pumpAndSettle();
  }

  group('整月网格', () {
    testWidgets('渲染七列星期表头、本月全部日期与相邻月补齐日期', (tester) async {
      final repository = InMemoryPlannerRepository();
      await pumpCalendar(tester, repository: repository);

      for (final label in <String>['日', '一', '二', '三', '四', '五', '六']) {
        expect(find.text(label), findsOneWidget);
      }

      for (var day = 1; day <= 30; day++) {
        expect(
          dayCell('2026-11-${day.toString().padLeft(2, '0')}'),
          findsOneWidget,
          reason: '11 月 $day 日应该出现在网格里',
        );
      }

      // 周日起始：11 月 1 日是周日，网格延伸到 12 月 5 日。
      expect(dayCell('2026-12-05'), findsOneWidget);
      expect(dayCell('2026-10-31'), findsNothing);
    });

    testWidgets('今天用实底圆形、选中日期用描边，非本月日期降级为灰字', (tester) async {
      final repository = InMemoryPlannerRepository();
      await pumpCalendar(
        tester,
        repository: repository,
        month: LocalDate(2026, 12, 1),
        selectedDate: LocalDate(2026, 12, 10),
      );

      final todayBadge = badgeDecoration(tester, '2026-12-10');
      expect(todayBadge.shape, BoxShape.circle);
      expect(todayBadge.color, AppColors.surface);
      expect(todayBadge.border!.top.color, AppColors.accent);

      // 11 月 14 日不在 12 月视图里，网格里的 11 月 29 日是非本月日期。
      final outsideBox = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('day-badge-2026-11-29')),
          matching: find.byType(Text),
        ),
      );
      expect(outsideBox.style!.color, AppColors.textDisabled);
      expect(
        cellBackground(tester, '2026-11-29'),
        CalendarPalette.outsideMonth,
      );
    });

    testWidgets('选中格用 accentSoft 底 + 左侧 accent 竖线', (tester) async {
      final repository = InMemoryPlannerRepository();
      await pumpCalendar(
        tester,
        repository: repository,
        selectedDate: LocalDate(2026, 11, 20),
      );

      expect(cellBackground(tester, '2026-11-20'), CalendarPalette.selected);
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: dayCell('2026-11-20'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final border = (box.decoration as BoxDecoration).border! as Border;
      expect(border.left.color, AppColors.accent);
      expect(border.left.width, 2);
    });

    testWidgets('月份切换响应传入的 visibleMonth', (tester) async {
      final repository = InMemoryPlannerRepository();
      await pumpCalendar(tester, repository: repository);
      expect(dayCell('2026-11-20'), findsOneWidget);

      await pumpCalendar(
        tester,
        repository: repository,
        month: LocalDate(2026, 12, 1),
      );

      expect(dayCell('2026-12-01'), findsOneWidget);
      expect(dayCell('2026-12-31'), findsOneWidget);
      expect(dayCell('2026-11-20'), findsNothing);
    });

    testWidgets('空数据时不崩、显示空态文案、所有日期格子仍然完整', (tester) async {
      final repository = InMemoryPlannerRepository();
      await pumpCalendar(tester, repository: repository);

      expect(find.text('本月暂无安排'), findsOneWidget);
      expect(dayCell('2026-11-01'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窗口较窄（约 1100×700）时 7 列不横向滚动、无布局溢出', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '项目甲', color: ProjectColor.blue),
      );
      for (var i = 0; i < 12; i++) {
        await repository.createTask(
          PlannerTaskDraft(
            title: '密集任务 $i',
            projectId: project.id,
            scheduledDate: LocalDate(2026, 11, 18),
            timeSlot: TimeSlot.at(hour: 9),
          ),
        );
      }
      await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '跨天阶段一',
          startDate: LocalDate(2026, 11, 2),
          endDate: LocalDate(2026, 11, 12),
        ),
      );

      await pumpCalendar(
        tester,
        repository: repository,
        canvasSize: const Size(1044, 644),
      );

      expect(tester.takeException(), isNull);
      expect(dayCell('2026-11-01'), findsOneWidget);
      // 当天 12 条任务放不下 → 折叠计数必须出现，而不是把格子撑破。
      expect(find.textContaining('项'), findsWidgets);
      expect(find.text('密集任务 12'), findsNothing);
    });

    testWidgets('格子很窄（抽屉展开）时收起任务时间，只留标题', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '项目甲', color: ProjectColor.blue),
      );
      await repository.createTask(
        PlannerTaskDraft(
          title: '侧边栏展开时的任务',
          projectId: project.id,
          scheduledDate: LocalDate(2026, 11, 18),
          timeSlot: TimeSlot.at(hour: 9),
        ),
      );

      await pumpCalendar(
        tester,
        repository: repository,
        canvasSize: const Size(660, 700),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('侧边栏展开时的任务'), findsOneWidget);
      expect(find.text('09:00'), findsNothing);
    });
  });

  group('日期交互', () {
    testWidgets('单击只选中，双击才展开当日', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final spot = emptySpot(tester, '2026-11-20');
      await tester.tapAt(spot);
      await tester.pumpAndSettle();

      expect(events.selected, <LocalDate>[LocalDate(2026, 11, 20)]);
      expect(events.opened, isEmpty);

      await doubleTap(tester, spot);
      expect(events.opened, <LocalDate>[LocalDate(2026, 11, 20)]);
    });

    testWidgets('单击相邻月日期会交出那一天（由外壳决定是否翻月）', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(
        tester,
        repository: repository,
        month: LocalDate(2026, 12, 1),
      );

      await tester.tapAt(emptySpot(tester, '2026-11-29'));
      await tester.pumpAndSettle();

      expect(events.selected, <LocalDate>[LocalDate(2026, 11, 29)]);
    });

    testWidgets('今天不在可见月内也能正常渲染', (tester) async {
      final repository = InMemoryPlannerRepository();
      await pumpCalendar(
        tester,
        repository: repository,
        month: LocalDate(2027, 3, 1),
      );

      expect(
        find.byKey(const ValueKey<String>('day-2027-03-01')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('单日任务', () {
    testWidgets('显示时间、标题与项目色，单击选中、双击开面板', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '产品官网改版', color: ProjectColor.blue),
      );
      final task = await repository.createTask(
        PlannerTaskDraft(
          title: '信息架构评审',
          projectId: project.id,
          scheduledDate: LocalDate(2026, 11, 18),
          timeSlot: TimeSlot.at(hour: 9, durationMinutes: 60),
        ),
      );

      final events = await pumpCalendar(tester, repository: repository);

      expect(find.text('信息架构评审'), findsOneWidget);
      expect(find.text('09:00'), findsOneWidget);

      final taskFinder = find.byKey(ValueKey<String>('task-${task.id}'));
      await tester.tap(taskFinder);
      await tester.pumpAndSettle();
      expect(events.selected, <LocalDate>[LocalDate(2026, 11, 18)]);
      expect(events.opened, isEmpty);

      await doubleTap(tester, tester.getRect(taskFinder).center);
      expect(events.opened, <LocalDate>[LocalDate(2026, 11, 18)]);
    });

    testWidgets('同一天多条任务按契约顺序展示，完成态有删除线', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '客户交付', color: ProjectColor.teal),
      );
      await repository.createTask(
        PlannerTaskDraft(
          title: '下午的评审',
          projectId: project.id,
          scheduledDate: LocalDate(2026, 11, 19),
          timeSlot: TimeSlot.at(hour: 15),
        ),
      );
      await repository.createTask(
        PlannerTaskDraft(
          title: '早上的对齐',
          projectId: project.id,
          scheduledDate: LocalDate(2026, 11, 19),
          timeSlot: TimeSlot.at(hour: 9),
          status: TaskStatus.done,
        ),
      );

      await pumpCalendar(tester, repository: repository);

      expect(find.text('早上的对齐'), findsOneWidget);
      expect(find.text('下午的评审'), findsOneWidget);

      final doneText = tester.widget<Text>(find.text('早上的对齐'));
      expect(doneText.style!.decoration, TextDecoration.lineThrough);
      expect(
        tester.getRect(find.text('早上的对齐')).top,
        lessThan(tester.getRect(find.text('下午的评审')).top),
      );
    });

    testWidgets('当天任务超过 3 条时折叠为 +N 项，点击打开当日', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '个人成长', color: ProjectColor.amber),
      );
      for (var i = 1; i <= 12; i++) {
        await repository.createTask(
          PlannerTaskDraft(
            title: '任务 $i',
            projectId: project.id,
            scheduledDate: LocalDate(2026, 11, 17),
            timeSlot: TimeSlot.at(hour: 8 + i % 8),
          ),
        );
      }

      final events = await pumpCalendar(tester, repository: repository);

      expect(find.text('+9 项'), findsOneWidget);
      expect(find.text('任务 4'), findsNothing);
      expect(find.text('任务 12'), findsNothing);

      await tester.tap(find.text('+9 项'));
      await tester.pumpAndSettle();
      expect(events.opened, <LocalDate>[LocalDate(2026, 11, 17)]);
    });
  });

  group('跨天阶段横条', () {
    testWidgets('连续多天的阶段画成一条横跨多格的条，并显示阶段标题', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '机械臂项目', color: ProjectColor.purple),
      );
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '机械臂无序抓取开发',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
        ),
      );

      await pumpCalendar(tester, repository: repository);

      expect(find.text('机械臂无序抓取开发'), findsOneWidget);
      final bar = find.byKey(ValueKey<String>('span-${span.id}-2026-11-01'));
      expect(bar, findsOneWidget);

      final cellWidth = tester.getRect(dayCell('2026-11-01')).width;
      expect(tester.getRect(bar).width, greaterThan(cellWidth * 4));
    });

    testWidgets('跨周阶段按周切段，第二段标记为"延续"', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '竞赛方案', color: ProjectColor.purple),
      );
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '竞赛方案打磨',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 20),
        ),
      );

      await pumpCalendar(tester, repository: repository);

      expect(find.byType(SpanBar), findsNWidgets(3));
      expect(
        find.byKey(ValueKey<String>('span-${span.id}-2026-11-08')),
        findsOneWidget,
      );
      // 三段共享同一个阶段标题，但只有第一段有真实起点。
      final first = tester.widget<SpanBar>(
        find.byKey(ValueKey<String>('span-${span.id}-2026-11-01')),
      );
      final second = tester.widget<SpanBar>(
        find.byKey(ValueKey<String>('span-${span.id}-2026-11-08')),
      );
      expect(first.segment.beginsHere, isTrue);
      expect(first.segment.endsHere, isFalse);
      expect(second.segment.beginsHere, isFalse);
      expect(second.segment.continuesBefore, isTrue);
    });

    testWidgets('点击跨天条交出阶段起始日（跨月段也一样）', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '竞赛方案', color: ProjectColor.purple),
      );
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '期中汇报准备',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 20),
        ),
      );

      final events = await pumpCalendar(tester, repository: repository);

      final secondSegment = find.byKey(
        ValueKey<String>('span-${span.id}-2026-11-08'),
      );
      await tester.tap(secondSegment);
      await tester.pumpAndSettle();

      expect(events.selected, <LocalDate>[LocalDate(2026, 11, 3)]);
      expect(events.opened, isEmpty);
    });

    testWidgets('相互重叠的阶段最多两条车道，超出折叠为本周 +N', (tester) async {
      final repository = InMemoryPlannerRepository();
      final projectA = await repository.createProject(
        const ProjectDraft(name: '项目甲', color: ProjectColor.blue),
      );
      final projectB = await repository.createProject(
        const ProjectDraft(name: '项目乙', color: ProjectColor.green),
      );
      await repository.createSpan(
        PlanSpanDraft(
          projectId: projectA.id,
          title: '阶段 A',
          startDate: LocalDate(2026, 11, 2),
          endDate: LocalDate(2026, 11, 6),
        ),
      );
      await repository.createSpan(
        PlanSpanDraft(
          projectId: projectB.id,
          title: '阶段 B',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
        ),
      );
      await repository.createSpan(
        PlanSpanDraft(
          projectId: projectA.id,
          title: '阶段 C',
          startDate: LocalDate(2026, 11, 4),
          endDate: LocalDate(2026, 11, 5),
        ),
      );

      await pumpCalendar(tester, repository: repository);

      expect(find.byType(SpanBar), findsNWidgets(2));
      expect(find.text('阶段 C'), findsNothing);
      // 折叠提示只出现在每周最后一列（11 月 7 日，周六）。
      expect(
        find.descendant(of: dayCell('2026-11-07'), matching: find.text('+1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dayCell('2026-11-04'), matching: find.text('+1')),
        findsNothing,
      );
    });

    testWidgets('跨月阶段在两个月里都不丢失起止关系', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '交付项目', color: ProjectColor.teal),
      );
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '验收冲刺',
          startDate: LocalDate(2026, 11, 27),
          endDate: LocalDate(2026, 12, 4),
        ),
      );

      await pumpCalendar(
        tester,
        repository: repository,
        month: LocalDate(2026, 12, 1),
      );

      // 12 月网格从 11 月 29 日开始，整条阶段落在网格内，只有一段且带延续标记。
      final bar = tester.widget<SpanBar>(
        find.byKey(ValueKey<String>('span-${span.id}-2026-11-29')),
      );
      expect(bar.segment.continuesBefore, isTrue);
      expect(bar.segment.endsHere, isTrue);
    });

    testWidgets('双击跨天条才打开编辑，单击仍然只选中起始日', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '项目甲', color: ProjectColor.blue),
      );
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '可编辑安排',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
        ),
      );

      final events = await pumpCalendar(tester, repository: repository);

      final bar = find.byKey(
        ValueKey<String>('span-${span.id}-2026-11-01'),
      );
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(events.selected, <LocalDate>[LocalDate(2026, 11, 3)]);
      expect(events.openedSpans, isEmpty);

      await tester.tap(bar);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(events.openedSpans.map((item) => item.id), <String>[span.id]);
    });

    testWidgets('阶段自带颜色优先于项目颜色', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '蓝色项目', color: ProjectColor.blue),
      );
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '红色安排',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
          color: ProjectColor.red,
        ),
      );

      await pumpCalendar(tester, repository: repository);

      final bar = tester.widget<SpanBar>(
        find.byKey(ValueKey<String>('span-${span.id}-2026-11-01')),
      );
      expect(bar.color, ProjectColor.red);
    });
  });

  group('可访问性与空态', () {
    testWidgets('日期格子带中文无障碍标签', (tester) async {
      final handle = tester.ensureSemantics();

      final repository = InMemoryPlannerRepository();
      await pumpCalendar(tester, repository: repository);

      expect(find.bySemanticsLabel(RegExp('今天')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('11月14日 周六，今天')), findsOneWidget);
      handle.dispose();
    });
  });

  group('右键拖选日期区间', () {
    testWidgets('拖过几天出现选择框，松手交出起止日', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final from = tester.getRect(dayCell('2026-11-25')).center;
      final to = tester.getRect(dayCell('2026-11-28')).center;
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();

      // 拖动过程中：框与"几天"提示都在，且还没有回调。
      expect(
        find.byKey(const ValueKey<String>('calendar-range-box')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('calendar-range-hint')),
        findsOneWidget,
      );
      expect(find.text('11月25日 – 11月28日 · 4 天'), findsOneWidget);
      expect(events.ranges, isEmpty);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(events.ranges, <(LocalDate, LocalDate)>[
        (LocalDate(2026, 11, 25), LocalDate(2026, 11, 28)),
      ]);
      expect(
        find.byKey(const ValueKey<String>('calendar-range-box')),
        findsNothing,
      );
      // 右键拖选不改变"选中日"，也不开面板。
      expect(events.selected, isEmpty);
      expect(events.opened, isEmpty);
    });

    testWidgets('反向拖（从后往前）也按先后顺序交出区间', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final gesture = await tester.startGesture(
        tester.getRect(dayCell('2026-11-28')).center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await gesture.moveTo(tester.getRect(dayCell('2026-11-25')).center);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(events.ranges, <(LocalDate, LocalDate)>[
        (LocalDate(2026, 11, 25), LocalDate(2026, 11, 28)),
      ]);
    });

    testWidgets('跨周的区间按周折返：选中连续日期，而不是首尾两列的矩形', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final gesture = await tester.startGesture(
        tester.getRect(dayCell('2026-11-20')).center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await gesture.moveTo(tester.getRect(dayCell('2026-11-24')).center);
      await tester.pump();

      final overlay = tester.widget<CalendarRangeOverlay>(
        find.byKey(const ValueKey<String>('calendar-range-box')),
      );
      final cellWidth = tester.getRect(dayCell('2026-11-20')).width;

      // 两段：周五–周六，然后周日–周二。中间是整块连着的。
      expect(overlay.runs, hasLength(2));
      expect(overlay.runs[0].left, closeTo(5 * cellWidth + 1, 0.6));
      expect(overlay.runs[0].right, closeTo(7 * cellWidth - 1, 0.6));
      expect(overlay.runs[1].left, closeTo(1, 0.6));
      expect(overlay.runs[1].right, closeTo(3 * cellWidth - 1, 0.6));
      // 两段之间不能有缝，否则看起来像两个框。
      expect(overlay.runs[0].bottom, overlay.runs[1].top);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(events.ranges, <(LocalDate, LocalDate)>[
        (LocalDate(2026, 11, 20), LocalDate(2026, 11, 24)),
      ]);
    });

    testWidgets('11/3 拖到 11/11：高亮的是 3–11 这 9 个连续日期', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final gesture = await tester.startGesture(
        tester.getRect(dayCell('2026-11-03')).center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await gesture.moveTo(tester.getRect(dayCell('2026-11-11')).center);
      await tester.pump();

      expect(find.text('11月3日 – 11月11日 · 9 天'), findsOneWidget);

      final overlay = tester.widget<CalendarRangeOverlay>(
        find.byKey(const ValueKey<String>('calendar-range-box')),
      );
      final cellWidth = tester.getRect(dayCell('2026-11-03')).width;

      // 第一周从周二铺到周六（3–7），第二周从周日铺到周三（8–11）。
      expect(overlay.runs, hasLength(2));
      expect(overlay.runs[0].left, closeTo(2 * cellWidth + 1, 0.6));
      expect(overlay.runs[0].right, closeTo(7 * cellWidth - 1, 0.6));
      expect(overlay.runs[1].left, closeTo(1, 0.6));
      // 11 月 11 日是周三 → 第二段铺到第 3 列为止。
      expect(overlay.runs[1].right, closeTo(4 * cellWidth - 1, 0.6));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(events.ranges, <(LocalDate, LocalDate)>[
        (LocalDate(2026, 11, 3), LocalDate(2026, 11, 11)),
      ]);
    });

    testWidgets('左键拖动不会触发区间选择', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final gesture = await tester.startGesture(
        tester.getRect(dayCell('2026-11-25')).center,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(tester.getRect(dayCell('2026-11-28')).center);
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('calendar-range-box')),
        findsNothing,
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(events.ranges, isEmpty);
    });

    testWidgets('右键单击（不拖）不会弹区间回调', (tester) async {
      final repository = InMemoryPlannerRepository();
      final events = await pumpCalendar(tester, repository: repository);

      final gesture = await tester.startGesture(
        tester.getRect(dayCell('2026-11-25')).center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(events.ranges, isEmpty);
    });
  });
}
