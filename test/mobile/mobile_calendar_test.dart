import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/mobile/calendar/mobile_month_cell.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

void main() {
  group('月历主页', () {
    testWidgets('七列日期、今天与选中态、月份标题', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      expect(find.text('2026年11月'), findsOneWidget);
      // 2026 年 11 月 1 日是周日，整月正好 5 周 = 35 个日期格。
      expect(find.byType(MobileMonthCell), findsNWidgets(35));
      for (var day = 1; day <= 30; day++) {
        final iso = LocalDate(2026, 11, day).iso;
        expect(find.byKey(ValueKey<String>('mobile-day-$iso')), findsOneWidget);
      }
      // 末尾补齐的相邻月日期也可以点。
      expect(
        find.byKey(const ValueKey<String>('mobile-day-2026-12-05')),
        findsOneWidget,
      );
    });

    testWidgets('切换上/下个月与回到今天', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-prev-period');
      expect(find.text('2026年10月'), findsOneWidget);

      await tapKey(tester, 'mobile-next-period');
      await tapKey(tester, 'mobile-next-period');
      expect(find.text('2026年12月'), findsOneWidget);

      await tapKey(tester, 'mobile-today');
      expect(find.text('2026年11月'), findsOneWidget);
      // 回到今天后，下方摘要显示今天。
      expect(find.text('11月14日'), findsWidgets);
    });

    testWidgets('单击日期切换下方任务列表，双击打开当日面板', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapDayCell(tester, LocalDate(2026, 11, 15));
      expect(find.text('11月15日'), findsWidgets);
      // 演示数据在 11 月 15 日有一项「首页视觉稿 v2」。
      expect(find.text('首页视觉稿 v2'), findsWidgets);

      await doubleTapDayCell(tester, LocalDate(2026, 11, 15));
      expect(
        find.byKey(const ValueKey<String>('mobile-day-close')),
        findsOneWidget,
      );
      await tapKey(tester, 'mobile-day-close');
      expect(
        find.byKey(const ValueKey<String>('mobile-day-close')),
        findsNothing,
      );
    });

    testWidgets('跨天安排显示为月历横条', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      final spanBars = find.byWidgetPredicate((Widget widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('mobile-spanbar-');
      });
      expect(spanBars, findsWidgets);
    });

    testWidgets('收起为周历后只显示一周，再展开恢复整月', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      expect(find.byType(MobileMonthCell), findsNWidgets(35));
      await tapKey(tester, 'mobile-calendar-mode');
      expect(find.byType(MobileMonthCell), findsNWidgets(7));
      // 周历副标题显示当前周范围。
      expect(find.textContaining('周历 ·'), findsOneWidget);
      // 只有一周时仍可切换上一周/下一周。
      await tapKey(tester, 'mobile-next-period');
      expect(find.byType(MobileMonthCell), findsNWidgets(7));

      await tapKey(tester, 'mobile-calendar-mode');
      expect(find.byType(MobileMonthCell), findsNWidgets(35));
    });

    testWidgets('相邻月日期被点中时自动切到那个月', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapDayCell(tester, LocalDate(2026, 12, 5));
      expect(find.text('2026年12月'), findsOneWidget);
      expect(find.text('12月5日'), findsWidgets);
    });
  });

  group('布局与内容压力', () {
    for (final size in <Size>[
      phoneNarrow,
      phoneSmall,
      phone,
      mediumWidth,
      tabletPortrait,
      tabletLandscape,
    ]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 无布局溢出', (
        WidgetTester tester,
      ) async {
        final repository = await demoRepository();
        await pumpMobileApp(tester, repository: repository, size: size);
        expect(find.text('2026年11月'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final scale in <double>[1.15, 1.3]) {
      testWidgets('文字缩放 $scale× 时手机主页不溢出', (WidgetTester tester) async {
        final repository = await demoRepository();
        await pumpMobileApp(
          tester,
          repository: repository,
          size: phoneNarrow,
          textScale: scale,
        );
        expect(find.text('2026年11月'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('单日大量任务 + 长标题不溢出', (WidgetTester tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '长标题压力测试项目'),
      );
      for (var index = 0; index < 18; index++) {
        await repository.createTask(
          PlannerTaskDraft(
            title:
                '这是一个非常非常长的任务标题，用来验证手机小屏不会因为文字太长而溢出布局'
                '（第 ${index + 1} 条）',
            projectId: project.id,
            scheduledDate: testToday,
            timeSlot: index.isEven ? TimeSlot.at(hour: 9 + (index ~/ 2)) : null,
            priority: TaskPriority.urgent,
          ),
        );
      }
      await pumpMobileApp(tester, repository: repository, size: phoneNarrow);

      // 月历格子里有折叠计数（超过 2 个任务显示 +N）。
      expect(find.textContaining('+'), findsWidgets);

      await doubleTapDayCell(tester, testToday);
      // 面板已打开（标题栏关闭按钮可见），大量任务在面板里滚动，不溢出。
      expect(
        find.byKey(const ValueKey<String>('mobile-day-close')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
