/// Android 账号/同步页 · 多宽度布局（不溢出）测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'support/mobile_cloud_harness.dart';

void main() {
  for (final double width in <double>[320, 360, 412, 600, 800]) {
    testWidgets('已登录账号页在宽 $width 下不溢出', (WidgetTester tester) async {
      final harness = MobileCloudHarness(
        inspection: boundSameAccountInspection(),
        status: mobileSyncedStatus(pending: 4, conflicts: 1),
        conflicts: <SyncConflict>[mobileDemoConflict()],
      );
      addTearDown(harness.dispose);
      await pumpMobileCloudPage(
        tester,
        harness,
        size: Size(width, 900),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(MobileCloudKeys.page), findsOneWidget);
      expect(find.byKey(MobileCloudKeys.syncNow), findsOneWidget);

      // 页面可滚动到底部（设置项/退出入口在一屏之外时也能到达）。
      await tester.drag(find.byKey(MobileCloudKeys.page), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final double width in <double>[320, 360, 412]) {
    testWidgets('未登录登录页在宽 $width 下不溢出', (WidgetTester tester) async {
      final harness = MobileCloudHarness(autoSignedIn: false);
      addTearDown(harness.dispose);
      await pumpMobileCloudPage(tester, harness, size: Size(width, 780));

      expect(tester.takeException(), isNull);
      expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
    });
  }

  for (final double width in <double>[320, 412]) {
    testWidgets('冲突页在宽 $width 下不溢出', (WidgetTester tester) async {
      final harness = MobileCloudHarness(
        inspection: boundSameAccountInspection(),
        status: mobileSyncedStatus(conflicts: 1, phase: SyncPhase.needsAttention),
        conflicts: <SyncConflict>[mobileDemoConflict()],
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.controller.openConflicts();

      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        mobileCloudTestApp(
          MobileCloudConflictPage(controller: harness.controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(MobileCloudKeys.conflictPage), findsOneWidget);
    });
  }

  testWidgets('数据归属待确认卡片在 360 宽下不溢出', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: bothHaveDataInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness, size: const Size(360, 900));
    expect(tester.takeException(), isNull);
  });
}
