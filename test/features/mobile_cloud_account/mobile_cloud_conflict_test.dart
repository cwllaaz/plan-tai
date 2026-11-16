/// Android 冲突处理页测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'support/mobile_cloud_harness.dart';

void main() {
  Future<MobileCloudHarness> openConflictPage(
    WidgetTester tester, {
    List<SyncConflict>? conflicts,
    Size size = const Size(412, 900),
  }) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(conflicts: 2, phase: SyncPhase.needsAttention),
      conflicts:
          conflicts ??
          <SyncConflict>[
            mobileDemoConflict(),
            mobileDemoConflict(
              id: 'conflict-2',
              title: '另一条冲突任务',
              kind: ConflictKind.updateDelete,
            ),
          ],
    );
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.controller.openConflicts();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      mobileCloudTestApp(
        MobileCloudConflictPage(controller: harness.controller),
      ),
    );
    await tester.pumpAndSettle();
    return harness;
  }

  testWidgets('展示本机版本与云端版本的字段差异', (WidgetTester tester) async {
    await openConflictPage(tester);

    expect(find.byKey(MobileCloudKeys.conflictPage), findsOneWidget);
    expect(find.text('整理季度汇报材料'), findsWidgets);
    expect(find.text('本机写的备注'), findsWidgets);
    expect(find.text('云端写的备注'), findsWidgets);
    expect(find.text('本机 v3'), findsWidgets);
    expect(find.text('云端 v4'), findsWidgets);
    expect(find.text('本机'), findsWidgets);
    expect(find.text('云端'), findsWidgets);
  });

  testWidgets('保留本机修改：调用 keepLocal 并移除该冲突', (WidgetTester tester) async {
    final harness = await openConflictPage(
      tester,
      conflicts: <SyncConflict>[mobileDemoConflict()],
    );

    await tester.tap(find.byKey(MobileCloudKeys.conflictKeepLocal('conflict-1')));
    await tester.pumpAndSettle();

    expect(harness.syncService.resolveCalls, 1);
    expect(find.text('没有需要处理的冲突'), findsOneWidget);
  });

  testWidgets('使用云端修改：调用 keepServer', (WidgetTester tester) async {
    final harness = await openConflictPage(
      tester,
      conflicts: <SyncConflict>[mobileDemoConflict()],
    );

    await tester.tap(find.byKey(MobileCloudKeys.conflictUseServer('conflict-1')));
    await tester.pumpAndSettle();

    expect(harness.syncService.resolveCalls, 1);
    expect(find.text('没有需要处理的冲突'), findsOneWidget);
  });

  testWidgets('多条冲突逐条展示，未处理的仍保留', (WidgetTester tester) async {
    final harness = await openConflictPage(tester);
    expect(
      find.byKey(MobileCloudKeys.conflictItem('conflict-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(MobileCloudKeys.conflictItem('conflict-2')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(MobileCloudKeys.conflictKeepLocal('conflict-1')));
    await tester.pumpAndSettle();

    expect(harness.syncService.resolveCalls, 1);
    expect(find.byKey(MobileCloudKeys.conflictItem('conflict-1')), findsNothing);
    expect(
      find.byKey(MobileCloudKeys.conflictItem('conflict-2')),
      findsOneWidget,
    );
    expect(find.text('1 项待处理'), findsOneWidget);
  });

  testWidgets('关闭冲突页不删除任何版本（稍后处理）', (WidgetTester tester) async {
    final harness = await openConflictPage(tester);

    await tester.tap(find.byKey(MobileCloudKeys.conflictClose));
    await tester.pumpAndSettle();

    expect(harness.syncService.resolveCalls, 0);
    expect(harness.controller.conflicts, hasLength(2));
  });
}
