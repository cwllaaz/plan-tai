import 'package:material_ui/material_ui.dart';

import '../../../app/app_scope.dart';
import '../../../app/app_shell.dart';
import '../../../app/shell_state.dart';
import '../../../core/cloud/cloud.dart';
import '../../../core/models/models.dart';
import '../../../core/testing/testing.dart';
import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import '../state/cloud_ui_preferences.dart';
import '../ui/cloud_account_overlay.dart';
import '../ui/conflict_page.dart';

/// 云账号 UI 的独立演示入口（**不进入正式应用**）。
///
/// 用途：在没有真实服务器、没有 SQLite 的情况下，用冻结的 Fake 服务跑出
/// 登录 / 绑定 / 同步 / 冲突各状态，供设计与截图验收。
///
/// 运行（场景通过命令行参数切换，不需要重新编译）：
/// ```
/// flutter build windows --debug -t lib/features/cloud_account/demo/cloud_account_demo.dart
/// build\windows\x64\runner\Debug\jihuatai.exe --scenario=binding
/// ```
///
/// 场景：`login`（默认）/ `login-error` / `binding` / `both-have-data` /
/// `connected` / `pending` / `syncing` / `offline` / `failed` / `conflict`。
///
/// 注意：演示入口把真实 `AppShell` 与云面板叠在一起，用于证明「面板浮在右侧、
/// 不重排月历」。正式接线由 Agent D 在 `app_shell.dart` 完成。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final scenario = _scenarioFrom(args);
  final today = LocalDate(2026, 11, 15);
  final repository = InMemoryPlannerRepository();
  await seedDemoData(repository, today: today);
  final shell = PlannerShellState(today: today);
  final setup = await _DemoSetup.create(scenario);
  runApp(
    _CloudDemoApp(
      repository: repository,
      shell: shell,
      controller: setup.controller,
      openConflicts: setup.openConflicts,
    ),
  );
}

String _scenarioFrom(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--scenario=')) {
      final value = arg.substring('--scenario='.length).trim();
      if (value.isNotEmpty) return value;
    }
  }
  return 'login';
}

class _CloudDemoApp extends StatelessWidget {
  const _CloudDemoApp({
    required this.repository,
    required this.shell,
    required this.controller,
    required this.openConflicts,
  });

  final InMemoryPlannerRepository repository;
  final PlannerShellState shell;
  final CloudAccountController controller;
  final bool openConflicts;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '计划台 · 云账号 UI 演示',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AppScope(
        repository: repository,
        shell: shell,
        child: _DemoHome(controller: controller, openConflicts: openConflicts),
      ),
    );
  }
}

class _DemoHome extends StatefulWidget {
  const _DemoHome({required this.controller, required this.openConflicts});

  final CloudAccountController controller;
  final bool openConflicts;

  @override
  State<_DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<_DemoHome> {
  @override
  void initState() {
    super.initState();
    if (widget.openConflicts) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await widget.controller.openConflicts();
        if (!mounted) return;
        await showCloudConflictPage(context, widget.controller);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const AppShell(isDemoData: true),
        CloudAccountOverlay(controller: widget.controller),
      ],
    );
  }
}

/// 每个场景对应的 Fake 服务与控制器状态。
class _DemoSetup {
  const _DemoSetup({required this.controller, this.openConflicts = false});

  final CloudAccountController controller;
  final bool openConflicts;

  static CloudAccount demoAccount() {
    final now = DateTime.now();
    return CloudAccount(
      ownerId: 'owner-demo',
      email: 'demo@example.com',
      displayName: '示例账号',
      serverUrl: Uri.parse('https://sync.example.com'),
      authenticatedAt: now.subtract(const Duration(minutes: 12)),
    );
  }

  static BindingInspection _boundSame() => const BindingInspection(
    situation: BindingSituation.boundSameAccount,
    canUpload: false,
    requiresBackup: false,
    recommendedChoice: BindingChoice.keepLocalUnbound,
    message: '本机数据已属于当前账号，可直接同步。',
    localLiveRecords: 14,
    cloudRecords: 14,
  );

  static BindingInspection _localDataCloudEmpty() => const BindingInspection(
    situation: BindingSituation.localDataCloudEmpty,
    canUpload: true,
    requiresBackup: true,
    recommendedChoice: BindingChoice.uploadLocalToAccount,
    message: '本机有 14 条记录（5 个项目、7 条任务、2 条跨天安排），云端为空。',
    localLiveRecords: 14,
    cloudRecords: 0,
  );

