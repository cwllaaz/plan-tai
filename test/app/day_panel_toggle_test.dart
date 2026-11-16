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

  Future<void> doubleTapDay(WidgetTester tester, String iso) async {
    final cell = find.byKey(ValueKey<String>('day-$iso'));
    await tester.tap(cell);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(cell);
    await tester.pumpAndSettle();
  }

  bool panelOpen(String iso) =>
      find.byKey(ValueKey<String>('day-detail-$iso')).evaluate().isNotEmpty;

  testWidgets('双击同一天：展开面板，再双击收起', (tester) async {
    await pumpApp(tester);
    expect(panelOpen('2026-11-18'), isFalse);

    await doubleTapDay(tester, '2026-11-18');
    expect(panelOpen('2026-11-18'), isTrue);

    // 再双击同一天 → 收起。
    await doubleTapDay(tester, '2026-11-18');
    expect(panelOpen('2026-11-18'), isFalse);
  });

  testWidgets('面板打开时双击另一天：切到那一天而不是关闭', (tester) async {
    await pumpApp(tester);

    await doubleTapDay(tester, '2026-11-18');
    expect(panelOpen('2026-11-18'), isTrue);

    await doubleTapDay(tester, '2026-11-20');
    expect(panelOpen('2026-11-20'), isTrue);
    expect(panelOpen('2026-11-18'), isFalse);
  });
}
