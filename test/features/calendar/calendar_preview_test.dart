import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/features/calendar/calendar_preview.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('独立预览入口能起得来：演示数据就绪后渲染月历', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CalendarPreviewApp());
    await tester.pumpAndSettle();

    expect(find.text('月历'), findsOneWidget);
    expect(find.text('上个月'), findsOneWidget);
    expect(find.text('下个月'), findsOneWidget);
    expect(find.textContaining('预览数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
