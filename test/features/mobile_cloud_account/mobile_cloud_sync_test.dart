/// Android 账号页 · 同步状态与操作测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'support/mobile_cloud_harness.dart';

void main() {
  testWidgets('展示：待同步数量、上次成功同步时间、立即同步与自动同步开关', (
    WidgetTester tester,
  ) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(pending: 3),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.byKey(MobileCloudKeys.syncStatusPill), findsOneWidget);
    expect(find.text('3 项'), findsOneWidget);
    // 固定时钟下「2 分钟前」。
    expect(find.text('2 分钟前'), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.syncNow), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.autoSync), findsOneWidget);

    final autoSwitch = tester.widget<Switch>(
      find.byKey(MobileCloudKeys.autoSync),
    );
    expect(autoSwitch.value, isTrue);
  });

  testWidgets('点击立即同步：调用一次双向同步', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await ensureVisible(tester, find.byKey(MobileCloudKeys.syncNow));
    await tester.tap(find.byKey(MobileCloudKeys.syncNow));
    await tester.pumpAndSettle();

    expect(harness.syncService.syncCalls, 1);
  });

  testWidgets('关闭自动同步开关：状态与引擎开关同步变化', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await ensureVisible(tester, find.byKey(MobileCloudKeys.autoSync));
    await tester.tap(find.byKey(MobileCloudKeys.autoSync));
    await tester.pumpAndSettle();

    expect(harness.syncService.isAutoSyncEnabled, isFalse);
    expect(
      tester.widget<Switch>(find.byKey(MobileCloudKeys.autoSync)).value,
      isFalse,
    );
  });

  testWidgets('有未上传改动时点下载：弹出"仅更新 / 覆盖"二次确认', (
    WidgetTester tester,
  ) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(pending: 2),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await ensureVisible(tester, find.byKey(MobileCloudKeys.downloadNow));
    await tester.tap(find.byKey(MobileCloudKeys.downloadNow));
    await tester.pumpAndSettle();
    expect(find.text('从云端更新'), findsOneWidget);

    await tester.tap(find.byKey(MobileCloudKeys.downloadPreserve));
    await tester.pumpAndSettle();
    expect(harness.syncService.downloadCalls, 1);
    expect(harness.syncService.overwriteCalls, 0);
  });

  testWidgets('确认覆盖本机时使用 overwriteLocal=true', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(pending: 1),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await ensureVisible(tester, find.byKey(MobileCloudKeys.downloadNow));
    await tester.tap(find.byKey(MobileCloudKeys.downloadNow));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅本机存在、云端没有的记录也会被移除'), findsOneWidget);
    await tester.tap(find.byKey(MobileCloudKeys.downloadForce));
    await tester.pumpAndSettle();

    expect(harness.syncService.downloadCalls, 1);
    expect(harness.syncService.overwriteCalls, 1);
  });

  testWidgets('同步失败：显示失败原因与"不丢数据"提示', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(
        phase: SyncPhase.error,
        lastError: '服务器返回 500',
      ),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.byKey(MobileCloudKeys.errorBanner), findsOneWidget);
    expect(find.text('同步失败'), findsWidgets);
    expect(find.text('服务器返回 500'), findsOneWidget);
    expect(find.text('失败不会丢数据：改动仍保存在本机，可以重试。'), findsOneWidget);
  });

  testWidgets('离线：显示离线提示与"已保存在本机"说明', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(phase: SyncPhase.offline, pending: 2),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.text('当前离线'), findsOneWidget);
    expect(
      find.text('改动已保存在本机；恢复网络后会自动重试上传，不需要重新编辑。'),
      findsOneWidget,
    );
  });

  testWidgets('存在冲突：显示"处理冲突（N）"并打开冲突页', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(conflicts: 1, phase: SyncPhase.needsAttention),
      conflicts: <SyncConflict>[mobileDemoConflict()],
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    // 控制器初始化后会把冲突数量与状态同步到界面。
    expect(find.textContaining('处理冲突'), findsOneWidget);
    await ensureVisible(tester, find.byKey(MobileCloudKeys.openConflicts));
    await tester.tap(find.byKey(MobileCloudKeys.openConflicts));
    await tester.pumpAndSettle();

    expect(find.byKey(MobileCloudKeys.conflictPage), findsOneWidget);
    expect(find.text('整理季度汇报材料'), findsWidgets);
  });

  testWidgets('数据归属待确认：页面引导用户先确认关联方式', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: bothHaveDataInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.text('本机与云端都有数据'), findsOneWidget);
    expect(find.text('待确认关联方式'), findsOneWidget);
    await ensureVisible(tester, find.byKey(MobileCloudKeys.syncNow));
    final button = tester.widget<FilledButton>(
      find.byKey(MobileCloudKeys.syncNow),
    );
    expect(button.onPressed, isNull, reason: '未确认归属前不允许上传');
    expect(find.textContaining('请先确认本地数据如何关联到云端账号'), findsWidgets);
  });

  testWidgets('本机数据属于其他账号：明确提示禁止上传', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundOtherAccountInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.text('本机数据属于其他账号'), findsOneWidget);
    expect(find.text('不会上传其他账号的数据'), findsOneWidget);
    await ensureVisible(tester, find.byKey(MobileCloudKeys.syncNow));
    final button = tester.widget<FilledButton>(
      find.byKey(MobileCloudKeys.syncNow),
    );
    expect(button.onPressed, isNull);
  });
}
