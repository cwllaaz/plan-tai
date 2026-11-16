import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final today = LocalDate(2026, 11, 14);

  Future<void> pumpApp(WidgetTester tester) async {
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
  }

  testWidgets('总体布局与演示数据标识', (tester) async {
    await pumpApp(tester);

    expect(find.text('计划台'), findsOneWidget);
    expect(find.text('2026年11月'), findsOneWidget);
    expect(find.text('今天'), findsWidgets);
    expect(find.text('演示数据 · 未接入本地库'), findsOneWidget);
    expect(find.text('本地优先 · 云同步可选'), findsOneWidget);
    expect(find.text('新建安排'), findsOneWidget);

    // 侧栏项目来自仓储流
    expect(find.text('产品官网改版'), findsOneWidget);
    expect(find.text('客户交付 · 星河'), findsOneWidget);
    expect(find.text('个人成长'), findsOneWidget);
    expect(find.text('月历'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('day-detail-2026-11-14')),
      findsNothing,
    );
  });

  testWidgets('点击新建任务打开每日面板，Esc 关闭', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('新建安排'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('day-detail-2026-11-14')),
      findsOneWidget,
    );
    expect(find.text('当日备注'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('day-detail-2026-11-14')),
      findsNothing,
    );
  });

  testWidgets('双击日期展开当日面板，单击只改选中', (tester) async {
    await pumpApp(tester);

    final cell = find.byKey(const ValueKey<String>('day-2026-11-20'));
    expect(cell, findsOneWidget);

    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('day-detail-2026-11-20')),
      findsNothing,
    );

    await tester.tap(cell);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('day-detail-2026-11-20')),
      findsOneWidget,
    );
  });

  testWidgets('切换上个月更新标题', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();
    expect(find.text('2026年10月'), findsOneWidget);

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(find.text('2026年11月'), findsOneWidget);
  });
}
