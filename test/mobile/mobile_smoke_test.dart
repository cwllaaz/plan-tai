import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/mobile/shell/mobile_navigation.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

void main() {
  testWidgets('手机主页可启动并显示月历与四个导航分区', (WidgetTester tester) async {
    final repository = await demoRepository();
    await pumpMobileApp(tester, repository: repository);

    expect(find.byType(MobileBottomNav), findsOneWidget);
    for (final tab in MobileTab.values) {
      expect(
        find.byKey(ValueKey<String>('mobile-tab-${tab.name}')),
        findsOneWidget,
      );
    }

    expect(find.text('2026年11月'), findsOneWidget);
    expect(find.text('日'), findsOneWidget);
    expect(find.text('一'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mobile-day-2026-11-14')),
      findsOneWidget,
    );
    // 下方选中日摘要（不是「今日」分区的任务列表标题）。
    expect(find.textContaining('11月14日 '), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('mobile-day-expand')),
      findsOneWidget,
    );
  });
}
