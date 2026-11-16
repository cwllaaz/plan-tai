import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/features/cloud_account/cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'support/cloud_harness.dart';

void main() {
  group('登录面板', () {
    testWidgets('1. 空服务器地址：提示必填且不发请求', (tester) async {
      final harness = CloudHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-signin-submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('请填写服务器地址'), findsOneWidget);
      expect(harness.accountService.loginCalls, 0);
    });

    testWidgets('2. 无效 HTTPS 地址：拒绝明文与非 https 协议', (tester) async {
      final harness = CloudHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await submitSignIn(
        tester,
        server: 'http://sync.example.com',
        account: 'demo@example.com',
        password: 'demo1234',
      );
      expect(find.textContaining('正式连接必须使用 HTTPS'), findsWidgets);
      expect(harness.accountService.loginCalls, 0);

      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud-server-field')),
        'https://exa mple.com',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-signin-submit')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('不能包含空格'), findsOneWidget);
      expect(harness.accountService.loginCalls, 0);
    });

    testWidgets('3. 错误账号密码：显示登录失败说明', (tester) async {
      final harness = CloudHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await submitSignIn(
        tester,
        server: 'https://sync.example.com',
        account: 'demo@example.com',
        password: 'wrong-password',
      );

      expect(find.text('登录失败'), findsOneWidget);
      expect(find.textContaining('账号或密码不正确'), findsWidgets);
      expect(harness.accountService.loginCalls, 1);
    });

    testWidgets('4. 服务器不可达：提示网络问题且可重试', (tester) async {
      late UnreachableCloudAccountService unreachable;
      final harness = CloudHarness(
        decorateAccount: (FakeCloudAccountService inner) =>
            unreachable = UnreachableCloudAccountService(inner),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await submitSignIn(
        tester,
        server: 'https://sync.example.com',
        account: 'demo@example.com',
        password: 'demo1234',
      );

      expect(find.text('无法连接服务器'), findsOneWidget);
      expect(find.textContaining('请检查网络'), findsWidgets);
      expect(unreachable.connectCalls, 1);
      expect(harness.accountService.loginCalls, 0);
      expect(
        find.byKey(const ValueKey<String>('cloud-signin-submit')),
        findsOneWidget,
      );
    });

    testWidgets('5. 登录成功：展示账号 / 同步状态 / 待同步数量', (tester) async {
      final preferences = MemoryCloudUiPreferences();
      final harness = CloudHarness(preferences: preferences);
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await submitSignIn(
        tester,
        server: 'sync.example.com',
        account: 'demo@example.com',
        password: 'demo1234',
      );

      expect(find.text('云端账号'), findsOneWidget);
      expect(find.text('已连接服务器'), findsOneWidget);
      expect(find.text('demo@example.com'), findsWidgets);
      expect(find.text('云同步'), findsOneWidget);
      expect(find.text('待上传'), findsOneWidget);
      expect(find.text('最近上传'), findsOneWidget);
      expect(find.text('最近下载'), findsOneWidget);
      expect(find.text('已保存到本机'), findsOneWidget);
      // 服务器地址作为普通配置保存（不含密码）。
      expect(await preferences.readServerAddress(), 'https://sync.example.com');
      expect(harness.controller.bindingStage, CloudBindingStage.ready);
    });

    testWidgets('6. Token 失效：回到登录态、保留待同步操作并提示重新登录', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(pending: 2),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('云端同步'), findsOneWidget);

      harness.accountService.expireSession();
      await tester.pumpAndSettle();

      expect(find.text('需要重新登录'), findsOneWidget);
      expect(find.textContaining('登录已过期'), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('cloud-signin-submit')),
        findsOneWidget,
      );
      // 本机待同步队列没有被清空。
      expect(harness.syncService.status.pendingOperations, 2);
      expect(harness.controller.syncStatus.pendingOperations, 2);
    });

    testWidgets('7. 离线状态：单独标识，改动只保存在本机', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(pending: 2),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      harness.syncService.setOffline(true);
      await tester.pumpAndSettle();

      expect(find.text('离线'), findsWidgets);
      expect(find.text('当前离线'), findsOneWidget);
      expect(find.textContaining('改动已保存在本机'), findsWidgets);
    });

    testWidgets('8. 同步过程：显示正在同步并禁用按钮', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      harness.syncService.emitStatus(
        SyncStatus(
          phase: SyncPhase.syncing,
          account: demoAccount(),
          pendingOperations: 3,
          autoUploadEnabled: true,
          autoDownloadEnabled: true,
          message: '正在上传 3/12',
        ),
      );
      // syncing 态有一直在转的小进度圈，不能 pumpAndSettle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('正在同步'), findsWidgets);
      expect(find.text('正在上传 3/12'), findsOneWidget);

      final syncButton = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('cloud-upload-now')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(syncButton.onPressed, isNull);
    });

    testWidgets('9. 同步失败：显示失败原因，可再次同步', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      harness.syncService.failNextSync(
        const CloudException(CloudErrorKind.server, '服务器暂时不可用'),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('cloud-upload-now')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('cloud-upload-now')));
      await tester.pumpAndSettle();

      expect(find.textContaining('上传失败'), findsWidgets);
      expect(find.textContaining('服务器暂时不可用'), findsWidgets);

      harness.syncService.emitStatus(
        SyncStatus(
          phase: SyncPhase.error,
          account: demoAccount(),
          lastError: '服务器返回 500',
          autoUploadEnabled: true,
          autoDownloadEnabled: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('同步失败'), findsWidgets);
      expect(find.textContaining('服务器返回 500'), findsWidgets);
    });

    testWidgets('10. 待同步操作：区分本地保存与已上传', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(pending: 3),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('待同步 3 项'), findsWidgets);
      expect(find.text('3 项'), findsWidgets);
      expect(find.text('已保存到本机'), findsOneWidget);
      expect(find.text('已上传到云端'), findsNothing);
      expect(find.text('最近上传'), findsOneWidget);
    });

    testWidgets('11. 冲突选择：保留本机修改后冲突消失', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(),
        conflicts: <SyncConflict>[demoConflict()],
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('处理冲突（1）'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('cloud-open-conflicts')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-open-conflicts')),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步冲突'), findsOneWidget);
      expect(find.text('主要字段差异'), findsOneWidget);
      expect(find.text('本机版本'), findsOneWidget);
      expect(find.text('云端版本'), findsOneWidget);
      expect(find.text('整理季度汇报材料'), findsWidgets);
      expect(find.text('09:00–10:00'), findsOneWidget);
      expect(find.text('10:00–11:00'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-conflict-keep-local')),
      );
      await tester.pumpAndSettle();

      expect(harness.syncService.resolveCalls, 1);
      expect(
        find.byKey(const ValueKey<String>('cloud-conflict-page')),
        findsNothing,
      );
      expect(find.text('处理冲突（1）'), findsNothing);
      expect(await harness.syncService.listConflicts(), isEmpty);
    });

    testWidgets('12. 冲突选择：取消并稍后处理不删除任何版本', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(),
        conflicts: <SyncConflict>[demoConflict()],
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('cloud-open-conflicts')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-open-conflicts')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-conflict-later')),
      );
      await tester.pumpAndSettle();

      expect(harness.syncService.resolveCalls, 0);
      expect(await harness.syncService.listConflicts(), hasLength(1));
      expect(find.text('处理冲突（1）'), findsOneWidget);
    });

    testWidgets('13. 退出账号：确认后断开，本地数据保留', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('cloud-signout')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('cloud-signout')));
      await tester.pumpAndSettle();

      expect(find.text('断开云端绑定？'), findsOneWidget);
      expect(find.textContaining('本机数据不会被删除'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-signout-confirm')),
      );
      await tester.pumpAndSettle();

      expect(harness.accountService.logoutCalls, 1);
      expect(
        find.byKey(const ValueKey<String>('cloud-signin-submit')),
        findsOneWidget,
      );
      expect(find.textContaining('仍完整保留在本机'), findsWidgets);
    });

    testWidgets('14. 密码输入框默认遮挡，可显式切换', (tester) async {
      final harness = CloudHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      final passwordField = find.byKey(
        const ValueKey<String>('cloud-password-field'),
      );
      expect(tester.widget<TextField>(passwordField).obscureText, isTrue);

      await tester.enterText(passwordField, 'secret-password-123');
      await tester.pump();
      // 遮挡状态下密码不会以普通 Text 出现在任何地方。
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Text && widget.data == 'secret-password-123',
        ),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-password-toggle')),
      );
      await tester.pump();
      expect(tester.widget<TextField>(passwordField).obscureText, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-password-toggle')),
      );
      await tester.pump();
      expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
    });
  });

  group('首次账号绑定', () {
    testWidgets('有本地数据时显示明确提示与四条说明，不确认不上传', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: localDataCloudEmptyInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('检测到当前电脑已有本地数据，是否将这些数据关联到当前云端账号？'), findsOneWidget);
      expect(find.textContaining('保留本地数据'), findsOneWidget);
      expect(find.textContaining('上传和下载后按记录合并'), findsOneWidget);
      expect(find.textContaining('已经存在的记录不会被直接覆盖'), findsOneWidget);
      expect(find.textContaining('出现冲突时会提示'), findsOneWidget);
      expect(find.textContaining('整库备份'), findsWidgets);
      expect(find.textContaining('本机 12 条记录'), findsOneWidget);

      // 没有点确认之前，一次绑定调用都不能发生。
      expect(harness.syncService.lastBindingChoice, isNull);
      expect(harness.syncService.syncCalls, 0);

      final syncButton = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('cloud-upload-now')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(syncButton.onPressed, isNull);
    });

    testWidgets('确认关联：上传本地数据并自动开始首次同步', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: localDataCloudEmptyInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-binding-confirm')),
      );
      await tester.pumpAndSettle();

      expect(
        harness.syncService.lastBindingChoice,
        BindingChoice.uploadLocalToAccount,
      );
      expect(harness.controller.bindingStage, CloudBindingStage.ready);
      expect(harness.syncService.syncCalls, greaterThanOrEqualTo(1));

      final syncButton = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('cloud-upload-now')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(syncButton.onPressed, isNotNull);
    });

    testWidgets('备份路径会显示在本机数据卡片里', (tester) async {
      const backupPath =
          r'C:\Users\demo\AppData\Roaming\计划台\data\backups\pre-bind-20261115.db';
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: localDataCloudEmptyInspection(),
        status: syncedStatus(),
        decorateSync: (FakeSyncService inner) => ScriptedSyncService(
          inner,
          bindingResult: const BindingResult(
            changed: true,
            requiresRestart: false,
            message: '已上传 14 条记录',
            backupPath: backupPath,
          ),
        ),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-binding-confirm')),
      );
      await tester.pumpAndSettle();

      expect(find.text('最近备份'), findsOneWidget);
      expect(find.textContaining('pre-bind-20261115.db'), findsWidgets);
    });

    testWidgets('需要重启时明确提示，不自动同步', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: localDataCloudEmptyInspection(),
        status: syncedStatus(),
        decorateSync: (FakeSyncService inner) => ScriptedSyncService(
          inner,
          bindingResult: const BindingResult(
            changed: true,
            requiresRestart: true,
            message: '工作区已切换',
            backupPath: r'C:\backups\pre-bind.db',
          ),
        ),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-binding-confirm')),
      );
      await tester.pumpAndSettle();

      expect(
        harness.controller.bindingStage,
        CloudBindingStage.restartRequired,
      );
      expect(find.textContaining('需要重启应用'), findsWidgets);
      expect(harness.syncService.syncCalls, 0);
    });

    testWidgets('暂不关联：保留本地数据且禁用同步', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: localDataCloudEmptyInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-binding-skip')),
      );
      await tester.pumpAndSettle();

      expect(
        harness.syncService.lastBindingChoice,
        BindingChoice.keepLocalUnbound,
      );
      expect(harness.controller.bindingSkipped, isTrue);
      expect(find.textContaining('本机数据未关联账号，暂不上传'), findsWidgets);
      expect(harness.syncService.syncCalls, 0);
      expect(harness.controller.inspection!.localLiveRecords, 12);
    });

    testWidgets('两边都有数据：不提供自动上传，只给备份归档或保持本地', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: bothHaveDataInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('两边都有数据，第一版不自动合并整库'), findsOneWidget);
      expect(find.text('以云端为准（先备份并归档本机数据）'), findsOneWidget);
      expect(find.text('保持本地不绑定'), findsOneWidget);
      expect(find.text('上传本机数据到该账号'), findsNothing);
      expect(find.textContaining('本机 12 条记录'), findsOneWidget);
      expect(find.textContaining('云端 8 条记录'), findsOneWidget);
    });

    testWidgets('全新安装且云端有数据：提示下载，不出现上传按钮', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: freshInstallWithCloudInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('云端已有 8 条数据，是否创建本机工作区并下载？'), findsOneWidget);
      expect(find.text('创建本机工作区并下载云端数据'), findsOneWidget);
      expect(find.text('上传本机数据到该账号'), findsNothing);
    });

    testWidgets('本机数据属于其他账号：禁止上传，可新建空工作区或取消登录', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundOtherAccountInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(find.text('不会上传其他账号的数据'), findsOneWidget);
      expect(find.textContaining('owner-a'), findsWidgets);
      expect(find.text('为当前账号新建空工作区'), findsOneWidget);
      expect(find.text('取消登录'), findsOneWidget);
      expect(find.text('上传本机数据到该账号'), findsNothing);
    });
  });

  group('窗口缩放与布局', () {
    testWidgets('1100×700 / 1366×768 / 1440×900 无溢出', (tester) async {
      for (final size in <Size>[
        const Size(1100, 700),
        const Size(1366, 768),
        const Size(1440, 900),
      ]) {
        final harness = CloudHarness(
          session: demoAccount(),
          inspection: boundSameAccountInspection(),
          status: syncedStatus(pending: 1),
        );
        await harness.initialize();
        addTearDown(harness.dispose);
        await pumpCloudPanel(tester, harness, size: size);
        expect(tester.takeException(), isNull, reason: '窗口 $size 不应该溢出');
      }
    });

    testWidgets('登录表单在最小窗口 1100×700 不溢出', (tester) async {
      final harness = CloudHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness, size: const Size(1100, 700));
      expect(tester.takeException(), isNull);
    });
  });

  group('上传与下载分离', () {
    testWidgets('两个按钮和两个自动开关独立存在；点下载只触发下载', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      expect(
        find.byKey(const ValueKey<String>('cloud-upload-now')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cloud-download-now')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cloud-auto-upload')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cloud-auto-download')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('cloud-download-now')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-download-now')),
      );
      await tester.pumpAndSettle();

      expect(harness.syncService.downloadCalls, 1);
      expect(harness.syncService.uploadCalls, 0);
    });

    testWidgets('有未上传改动时，下载前必须二次确认', (tester) async {
      final harness = CloudHarness(
        session: demoAccount(),
        inspection: boundSameAccountInspection(),
        status: syncedStatus(pending: 3),
      );
      await harness.initialize();
      addTearDown(harness.dispose);
      await pumpCloudPanel(tester, harness);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('cloud-download-now')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-download-now')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('本机有 3 项未上传改动'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('cloud-download-force')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('cloud-download-force')),
      );
      await tester.pumpAndSettle();

      expect(harness.syncService.overwriteCalls, 1);
      expect(harness.syncService.downloadCalls, 1);
    });
  });
}