  static BindingInspection _bothHaveData() => const BindingInspection(
    situation: BindingSituation.bothHaveData,
    canUpload: false,
    requiresBackup: true,
    recommendedChoice: BindingChoice.useCloudAndArchiveLocal,
    message: '本机有 14 条记录，云端有 9 条记录，不能自动合并整库。',
    localLiveRecords: 14,
    cloudRecords: 9,
  );

  static SyncConflict _conflict() => SyncConflict(
    id: 'conflict-demo-1',
    entityType: CloudEntityType.task,
    entityId: 'task-demo-1',
    baseRevision: 3,
    serverRevision: 4,
    kind: ConflictKind.updateUpdate,
    detectedAt: DateTime.now().subtract(const Duration(minutes: 5)),
    localPayload: <String, Object?>{
      'id': 'task-demo-1',
      'title': '整理季度汇报材料',
      'scheduledDate': '2026-11-16',
      'timeSlot': <String, Object?>{'startMinute': 540, 'durationMinutes': 60},
      'notes': '本机写的备注：补上两张图表',
      'status': 'todo',
      'revision': 3,
      'updatedAt': '2026-11-15T05:30:00Z',
    },
    serverPayload: <String, Object?>{
      'id': 'task-demo-1',
      'title': '整理季度汇报材料（云端修改）',
      'scheduledDate': '2026-11-16',
      'timeSlot': <String, Object?>{'startMinute': 600, 'durationMinutes': 60},
      'notes': '云端写的备注：先发给主管确认',
      'status': 'todo',
      'revision': 4,
      'updatedAt': '2026-11-15T05:45:00Z',
    },
  );

  static Future<_DemoSetup> create(String scenario) async {
    final account = demoAccount();
    final signedOut = scenario == 'login' || scenario == 'login-error';
    final accountService = FakeCloudAccountService(
      account: signedOut ? null : account,
    );
    final syncService = FakeSyncService(account: account);
    syncService.setBindingInspection(
      scenario == 'binding'
          ? _localDataCloudEmpty()
          : scenario == 'both-have-data'
          ? _bothHaveData()
          : _boundSame(),
    );

    final SyncStatus idleStatus = SyncStatus(
      phase: SyncPhase.idle,
      account: account,
      lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      autoUploadEnabled: true,
      autoDownloadEnabled: true,
    );
    if (scenario == 'pending') {
      syncService.emitStatus(
        SyncStatus(
          phase: SyncPhase.idle,
          account: account,
          lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 8)),
          pendingOperations: 3,
          autoUploadEnabled: true,
          autoDownloadEnabled: true,
        ),
      );
    } else if (scenario == 'syncing') {
      syncService.emitStatus(
        SyncStatus(
          phase: SyncPhase.syncing,
          account: account,
          pendingOperations: 3,
          autoUploadEnabled: true,
          autoDownloadEnabled: true,
          message: '正在上传 3/12',
        ),
      );
    } else if (scenario == 'offline') {
      syncService.emitStatus(
        SyncStatus(
          phase: SyncPhase.offline,
          account: account,
          lastSyncedAt: DateTime.now().subtract(const Duration(hours: 3)),
          pendingOperations: 2,
          autoUploadEnabled: true,
          autoDownloadEnabled: true,
        ),
      );
    } else if (scenario == 'failed') {
      syncService.emitStatus(
        SyncStatus(
          phase: SyncPhase.error,
          account: account,
          lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 21)),
          pendingOperations: 1,
          autoUploadEnabled: true,
          autoDownloadEnabled: true,
          lastError: '服务器暂时不可用（503），请稍后重试。',
        ),
      );
    } else if (scenario == 'conflict') {
      syncService.seedConflict(_conflict());
    } else {
      syncService.emitStatus(idleStatus);
    }

    final controller = CloudAccountController(
      services: CloudServices(account: accountService, sync: syncService),
      preferences: MemoryCloudUiPreferences(),
      initialPanelOpen: true,
    );
    await controller.initialize();
    if (scenario == 'login-error') {
      await controller.signIn(
        server: 'https://sync.example.com',
        account: 'demo@example.com',
        password: 'wrong-password',
      );
    }
    return _DemoSetup(
      controller: controller,
      openConflicts: scenario == 'conflict',
    );
  }
}
