import 'package:material_ui/material_ui.dart';

import '../../app/shell_state.dart';
import '../../core/contracts/contracts.dart';
import '../../core/theme/theme.dart';
import '../calendar/mobile_calendar_page.dart';
import '../projects/mobile_project_detail_page.dart';
import '../projects/mobile_projects_page.dart';
import '../settings/mobile_cloud_account_page.dart';
import '../settings/mobile_my_page.dart';
import '../theme/mobile_metrics.dart';
import '../today/mobile_today_page.dart';
import 'mobile_navigation.dart';
import 'mobile_project_nav.dart';

/// 移动端外壳：分区导航（底部导航 / 侧栏）、系统返回键语义、状态保持。
///
/// 布局按可用宽度切换：
/// - compact（<600dp）：底部导航 + 单列内容；
/// - medium（600–839dp）：左侧 NavigationRail + 单列内容；
/// - expanded（≥840dp）：左侧项目导航 + 内容（月历页内部再分三栏）。
class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    required this.repository,
    required this.shell,
    required this.isDemoData,
    this.databasePath,
    this.dataDirectory,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;
  final bool isDemoData;
  final String? databasePath;
  final String? dataDirectory;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  MobileTab _tab = MobileTab.calendar;

  @override
  void initState() {
    super.initState();
    widget.shell.showSection(AppSection.calendar);
  }

  void _selectTab(MobileTab tab) {
    if (_tab == tab) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _tab = tab);
    switch (tab) {
      case MobileTab.calendar:
        widget.shell.showSection(AppSection.calendar);
      case MobileTab.today:
        widget.shell.showSection(AppSection.tasks);
      case MobileTab.projects:
        widget.shell.showSection(AppSection.projects);
      case MobileTab.me:
        widget.shell.showSection(AppSection.projects);
    }
  }

  void _openCloud() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const MobileCloudAccountPage(),
      ),
    );
  }

  void _openProject(String projectId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => MobileProjectDetailPage(
          repository: widget.repository,
          projectId: projectId,
          today: widget.shell.today,
        ),
      ),
    );
  }

  /// 系统返回键：非日历分区先回日历；已在日历分区则退出应用。
  void _handleBackIntent() {
    if (_tab != MobileTab.calendar) {
      _selectTab(MobileTab.calendar);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.shell,
      builder: (BuildContext context, Widget? _) => _buildShell(context),
    );
  }

  Widget _buildShell(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final safeInsets = MediaQuery.viewPaddingOf(context);
        final layout = mobileLayoutFor(
          constraints.maxWidth - safeInsets.horizontal,
          availableHeight: constraints.maxHeight - safeInsets.vertical,
        );
        final pages = <Widget>[
          MobileCalendarPage(
            repository: widget.repository,
            shell: widget.shell,
            layout: layout,
            onOpenCloud: _openCloud,
          ),
          MobileTodayPage(repository: widget.repository, shell: widget.shell),
          MobileProjectsPage(
            repository: widget.repository,
            shell: widget.shell,
          ),
          MobileMyPage(
            repository: widget.repository,
            isDemoData: widget.isDemoData,
            databasePath: widget.databasePath,
            dataDirectory: widget.dataDirectory,
          ),
        ];

        final content = IndexedStack(index: _tab.index, children: pages);

        // Keep the page stack mounted when the navigation changes form.
        final body = Row(
          children: <Widget>[
            switch (layout) {
              MobileLayout.compact => const SizedBox.shrink(),
              MobileLayout.medium => MobileNavRail(
                current: _tab,
                onSelect: _selectTab,
              ),
              MobileLayout.expanded => MobileProjectNav(
                repository: widget.repository,
                shell: widget.shell,
                current: _tab,
                onSelect: _selectTab,
                onOpenProject: _openProject,
              ),
            },
            Expanded(child: content),
          ],
        );

        return PopScope(
          canPop: _tab == MobileTab.calendar,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (didPop) return;
            _handleBackIntent();
          },
          child: Scaffold(
            // 弹层自行避让键盘，底下的月历和任务列表保持原滚动位置。
            resizeToAvoidBottomInset: ModalRoute.isCurrentOf(context) ?? true,
            backgroundColor: AppColors.canvas,
            body: SafeArea(bottom: layout != MobileLayout.compact, child: body),
            bottomNavigationBar: layout == MobileLayout.compact
                ? MobileBottomNav(current: _tab, onSelect: _selectTab)
                : null,
          ),
        );
      },
    );
  }
}
