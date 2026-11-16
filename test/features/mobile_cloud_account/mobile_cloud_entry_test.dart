/// 同步状态入口按钮测试（月历模块/D 接入用）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'support/mobile_cloud_harness.dart';

void main() {
  testWidgets('未登录：入口显示未连接图标，点击打开账号页', (WidgetTester tester) async {
    final harness = MobileCloudHarness(autoSignedIn: false);
    addTearDown(harness.dispose);
    await pumpMobileCloudWidget(
      tester,
      MobileCloudEntryButton(controller: harness.controller),
    );
    await harness.initialize();
    await tester.pumpAndSettle();

    expect(find.byKey(MobileCloudKeys.entryButton), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);

    await tester.tap(find.byKey(MobileCloudKeys.entryButton));
    await tester.pumpAndSettle();
    expect(find.byKey(MobileCloudKeys.page), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
  });

  testWidgets('已同步：入口显示已同步图标', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudWidget(
      tester,
      MobileCloudEntryButton(controller: harness.controller, showLabel: true),
    );
    await harness.initialize();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_done_outlined), findsWidgets);
    expect(find.text('已同步'), findsOneWidget);
  });

  testWidgets('有冲突：入口出现警示角标并可进入冲突页', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(conflicts: 1, phase: SyncPhase.needsAttention),
      conflicts: <SyncConflict>[mobileDemoConflict()],
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudWidget(
      tester,
      MobileCloudEntryButton(controller: harness.controller),
    );
    await harness.initialize();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);

    await tester.tap(find.byKey(MobileCloudKeys.entryButton));
    await tester.pumpAndSettle();
    await ensureVisible(tester, find.byKey(MobileCloudKeys.openConflicts));
    await tester.tap(find.byKey(MobileCloudKeys.openConflicts));
    await tester.pumpAndSettle();
    expect(find.byKey(MobileCloudKeys.conflictPage), findsOneWidget);
  });

  testWidgets('同步中：入口显示同步图标', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(phase: SyncPhase.syncing),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudWidget(
      tester,
      MobileCloudEntryButton(controller: harness.controller),
    );
    await harness.initialize();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.sync_rounded), findsWidgets);
  });
}
