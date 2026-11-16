import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/theme/theme.dart';
import 'package:jihuatai/features/cloud_account/cloud_account.dart';
import 'package:material_ui/material_ui.dart';

/// 测试固定时钟：2026-11-15 14:00（Asia/Shanghai），保证「N 分钟前」等文案稳定。
final DateTime kCloudTestNow = DateTime.utc(2026, 11, 15, 6);

CloudAccount demoAccount({
  String email = 'demo@example.com',
  String ownerId = 'owner-demo',
  String? displayName,
  Uri? serverUrl,
}) {
  return CloudAccount(
    ownerId: ownerId,
    email: email,
    displayName: displayName,
    serverUrl: serverUrl ?? Uri.parse('https://sync.example.com'),
    authenticatedAt: kCloudTestNow.subtract(const Duration(minutes: 30)),
  );
}

BindingInspection boundSameAccountInspection({int records = 12}) {
  return BindingInspection(
    situation: BindingSituation.boundSameAccount,
    canUpload: false,
    requiresBackup: false,
    recommendedChoice: BindingChoice.keepLocalUnbound,
    message: '本机数据已属于当前账号，可直接同步。',
    localLiveRecords: records,
    cloudRecords: records,
  );
}

BindingInspection localDataCloudEmptyInspection({int localRecords = 12}) {
  return BindingInspection(
    situation: BindingSituation.localDataCloudEmpty,
    canUpload: true,
    requiresBackup: true,
    recommendedChoice: BindingChoice.uploadLocalToAccount,
    message: '本机有 $localRecords 条记录，云端为空；确认后可以上传到当前账号。',
    localLiveRecords: localRecords,
    cloudRecords: 0,
  );
}

BindingInspection bothHaveDataInspection({
  int localRecords = 12,
  int cloudRecords = 8,
}) {
  return BindingInspection(
    situation: BindingSituation.bothHaveData,
    canUpload: false,
    requiresBackup: true,
    recommendedChoice: BindingChoice.useCloudAndArchiveLocal,
    message: '本机有 $localRecords 条记录，云端有 $cloudRecords 条记录，不能自动合并整库。',
    localLiveRecords: localRecords,
    cloudRecords: cloudRecords,
  );
}

BindingInspection freshInstallWithCloudInspection({int cloudRecords = 8}) {
  return BindingInspection(
    situation: BindingSituation.freshInstallCloudHasData,
    canUpload: false,
    requiresBackup: false,
    recommendedChoice: BindingChoice.useCloudAndArchiveLocal,
    message: '本机没有数据，云端有 $cloudRecords 条记录。',
    localLiveRecords: 0,
    cloudRecords: cloudRecords,
  );
}

BindingInspection freshInstallInspection() {
  return const BindingInspection(
    situation: BindingSituation.freshInstallCloudEmpty,
    canUpload: false,
    requiresBackup: false,
    recommendedChoice: BindingChoice.keepLocalUnbound,
    message: '本机与云端都没有数据。',
  );
}

BindingInspection boundOtherAccountInspection({
  int localRecords = 12,
  String boundOwnerId = 'owner-a',
}) {
  return BindingInspection(
    situation: BindingSituation.boundOtherAccount,
    canUpload: false,
    requiresBackup: true,
    recommendedChoice: BindingChoice.keepLocalUnbound,
    message: '本机数据已绑定其他账号，禁止上传。',
    boundOwnerId: boundOwnerId,
    localLiveRecords: localRecords,
    cloudRecords: 3,
  );
}

SyncStatus syncedStatus({DateTime? lastSyncedAt, int pending = 0}) {
  final uploaded =
      lastSyncedAt ?? kCloudTestNow.subtract(const Duration(minutes: 2));
  return SyncStatus(
    phase: SyncPhase.idle,
    account: demoAccount(),
    lastSyncedAt: uploaded,
    lastUploadedAt: uploaded,
    lastDownloadedAt: uploaded,
    pendingOperations: pending,
    autoUploadEnabled: true,
    autoDownloadEnabled: true,
  );
}

SyncConflict demoConflict({
  String id = 'conflict-1',
  String title = '整理季度汇报材料',
  CloudEntityType entityType = CloudEntityType.task,
  ConflictKind kind = ConflictKind.updateUpdate,
}) {
  return SyncConflict(
    id: id,
    entityType: entityType,
    entityId: 'task-0001',
    baseRevision: 3,
    serverRevision: 4,
    kind: kind,
    detectedAt: kCloudTestNow.subtract(const Duration(minutes: 5)),
    localPayload: <String, Object?>{
      'id': 'task-0001',
      'title': title,
      'scheduledDate': '2026-11-16',
      'timeSlot': <String, Object?>{'startMinute': 540, 'durationMinutes': 60},
      'notes': '本机写的备注',
      'status': 'todo',
      'revision': 3,
      'updatedAt': '2026-11-15T05:30:00Z',
    },
    serverPayload: <String, Object?>{
      'id': 'task-0001',
      'title': '$title（云端修改）',
      'scheduledDate': '2026-11-16',
      'timeSlot': <String, Object?>{'startMinute': 600, 'durationMinutes': 60},
      'notes': '云端写的备注',
      'status': 'todo',
      'revision': 4,
      'updatedAt': '2026-11-15T05:45:00Z',
    },
  );
}

