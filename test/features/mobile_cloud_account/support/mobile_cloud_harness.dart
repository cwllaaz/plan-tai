/// Android 账号/同步 UI 的测试支撑：Fake 云服务 + 控制器 + 固定时钟。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/theme/theme.dart';
import 'package:jihuatai/features/cloud_account/cloud_account.dart';
import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';
import 'package:material_ui/material_ui.dart';

/// 固定时钟：2026-11-15 14:00（Asia/Shanghai），保证"几分钟前"等文案稳定。
final DateTime kMobileCloudNow = DateTime.utc(2026, 11, 15, 6);

CloudAccount mobileDemoAccount({
  String email = 'android@example.com',
  String ownerId = 'owner-android',
  Uri? serverUrl,
}) => CloudAccount(
  ownerId: ownerId,
  email: email,
  serverUrl: serverUrl ?? Uri.parse('https://sync.example.com'),
  authenticatedAt: kMobileCloudNow.subtract(const Duration(minutes: 30)),
);

BindingInspection boundSameAccountInspection({int records = 5}) =>
    BindingInspection(
      situation: BindingSituation.boundSameAccount,
      canUpload: false,
      requiresBackup: false,
      recommendedChoice: BindingChoice.keepLocalUnbound,
      message: '本机数据已属于当前账号，可直接同步。',
      localLiveRecords: records,
      cloudRecords: records,
    );

BindingInspection bothHaveDataInspection({
  int localRecords = 5,
  int cloudRecords = 3,
}) => BindingInspection(
  situation: BindingSituation.bothHaveData,
  canUpload: false,
  requiresBackup: true,
  recommendedChoice: BindingChoice.keepLocalUnbound,
  message: '本机有 $localRecords 条记录，云端有 $cloudRecords 条记录，不能自动合并整库。',
  localLiveRecords: localRecords,
  cloudRecords: cloudRecords,
);

BindingInspection boundOtherAccountInspection() => const BindingInspection(
  situation: BindingSituation.boundOtherAccount,
  canUpload: false,
  requiresBackup: true,
  recommendedChoice: BindingChoice.keepLocalUnbound,
  message: '本机数据已绑定其他账号，禁止上传。',
  boundOwnerId: 'owner-other',
  localLiveRecords: 5,
  cloudRecords: 2,
);

SyncStatus mobileSyncedStatus({
  DateTime? lastSyncedAt,
  int pending = 0,
  SyncPhase phase = SyncPhase.idle,
  int conflicts = 0,
  String? lastError,
  bool autoSync = true,
}) {
  final synced = lastSyncedAt ?? kMobileCloudNow.subtract(const Duration(minutes: 2));
  return SyncStatus(
    phase: phase,
    account: mobileDemoAccount(),
    lastSyncedAt: synced,
    lastUploadedAt: synced,
    lastDownloadedAt: synced,
    pendingOperations: pending,
    conflictCount: conflicts,
    autoUploadEnabled: autoSync,
    autoDownloadEnabled: autoSync,
    lastError: lastError,
  );
}

SyncConflict mobileDemoConflict({
  String id = 'conflict-1',
  String title = '整理季度汇报材料',
  ConflictKind kind = ConflictKind.updateUpdate,
}) => SyncConflict(
  id: id,
  entityType: CloudEntityType.task,
  entityId: 'task-0001',
  baseRevision: 3,
  serverRevision: 4,
  kind: kind,
  detectedAt: kMobileCloudNow.subtract(const Duration(minutes: 5)),
  localPayload: <String, Object?>{
    'id': 'task-0001',
    'title': title,
    'scheduledDate': '2026-11-16',
    'notes': '本机写的备注',
    'status': 'todo',
  },
  serverPayload: <String, Object?>{
    'id': 'task-0001',
    'title': '$title（云端修改）',
    'scheduledDate': '2026-11-17',
    'notes': '云端写的备注',
    'status': 'done',
  },
);

/// 一个接好线的控制器 + Fake 服务。
class MobileCloudHarness {
  MobileCloudHarness._({
    required this.controller,
    required this.accountService,
    required this.syncService,
  });

  factory MobileCloudHarness({
    CloudAccount? session,
    BindingInspection? inspection,
    SyncStatus? status,
    List<SyncConflict> conflicts = const <SyncConflict>[],
    bool autoSignedIn = true,
  }) {
    final signedIn = autoSignedIn
        ? (session ?? mobileDemoAccount())
        : session;
    final accountService = FakeCloudAccountService(
      account: signedIn,
      clock: () => kMobileCloudNow,
    );
    final syncService = FakeSyncService(
      // 同步服务始终有一个"当前账号"，这样 unbinding 检查（inspectBinding）
      // 在已登录场景返回真实语义；未登录时控制器不会调用它。
      account: signedIn ?? mobileDemoAccount(),
      clock: () => kMobileCloudNow,
    );
    if (inspection != null) syncService.setBindingInspection(inspection);
    if (status != null) syncService.emitStatus(status);
    for (final conflict in conflicts) {
      syncService.seedConflict(conflict);
    }
    final controller = CloudAccountController(
      services: CloudServices(account: accountService, sync: syncService),
      preferences: MemoryCloudUiPreferences(),
      clock: () => kMobileCloudNow,
    );
    return MobileCloudHarness._(
      controller: controller,
      accountService: accountService,
      syncService: syncService,
    );
  }

  final CloudAccountController controller;
  final FakeCloudAccountService accountService;
  final FakeSyncService syncService;

  Future<void> initialize() => controller.initialize();

  Future<void> dispose() async {
    controller.dispose();
    await syncService.close();
    await accountService.close();
  }
}

Widget mobileCloudTestApp(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: child,
  );
}

/// 挂载账号与同步页面（默认 412×900，接近主流手机）。
Future<void> pumpMobileCloudPage(
  WidgetTester tester,
  MobileCloudHarness harness, {
  Size size = const Size(412, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    mobileCloudTestApp(MobileCloudAccountPage(controller: harness.controller)),
  );
  await harness.initialize();
  await tester.pumpAndSettle();
}

/// 只挂载一个控件并铺满屏幕（用于入口按钮等）。
Future<void> pumpMobileCloudWidget(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(412, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    mobileCloudTestApp(Scaffold(body: SafeArea(child: child))),
  );
  await tester.pumpAndSettle();
}

/// 输入并提交登录表单。
Future<void> submitMobileSignIn(
  WidgetTester tester, {
  String server = 'https://sync.example.com',
  String account = 'android@example.com',
  String password = 'demo1234',
}) async {
  await tester.enterText(find.byKey(MobileCloudKeys.serverField), server);
  await tester.enterText(find.byKey(MobileCloudKeys.accountField), account);
  await tester.enterText(find.byKey(MobileCloudKeys.passwordField), password);
  await tester.tap(find.byKey(MobileCloudKeys.signInSubmit));
  await tester.pumpAndSettle();
}

/// 确保控件可见：已构建就滚到它；还在懒加载的 ListView 里就先滚动找到它。
Future<void> ensureVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      240,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}
