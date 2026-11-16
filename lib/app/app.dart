import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/contracts/contracts.dart';
import '../core/models/models.dart';
import '../core/theme/theme.dart';
import '../data/sync/account_binding.dart';
import '../features/cloud_account/cloud_account.dart';
import 'app_scope.dart';
import 'app_shell.dart';
import 'cloud_scope.dart';
import 'cloud_workspace.dart';
import 'shell_state.dart';

/// 应用根组件：主题、中文本地化、作用域注入、总体布局。
class PlannerApp extends StatefulWidget {
  const PlannerApp({
    super.key,
    required this.repository,
    this.isDemoData = false,
    this.today,
    this.databasePath,
    this.cloudServices,
    this.cloudController,
    this.dataDirectory,
  });

  final PlannerRepository repository;

  /// 是否处于演示数据模式（内存仓储）。会在侧栏明确标注，避免误当真数据。
  final bool isDemoData;

  /// 仅测试注入，正式运行取本机今天。
  final LocalDate? today;

  /// 正式模式下数据库文件路径（设置/备份对话框展示用）。
  final String? databasePath;

  /// 云服务组合；演示模式为 null（保持完全离线）。
  final CloudServices? cloudServices;

  /// 云账号面板控制器；演示模式为 null。
  final CloudAccountController? cloudController;

  /// 数据目录（`%APPDATA%\计划台\data` 或 `JIHUATAI_DATA_DIR`），
  /// 用于记录/解析账号工作区指针。
  final String? dataDirectory;

  @override
  State<PlannerApp> createState() => _PlannerAppState();
}

class _PlannerAppState extends State<PlannerApp> {
  late final PlannerShellState _shell = PlannerShellState(today: widget.today);

  @override
  void initState() {
    super.initState();
    final controller = widget.cloudController;
    if (controller != null) {
      controller.addListener(_onCloudChanged);
      // 不阻塞首帧：恢复会话/检查绑定是异步的，顶栏会随 controller 刷新。
      unawaited(controller.initialize());
    }
  }

  /// 绑定结果要求“重启切换工作区”时，把目标库写入指针文件。
  ///
  /// 只记录路径，不复制/清空任何数据；下一次启动 `main` 会打开该库。
  void _onCloudChanged() {
    final controller = widget.cloudController;
    final dataDirectory = widget.dataDirectory;
    if (controller == null || dataDirectory == null) return;
    if (controller.bindingStage != CloudBindingStage.restartRequired) return;
    final result = controller.bindingResult;
    final account = controller.account;
    if (result == null || !result.requiresRestart || account == null) return;
    final databasePath = WorkspaceLayout(
      dataDirectory,
    ).accountDatabasePath(account.ownerId);
    if (!File(databasePath).existsSync()) return;
    final store = CloudWorkspaceStore(dataDirectory);
    if (store.activeDatabasePath() == databasePath) return;
    store.remember(account.ownerId, databasePath);
  }

  @override
  void dispose() {
    widget.cloudController?.removeListener(_onCloudChanged);
    widget.cloudController?.dispose();
    unawaited(widget.cloudServices?.close() ?? Future<void>.value());
    _shell.dispose();
    unawaited(widget.repository.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget app = MaterialApp(
      title: '计划台',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AppShell(
        isDemoData: widget.isDemoData,
        databasePath: widget.databasePath,
      ),
    );

    final controller = widget.cloudController;
    final services = widget.cloudServices;
    if (controller != null && services != null) {
      app = CloudScope(services: services, controller: controller, child: app);
    }

    return AppScope(
      repository: widget.repository,
      shell: _shell,
      child: app,
    );
  }
}
