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
      expect(find.text('11月20日'), findsWidgets);

      await tapKey(tester, 'mobile-tab-projects');
      await tapKey(tester, 'mobile-tab-calendar');
      expect(find.text('11月20日'), findsWidgets);
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
      expect(find.text('11月20日'), findsWidgets);

      await tapKey(tester, 'mobile-nav-today');
      expect(find.text('今日任务'), findsOneWidget);
      await tapKey(tester, 'mobile-nav-calendar');
      expect(find.text('11月20日'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
