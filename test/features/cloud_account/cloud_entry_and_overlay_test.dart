import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/theme/theme.dart';
import 'package:jihuatai/features/cloud_account/cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'support/cloud_harness.dart';

Widget _entryApp(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(child: child),
    ),
  );
}

Future<CloudHarness> _pumpEntry(
  WidgetTester tester, {
  bool compact = false,
  CloudHarness? harness,
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final active = harness ?? CloudHarness();
  await active.initialize();
  addTearDown(active.dispose);
  await tester.pumpWidget(
    _entryApp(
      CloudSyncEntryButton(controller: active.controller, compact: compact),
    ),
  );
  await tester.pumpAndSettle();
  return active;
}

void main() {
  group('顶部同步入口', () {
    testWidgets('未登录显示未登录', (tester) async {
      await _pumpEntry(tester);
      expect(find.text('未登录'), findsOneWidget);
    });

    testWidgets('已同步显示已同步', (tester) async {
      await _pumpEntry(
        tester,
        harness: CloudHarness(
          session: demoAccount(),
          inspection: boundSameAccountInspection(),
          status: syncedStatus(),
        ),
      );
      expect(find.text('已同步'), findsOneWidget);
    });

    testWidgets('待同步显示待同步 N 项', (tester) async {
      await _pumpEntry(
        tester,
        harness: CloudHarness(
          session: demoAccount(),
          inspection: boundSameAccountInspection(),
          status: syncedStatus(pending: 3),
        ),
      );
      expect(find.text('待同步 3 项'), findsOneWidget);
    });

    testWidgets('离线显示离线', (tester) async {
      await _pumpEntry(
        tester,
        harness: CloudHarness(
          session: demoAccount(),
          inspection: boundSameAccountInspection(),
          status: SyncStatus(
            phase: SyncPhase.offline,
            account: demoAccount(),
            pendingOperations: 2,
            autoUploadEnabled: true,
            autoDownloadEnabled: true,
          ),
        ),
      );
      expect(find.text('离线'), findsOneWidget);
    });

    testWidgets('失败显示同步失败', (tester) async {
      await _pumpEntry(
        tester,
        harness: CloudHarness(
          session: demoAccount(),
          inspection: boundSameAccountInspection(),
          status: SyncStatus(
            phase: SyncPhase.error,
            account: demoAccount(),
            lastError: '服务器暂时不可用',
            autoUploadEnabled: true,
            autoDownloadEnabled: true,
          ),
        ),
      );
      expect(find.text('同步失败'), findsOneWidget);
    });

    testWidgets('冲突显示存在冲突 N', (tester) async {
      await _pumpEntry(
        tester,
        harness: CloudHarness(
          session: demoAccount(),
          inspection: boundSameAccountInspection(),
          status: syncedStatus(),
          conflicts: <SyncConflict>[demoConflict()],
        ),
      );
      expect(find.text('存在冲突 1'), findsOneWidget);
    });

    testWidgets('待确认关联时提示，不显示已同步', (tester) async {
      await _pumpEntry(
        tester,
        harness: CloudHarness(
          session: demoAccount(),
          inspection: localDataCloudEmptyInspection(),
          status: syncedStatus(),
        ),
      );
      expect(find.text('待确认关联'), findsOneWidget);
      expect(find.text('已同步'), findsNothing);
    });

    testWidgets('点击入口打开面板', (tester) async {
      final harness = await _pumpEntry(
        tester,
        harness: CloudHarness(panelOpen: false),
      );
      expect(harness.controller.isPanelOpen, isFalse);
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-entry-button')),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.isPanelOpen, isTrue);
    });

    testWidgets('窄窗口 compact 形态：只有图标，点击同样能打开面板', (tester) async {
      final harness = await _pumpEntry(
        tester,
        compact: true,
        harness: CloudHarness(panelOpen: false),
        size: const Size(1100, 700),
      );
      expect(find.text('未登录'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-entry-button-compact')),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.isPanelOpen, isTrue);
    });
  });

  group('抽屉浮层', () {
    Future<CloudHarness> pumpOverlay(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(pending: 2),
        panelOpen: false,
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const <Locale>[
            Locale('zh', 'CN'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            backgroundColor: AppColors.canvas,
            body: Stack(
              children: <Widget>[
                const Positioned.fill(
                  child: ColoredBox(color: AppColors.canvas),
                ),
                CloudAccountOverlay(controller: harness.controller),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('关闭时不渲染面板、不拦截点击', (tester) async {
      final harness = await pumpOverlay(tester, const Size(1440, 900));
      expect(
        find.byKey(const ValueKey<String>('cloud-account-panel')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      expect(harness.controller.isPanelOpen, isFalse);
    });

    testWidgets('打开后面板浮在右侧，点击面板外关闭', (tester) async {
      final harness = await pumpOverlay(tester, const Size(1440, 900));
      harness.controller.openPanel();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('cloud-account-panel')),
        findsOneWidget,
      );
      // 面板左缘在 1440-420=1020 附近；点左侧空白关闭。
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect(harness.controller.isPanelOpen, isFalse);
    });

    testWidgets('Esc 关闭抽屉', (tester) async {
      final harness = await pumpOverlay(tester, const Size(1440, 900));
      harness.controller.openPanel();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(harness.controller.isPanelOpen, isFalse);
    });

    testWidgets('最小窗口 1100×700 打开抽屉不溢出', (tester) async {
      final harness = await pumpOverlay(tester, const Size(1100, 700));
      harness.controller.openPanel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('cloud-account-panel')),
        findsOneWidget,
      );
    });
  });
}
