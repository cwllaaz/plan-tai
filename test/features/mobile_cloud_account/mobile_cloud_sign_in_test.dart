/// Android 账号页 · 登录/退出流程测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';

import 'support/mobile_cloud_harness.dart';

void main() {
  testWidgets('未登录：展示服务器、账号、密码与登录按钮', (WidgetTester tester) async {
    final harness = MobileCloudHarness(autoSignedIn: false);
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.byKey(MobileCloudKeys.page), findsOneWidget);
    expect(find.text('云端账号与同步'), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.serverField), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.accountField), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.passwordField), findsOneWidget);
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('数据只保存在本机'), findsOneWidget);
  });

  testWidgets('空表单提交：给出输入错误且不发起登录', (WidgetTester tester) async {
    final harness = MobileCloudHarness(autoSignedIn: false);
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await tester.tap(find.byKey(MobileCloudKeys.signInSubmit));
    await tester.pumpAndSettle();

    expect(find.byKey(MobileCloudKeys.loginError), findsOneWidget);
    expect(find.text('请填写服务器地址'), findsOneWidget);
    expect(harness.accountService.loginCalls, 0);
  });

  testWidgets('输入 HTTP 地址时提示"开发环境例外"', (WidgetTester tester) async {
    final harness = MobileCloudHarness(autoSignedIn: false);
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await tester.enterText(
      find.byKey(MobileCloudKeys.serverField),
      'http://127.0.0.1:8090',
    );
    await tester.pumpAndSettle();
    expect(find.text('开发环境例外'), findsOneWidget);
  });

  testWidgets('账号密码正确：登录成功并进入账号/同步视图', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      autoSignedIn: false,
      inspection: boundSameAccountInspection(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await submitMobileSignIn(
      tester,
      account: 'demo@example.com',
      password: 'demo1234',
    );

    expect(harness.accountService.loginCalls, 1);
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsNothing);
    expect(find.byKey(MobileCloudKeys.accountValue), findsOneWidget);
    expect(find.text('demo@example.com'), findsOneWidget);
    expect(find.text('https://sync.example.com'), findsOneWidget);
    expect(find.text('云同步'), findsOneWidget);
    expect(find.text('已关联（可同步）'), findsOneWidget);
  });

  testWidgets('密码错误：显示明确的登录失败原因', (WidgetTester tester) async {
    final harness = MobileCloudHarness(autoSignedIn: false);
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await submitMobileSignIn(
      tester,
      account: 'demo@example.com',
      password: 'wrong-password',
    );

    expect(find.byKey(MobileCloudKeys.loginError), findsOneWidget);
    expect(find.text('账号或密码不正确'), findsOneWidget);
    // 失败后停留在登录表单，可重试。
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
  });

  testWidgets('退出账号：二次确认后回到未登录状态，不删除本地数据', (
    WidgetTester tester,
  ) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    expect(find.byKey(MobileCloudKeys.signOut), findsOneWidget);
    await ensureVisible(tester, find.byKey(MobileCloudKeys.signOut));
    await tester.tap(find.byKey(MobileCloudKeys.signOut));
    await tester.pumpAndSettle();
    expect(find.text('退出账号并断开云端绑定？'), findsOneWidget);

    await tester.tap(find.byKey(MobileCloudKeys.signOutConfirm));
    await tester.pumpAndSettle();

    expect(harness.accountService.logoutCalls, 1);
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets('重新登录：确认后清空会话回到登录表单', (WidgetTester tester) async {
    final harness = MobileCloudHarness(
      inspection: boundSameAccountInspection(),
      status: mobileSyncedStatus(),
    );
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await ensureVisible(tester, find.byKey(MobileCloudKeys.relogin));
    await tester.tap(find.byKey(MobileCloudKeys.relogin));
    await tester.pumpAndSettle();
    expect(find.text('重新登录？'), findsOneWidget);

    await tester.tap(find.text('重新登录').last);
    await tester.pumpAndSettle();

    expect(harness.accountService.logoutCalls, 1);
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
    expect(find.text('请重新登录以继续同步；本机数据不会受影响。'), findsOneWidget);
  });

  testWidgets('填写服务器但缺账号：提示填写账号，不发起登录', (WidgetTester tester) async {
    final harness = MobileCloudHarness(autoSignedIn: false);
    addTearDown(harness.dispose);
    await pumpMobileCloudPage(tester, harness);

    await tester.enterText(
      find.byKey(MobileCloudKeys.serverField),
      'https://sync.example.com',
    );
    await tester.tap(find.byKey(MobileCloudKeys.signInSubmit));
    await tester.pumpAndSettle();

    expect(find.text('请填写账号或邮箱'), findsOneWidget);
    expect(harness.accountService.loginCalls, 0);
    // 失败后停留在登录表单，可重试。
    expect(find.byKey(MobileCloudKeys.signInSubmit), findsOneWidget);
  });
}
