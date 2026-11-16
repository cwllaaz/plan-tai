import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/contracts/contracts.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/mobile/mobile_app.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

/// 手机 / 平板界面截图（golden 渲染，加载系统中文字体后输出 PNG）。
///
/// 生成/更新：`flutter test --no-pub --update-goldens test/mobile/mobile_screenshots_test.dart`
/// 产物：`test/mobile/goldens/*.png`。
///
/// 没有系统中文字体的机器会跳过这些用例（避免截图里全是方块）。
void main() {
  var fontLoaded = false;

  setUpAll(() async {
    fontLoaded = await loadChineseTestFont();
  });

  Future<void> pumpForGolden(
    WidgetTester tester, {
    required PlannerRepository repository,
    Size size = phone,
  }) async {
    useViewSize(tester, size);
    await tester.pumpWidget(
      RepaintBoundary(
        child: MobileApp(
          repository: repository,
          isDemoData: true,
          today: testToday,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('手机主页截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository);
    await shoot(tester, 'phone-01-home');
  });

  testWidgets('手机紧凑周历截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository);
    await tapKey(tester, 'mobile-calendar-mode');
    await shoot(tester, 'phone-02-week');
  });

  testWidgets('手机当日面板截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository);
    await doubleTapDayCell(tester, testToday);
    await shoot(tester, 'phone-03-day-sheet');
  });

  testWidgets('手机今日分区截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository);
    await tapKey(tester, 'mobile-tab-today');
    await shoot(tester, 'phone-04-today');
  });

  testWidgets('手机项目分区截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository);
    await tapKey(tester, 'mobile-tab-projects');
    await shoot(tester, 'phone-05-projects');
  });

  testWidgets('手机项目详情截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    final projects = await repository.watchProjects().first;
    final project = projects.firstWhere(
      (Project item) => item.name == '产品官网改版',
    );
    await pumpForGolden(tester, repository: repository);
    await tapKey(tester, 'mobile-tab-projects');
    await tapVisibleKey(tester, 'mobile-project-${project.id}');
    await shoot(tester, 'phone-06-project-detail');
  });

  testWidgets('手机我的分区截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository);
    await tapKey(tester, 'mobile-tab-me');
    await shoot(tester, 'phone-07-me');
  });

  testWidgets('平板横屏三栏截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository, size: tabletLandscape);
    await shoot(tester, 'tablet-01-landscape');
  });

  testWidgets('平板竖屏截图', (WidgetTester tester) async {
    if (!fontLoaded) return;
    final repository = await demoRepository();
    await pumpForGolden(tester, repository: repository, size: tabletPortrait);
    await shoot(tester, 'tablet-02-portrait');
  });
}
