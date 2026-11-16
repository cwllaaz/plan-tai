import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../app/app_scope.dart';
import '../app/cloud_scope.dart';
import '../app/cloud_workspace.dart';
import '../app/shell_state.dart';
import '../core/contracts/contracts.dart';
import '../core/models/models.dart';
import '../data/sync/account_binding.dart';
import '../features/cloud_account/cloud_account.dart';
import 'shell/mobile_shell.dart';
import 'theme/mobile_theme.dart';

/// Android 移动端应用根组件（**构造参数已冻结**，见 docs/android/MODULE_CONTRACT.md §10.1）。
///
/// 职责与桌面端 `PlannerApp` 对齐：主题 / 中文本地化 / 作用域注入 / 账号工作区
/// 指针维护；区别只在「主界面」换成触屏布局（[MobileShell]）。
/// 业务数据一律通过 [PlannerRepository] 的流获取，不在 UI 里缓存。
class MobileApp extends StatefulWidget {
  const MobileApp({
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

  /// 是否演示数据（内存仓储）。
  final bool isDemoData;

  /// 仅测试注入，正式运行取本机今天。
  final LocalDate? today;

  /// 正式模式下数据库文件路径（设置页展示用）。
  final String? databasePath;

  /// 云服务组合；Android 安全存储就绪前为 null（纯离线可用）。
  final CloudServices? cloudServices;

  /// 云账号面板控制器；离线模式下为 null。
  final CloudAccountController? cloudController;

  /// 数据目录（账号工作区指针所在地）。
  final String? dataDirectory;

  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> {
  late final PlannerShellState _shell = PlannerShellState(today: widget.today);

  @override
  void initState() {
    super.initState();
    final controller = widget.cloudController;
    if (controller != null) {
      controller.addListener(_onCloudChanged);
      // 不阻塞首帧：恢复会话/检查绑定是异步的。
      unawaited(controller.initialize());
    }
  }

  /// 绑定结果要求「重启切换工作区」时，把目标库写入指针文件。
  ///
  /// 只记录路径，不复制/清空任何数据；下一次启动会打开该库。
  void _onCloudChanged() {
    final controller = widget.cloudController;
    final dataDirectory = widget.dataDirectory;
    if (controller == null || dataDirectory == null) return;
    if (controller.bindingStage != CloudBindingStage.restartRequired) return;
    final result = controller.bindingResult;
    final account = controller.account;
    if (result == null || !result.requiresRestart || account == null) return;
    final databasePath = WorkspaceLayout(dataDirectory)
        .accountDatabasePath(account.ownerId);
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
      theme: buildMobileAppTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: MobileShell(
        repository: widget.repository,
        shell: _shell,
        isDemoData: widget.isDemoData,
        databasePath: widget.databasePath,
        dataDirectory: widget.dataDirectory,
      ),
    );

    final controller = widget.cloudController;
    final services = widget.cloudServices;
    if (controller != null && services != null) {
      app = CloudScope(services: services, controller: controller, child: app);
    }

    return AppScope(repository: widget.repository, shell: _shell, child: app);
  }
}
