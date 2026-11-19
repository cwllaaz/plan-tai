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
      expect(find.textContaining('11月14日 '), findsWidgets);
    });

    testWidgets('单击日期切换下方任务列表，双击打开当日面板', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapDayCell(tester, LocalDate(2026, 11, 15));
      expect(find.textContaining('11月15日 '), findsWidgets);
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

    testWidgets('窄屏放大字体仍显示跨周标题，且不挡选日或任务计数', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '小车项目'),
      );
      const title = '周末安排：联调并确认小车可以稳定完成全程';
      final sunday = LocalDate(2026, 11, 15);
      final span = await repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: title,
          startDate: testToday.addDays(-1),
          endDate: sunday.addDays(1),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await repository.createTask(
          PlannerTaskDraft(title: '调试任务 $i', scheduledDate: sunday),
        );
      }
      await pumpMobileApp(
        tester,
        repository: repository,
        size: phoneNarrow,
        textScale: 1.3,
      );

      final first = find.byKey(
        ValueKey('mobile-spanbar-${span.id}-2026-11-08'),
      );
      final second = find.byKey(
        ValueKey('mobile-spanbar-${span.id}-2026-11-15'),
      );
      final sundayCell = find.byKey(ValueKey('mobile-day-${sunday.iso}'));
      for (final bar in [first, second]) {
        final label = find.descendant(of: bar, matching: find.text(title));
        expect(label, findsOneWidget);
        expect(tester.widget<Text>(label).overflow, TextOverflow.ellipsis);
      }
      final band = tester.getRect(second);
      final date = find.descendant(of: sundayCell, matching: find.text('15'));
      final count = find.descendant(of: sundayCell, matching: find.text('+1'));
      expect(tester.getRect(date).bottom, lessThan(band.top));
      expect(tester.getRect(count).top, greaterThanOrEqualTo(band.bottom));
      await tester.tapAt(
        Offset(tester.getCenter(sundayCell).dx, band.center.dy),
      );
      await settleFor(tester, const Duration(milliseconds: 350));
      expect(tester.widget<MobileMonthCell>(sundayCell).isSelected, isTrue);

      await tapKey(tester, 'mobile-calendar-mode');
      expect(first, findsNothing);
      expect(
        find.descendant(of: second, matching: find.text(title)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('空间足够的月份显示两条重叠安排的标题', (tester) async {
      final repository = InMemoryPlannerRepository();
      final project = await repository.createProject(
        const ProjectDraft(name: '小车项目'),
      );
      final spans = <PlanSpan>[
        for (final title in ['第一段：轨迹检查', '第二段：实车联调'])
          await repository.createSpan(
            PlanSpanDraft(
              projectId: project.id,
              title: title,
              startDate: LocalDate(2026, 11, 16),
              endDate: LocalDate(2026, 11, 18),
            ),
          ),
      ];
      await pumpMobileApp(
        tester,
        repository: repository,
        size: tabletLandscape,
      );

      final bands = [
        for (final span in spans)
          find.byKey(ValueKey('mobile-spanbar-${span.id}-2026-11-15')),
      ];
      for (var i = 0; i < bands.length; i++) {
        expect(
          find.descendant(of: bands[i], matching: find.text(spans[i].title)),
          findsOneWidget,
        );
      }
      expect(
        tester.getRect(bands.first).overlaps(tester.getRect(bands.last)),
        isFalse,
      );
    });

    testWidgets('收起为周历后只显示一周，再展开恢复整月', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      expect(find.byType(MobileMonthCell), findsNWidgets(35));
      await tapKey(tester, 'mobile-calendar-mode');
      expect(find.byType(MobileMonthCell), findsNWidgets(7));
      // 周历副标题显示当前周范围。
      expect(find.text('11/8 – 11/14'), findsOneWidget);
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
      expect(find.textContaining('12月5日 '), findsWidgets);
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
        for (var day = 1; day <= 7; day++) {
          final iso = LocalDate(2026, 11, day).iso;
          expect(
            find.byKey(ValueKey('mobile-day-$iso')).hitTestable(),
            findsOneWidget,
          );
        }
        final today = find.byKey(ValueKey('mobile-day-${testToday.iso}'));
        expect(tester.widget<MobileMonthCell>(today).isToday, isTrue);
        expect(tester.widget<MobileMonthCell>(today).isSelected, isTrue);
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
        const ProjectDraft(name: '这是一条很长的中文项目名称用于验证窄屏放大字体时不挤出任务列表'),
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
      await pumpMobileApp(
        tester,
        repository: repository,
        size: phoneNarrow,
        textScale: 1.3,
      );

      // 月历格子里有折叠计数（超过 2 个任务显示 +N）。
      expect(find.text('+16').hitTestable(), findsOneWidget);
      expect(find.byTooltip('新建任务').hitTestable(), findsOneWidget);

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
