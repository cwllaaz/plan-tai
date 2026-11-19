import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/mobile/shell/mobile_navigation.dart';
import 'package:jihuatai/mobile/shell/mobile_project_nav.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

void main() {
  group('底部导航与状态保持', () {
    testWidgets('四个分区可以切换并显示各自内容', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-tab-today');
      expect(find.text('今日任务'), findsOneWidget);
      expect(find.text('逾期未完成'), findsWidgets);
      expect(find.text('收件箱'), findsWidgets);

      await tapKey(tester, 'mobile-tab-projects');
      expect(find.text('项目'), findsWidgets);

      await tapKey(tester, 'mobile-tab-me');
      expect(find.text('项目与日程 · Android'), findsOneWidget);

      await tapKey(tester, 'mobile-tab-calendar');
      expect(find.text('2026年11月'), findsOneWidget);
    });

    testWidgets('切换分区后日期选择不丢失', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapDayCell(tester, LocalDate(2026, 11, 20));
      expect(find.textContaining('11月20日 '), findsWidgets);

      await tapKey(tester, 'mobile-tab-projects');
      await tapKey(tester, 'mobile-tab-calendar');
      expect(find.textContaining('11月20日 '), findsWidgets);
    });

    testWidgets('非日历分区按返回键先回日历分区', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-tab-me');
      expect(find.text('项目与日程 · Android'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('2026年11月'), findsOneWidget);
      expect(find.text('项目与日程 · Android'), findsNothing);
    });
  });

  for (final (width, height, inset, nav) in [
    (599.0, 900.0, 0.0, 'tab'),
    (600.0, 900.0, 0.0, 'rail'),
    (601.0, 900.0, 0.0, 'rail'),
    (839.0, 800.0, 0.0, 'rail'),
    (840.0, 800.0, 0.0, 'project-nav'),
    (841.0, 800.0, 0.0, 'project-nav'),
    (840.0, 800.0, 8.0, 'rail'),
    (920.0, 519.0, 0.0, 'rail'),
    (920.0, 520.0, 0.0, 'project-nav'),
  ]) {
    testWidgets('窗口 $width×$height，侧边安全区 $inset：$nav', (tester) async {
      tester.view.viewPadding = FakeViewPadding(left: inset, bottom: 0);
      tester.view.padding = FakeViewPadding(left: inset, bottom: 0);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      final repository = await demoRepository();
      await pumpMobileApp(
        tester,
        repository: repository,
        size: Size(width, height),
        textScale: 1.3,
      );
      expect(
        find.byType(MobileBottomNav),
        nav == 'tab' ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(MobileNavRail),
        nav == 'rail' ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(MobileProjectNav),
        nav == 'project-nav' ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('跨过 600 / 840dp 保留已选日和周历偏好', (tester) async {
    final repository = await demoRepository();
    await pumpMobileApp(tester, repository: repository);
    await tapDayCell(tester, LocalDate(2026, 11, 20));
    await tapKey(tester, 'mobile-calendar-mode');
    tester.view.physicalSize = tabletLandscape;
    await tester.pumpAndSettle();
    expect(find.byType(MobileProjectNav), findsOneWidget);
    expect(find.textContaining('11月20日 '), findsOneWidget);
    tester.view.physicalSize = phoneSmall;
    await tester.pumpAndSettle();
    expect(find.text('展开整月'), findsOneWidget);
    expect(find.textContaining('11月20日 '), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('平板与横屏布局', () {
    testWidgets('平板横屏 1280×800：项目导航 + 月历 + 右侧当日面板', (
      WidgetTester tester,
    ) async {
      final repository = await demoRepository();
      await pumpMobileApp(
        tester,
        repository: repository,
        size: tabletLandscape,
      );

      expect(find.byType(MobileProjectNav), findsOneWidget);
      expect(find.byType(MobileBottomNav), findsNothing);
      expect(find.byType(MobileNavRail), findsNothing);
      // 右侧当日面板带每日备注。
      expect(find.text('当日备注'), findsOneWidget);
      expect(find.text('2026年11月'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('平板竖屏 800×1280：侧栏 + 上下排布，不强行三栏', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository, size: tabletPortrait);

      expect(find.byType(MobileNavRail), findsOneWidget);
      expect(find.byType(MobileProjectNav), findsNothing);
      expect(find.byType(MobileBottomNav), findsNothing);
      expect(find.text('当日备注'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('600dp 宽度使用侧栏导航', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository, size: mediumWidth);
      expect(find.byType(MobileNavRail), findsOneWidget);
      expect(find.byType(MobileBottomNav), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机横屏 915×412 降级为单栏 + 侧栏，不挤压三栏', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(
        tester,
        repository: repository,
        size: const Size(915, 412),
      );
      expect(find.byType(MobileProjectNav), findsNothing);
      expect(find.byType(MobileNavRail), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('小屏横屏 800×412 不溢出', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(
        tester,
        repository: repository,
        size: const Size(800, 412),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('平板三栏下点击项目导航打开项目详情', (WidgetTester tester) async {
      final repository = await demoRepository();
      final projects = await repository.watchProjects().first;
      final project = projects.first;
      await pumpMobileApp(
        tester,
        repository: repository,
        size: tabletLandscape,
      );

      await tapVisibleKey(tester, 'mobile-nav-project-${project.id}');
      expect(find.text(project.name), findsWidgets);
      expect(find.text('安排'), findsOneWidget);
    });

    testWidgets('平板三栏下切换分区保留月历选中日期', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(
        tester,
        repository: repository,
        size: tabletLandscape,
      );

      await tapDayCell(tester, LocalDate(2026, 11, 20));
      expect(find.textContaining('11月20日 '), findsWidgets);

      await tapKey(tester, 'mobile-nav-today');
      expect(find.text('今日任务'), findsOneWidget);
      await tapKey(tester, 'mobile-nav-calendar');
      expect(find.textContaining('11月20日 '), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