/// 一个测试用的控制器 + Fake 服务组合。
class CloudHarness {
  CloudHarness._({
    required this.controller,
    required this.accountService,
    required this.syncService,
  });

  /// 用同一组 Fake 实例接线：账号服务供登录断言，同步服务供同步/冲突断言。
  factory CloudHarness({
    CloudAccount? session,
    CloudAccount? syncAccount,
    BindingInspection? inspection,
    SyncStatus? status,
    List<SyncConflict> conflicts = const <SyncConflict>[],
    CloudAccountService Function(FakeCloudAccountService inner)?
    decorateAccount,
    SyncService Function(FakeSyncService inner)? decorateSync,
    CloudUiPreferences? preferences,
    bool panelOpen = true,
  }) {
    final accountService = FakeCloudAccountService(account: session);
    final syncService = FakeSyncService(
      account: syncAccount ?? session ?? demoAccount(),
    );
    if (inspection != null) syncService.setBindingInspection(inspection);
    if (status != null) syncService.emitStatus(status);
    for (final conflict in conflicts) {
      syncService.seedConflict(conflict);
    }
    final controller = CloudAccountController(
      services: CloudServices(
        account: decorateAccount?.call(accountService) ?? accountService,
        sync: decorateSync?.call(syncService) ?? syncService,
      ),
      preferences: preferences ?? MemoryCloudUiPreferences(),
      clock: () => kCloudTestNow,
      initialPanelOpen: panelOpen,
    );
    return CloudHarness._(
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

Widget cloudTestApp(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Expanded(child: ColoredBox(color: AppColors.canvas)),
          child,
        ],
      ),
    ),
  );
}

Future<void> pumpCloudPanel(
  WidgetTester tester,
  CloudHarness harness, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    cloudTestApp(CloudAccountPanel(controller: harness.controller)),
  );
  await tester.pumpAndSettle();
}

/// 连接阶段就失败的账号服务：模拟服务器不可达（不启动任何网络）。
class UnreachableCloudAccountService implements CloudAccountService {
  UnreachableCloudAccountService(
    this._inner, {
    this.error = const CloudException(
      CloudErrorKind.network,
      '无法连接到服务器',
      retryable: true,
    ),
  });

  final CloudAccountService _inner;
  final CloudException error;
  int connectCalls = 0;

  @override
  Stream<CloudAccount?> observeAccount() => _inner.observeAccount();

  @override
  CloudAccount? currentAccount() => _inner.currentAccount();

  @override
  Future<ServerHandshake> connectServer(Uri baseUrl) async {
    connectCalls++;
    throw error;
  }

  @override
  Future<CloudAccount> login({
    required String username,
    required String password,
  }) => _inner.login(username: username, password: password);

  @override
  Future<CloudAccount?> restoreSession() => _inner.restoreSession();

  @override
  Future<void> logout({bool revokeRemoteSession = true}) =>
      _inner.logout(revokeRemoteSession: revokeRemoteSession);

  @override
  Future<void> close() => _inner.close();
}

/// 可替换绑定结果的同步服务（用于验证备份路径 / 需要重启的提示）。
class ScriptedSyncService implements SyncService {
  ScriptedSyncService(this._inner, {this.bindingResult});

  final FakeSyncService _inner;
  final BindingResult? bindingResult;

  @override
  Stream<SyncStatus> observeSyncStatus() => _inner.observeSyncStatus();

  @override
  SyncStatus get status => _inner.status;

  @override
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental}) =>
      _inner.syncNow(mode: mode);

  @override
  Future<SyncResult> uploadNow() => _inner.uploadNow();

  @override
  Future<SyncResult> downloadNow({
    SyncMode mode = SyncMode.incremental,
    bool overwriteLocal = false,
  }) => _inner.downloadNow(mode: mode, overwriteLocal: overwriteLocal);

  @override
  Future<void> enableAutoUpload(bool enabled) =>
      _inner.enableAutoUpload(enabled);

  @override
  Future<void> enableAutoDownload(bool enabled) =>
      _inner.enableAutoDownload(enabled);

  @override
  Future<void> enableAutoSync(bool enabled) => _inner.enableAutoSync(enabled);

  @override
  Future<List<SyncConflict>> listConflicts() => _inner.listConflicts();

  @override
  Future<SyncResult> resolveConflict(
    String conflictId,
    ConflictResolution resolution, {
    Map<String, Object?>? mergedPayload,
  }) => _inner.resolveConflict(
    conflictId,
    resolution,
    mergedPayload: mergedPayload,
  );

  @override
  Future<BindingInspection> inspectBinding() => _inner.inspectBinding();

  @override
  Future<BindingResult> applyBinding(BindingChoice choice) async {
    await _inner.applyBinding(choice);
    return bindingResult ??
        const BindingResult(
          changed: true,
          requiresRestart: false,
          message: '已建立账号工作区',
        );
  }

  @override
  Future<void> close() => _inner.close();
}

/// 输入并提交登录表单。
Future<void> submitSignIn(
  WidgetTester tester, {
  required String server,
  required String account,
  required String password,
}) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('cloud-server-field')),
    server,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('cloud-account-field')),
    account,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('cloud-password-field')),
    password,
  );
  await tester.tap(find.byKey(const ValueKey<String>('cloud-signin-submit')));
  await tester.pumpAndSettle();
}
