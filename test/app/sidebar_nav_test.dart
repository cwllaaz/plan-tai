import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/app/app_scope.dart';
import 'package:jihuatai/app/app_shell.dart';
import 'package:jihuatai/app/shell_state.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/core/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// 侧栏（surfaceSunken 底）上的 hover 底色：墨色 6% 压深的浅灰。
///
/// 与 lib/app/app_shell.dart 里的 `_sunkenHoverColor` 是同一个推导；
/// 这里是回归断言，故意重算一遍而不是导出私有常量。
Color get _expectedHoverBase => Color.alphaBlend(
  AppColors.textPrimary.withValues(alpha: 0.06),
  AppColors.surfaceSunken,
);

void main() {
  final today = LocalDate(2026, 11, 14);

  Future<InMemoryPlannerRepository> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = InMemoryPlannerRepository();
    await seedDemoData(repository, today: today);
    await tester.pumpWidget(
      PlannerApp(repository: repository, isDemoData: true, today: today),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  /// 取导航项里负责底色的 [AnimatedContainer]。
  AnimatedContainer navBox(WidgetTester tester, String key) =>
      tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(AnimatedContainer),
        ),
      );

  Color navColor(WidgetTester tester, String key) =>
      (navBox(tester, key).decoration! as BoxDecoration).color!;

  TextStyle navLabelStyle(WidgetTester tester, String key) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(Text),
        ),
      )
      .style!;

  testWidgets('鼠标悬停时浅灰底一直保持，移开后恢复透明', (tester) async {
    await pumpApp(tester);

    final nav = find.byKey(const ValueKey<String>('nav-completed'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    final before = navColor(tester, 'nav-completed');
    expect(before.a, 0, reason: '未悬停时完全透明');

    await mouse.moveTo(tester.getCenter(nav));
    await tester.pump();
    await tester.pump(AppMotion.hover);

    final hovered = navColor(tester, 'nav-completed');
    expect(hovered.a, 1);
    expect(hovered, _expectedHoverBase);
    // 与侧栏底色的差异必须看得出来，否则用户会觉得"闪一下又变回白"。
    expect(hovered, isNot(AppColors.surfaceSunken));

    // 指针不动，等两秒也不能掉色。
    await tester.pump(const Duration(seconds: 2));
    expect(navColor(tester, 'nav-completed'), hovered);

    // 悬停过渡只动 alpha：两端 RGB 相同，才不会经过半透明黑闪灰。
    expect(before.withValues(alpha: 1), hovered);

    await mouse.moveTo(const Offset(5, 880));
    await tester.pump();
    expect(navColor(tester, 'nav-completed').a, 0);
  });

  testWidgets('悬停中发生整壳重建，hover 仍然保持', (tester) async {
    await pumpApp(tester);

    final nav = find.byKey(const ValueKey<String>('nav-completed'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(nav));
    await tester.pump(AppMotion.hover);
    final hovered = navColor(tester, 'nav-completed');
    expect(hovered, _expectedHoverBase);

    // 触发一次整壳重建（切到「任务」页），指针仍停在「已完成」上。
    final context = tester.element(find.byType(AppShell));
    final shell = AppScope.of(context).shell;
    shell.showSection(AppSection.tasks);
    await tester.pumpAndSettle();

    expect(navColor(tester, 'nav-completed'), hovered);
  });

  testWidgets('点击导航项后变成浅蓝选中态（与截图里的「归档」一致）', (tester) async {
    await pumpApp(tester);

    expect(navColor(tester, 'nav-archive').a, 0);
    expect(navLabelStyle(tester, 'nav-archive').color, AppColors.textSecondary);

    await tester.tap(find.byKey(const ValueKey<String>('nav-archive')));
    await tester.pumpAndSettle();

    expect(navColor(tester, 'nav-archive'), AppColors.accentSoft);
    expect(navLabelStyle(tester, 'nav-archive').color, AppColors.accent);
    expect(navLabelStyle(tester, 'nav-archive').fontWeight, FontWeight.w600);

    // 再等一秒不会把选中态打回透明。
    await tester.pump(const Duration(seconds: 1));
    expect(navColor(tester, 'nav-archive'), AppColors.accentSoft);
  });

  testWidgets('侧栏项目条目也用浅灰 hover，不再用几乎看不见的 surfaceHover', (tester) async {
    await pumpApp(tester);

    final row = find.text('产品官网改版');
    expect(row, findsWidgets);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row.first));
    await tester.pump(AppMotion.hover);

    final box = tester.widget<AnimatedContainer>(
      find
          .ancestor(of: row.first, matching: find.byType(AnimatedContainer))
          .first,
    );
    expect((box.decoration! as BoxDecoration).color, _expectedHoverBase);
  });
}
