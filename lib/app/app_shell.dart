import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/contracts/contracts.dart';
import '../core/format/format.dart';
import '../core/models/models.dart';
import '../core/theme/theme.dart';
import '../features/calendar/calendar_month_view.dart';
import '../features/cloud_account/cloud_account.dart';
import '../features/day_detail/day_detail_panel.dart';
import 'app_scope.dart';
import 'backup_dialog.dart';
import 'cloud_scope.dart';
import 'projects_page.dart';
import 'settings_dialog.dart';
import 'shell_state.dart';
import 'span_editor_dialog.dart';
import 'tasks_page.dart';
import 'unfiled_group.dart';

/// `surfaceSunken` 底色（侧栏、分段控件底）上的 hover 底色。
///
/// 不能直接用 `AppColors.surfaceHover`：它（#F5F7FA）比侧栏底色（#F2F4F7）更亮，
/// hover 时几乎看不出变化，观感就是"闪一下又变回白"。这里用墨色 6% 压深的浅灰，
/// 在侧栏上能稳定看出一个浅灰底。
///
/// 另外，hover 过渡只能动 alpha：如果用 `Colors.transparent` 当终点，
/// 补间会经过半透明黑，进出时会各闪一下深灰。
final Color _sunkenHoverColor = Color.alphaBlend(
  AppColors.textPrimary.withValues(alpha: 0.06),
  AppColors.surfaceSunken,
);

/// 应用总体布局：左侧导航 224 + 顶部工具栏 56 + 月历 + 可收起的日面板 420。
///
/// 只负责"框架与组装"：日历主体与每日面板是可替换模块（见 docs/MODULE_API.md）。
class AppShell extends StatelessWidget {
  const AppShell({super.key, this.isDemoData = false, this.databasePath});

  /// 演示数据模式下在侧栏明确标注，避免把模拟数据当成真实数据。
  final bool isDemoData;

  /// 正式模式下 `app.db` 的绝对路径，用于设置与备份对话框展示。
  final String? databasePath;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final shell = scope.shell;
    final cloud = CloudScope.controllerOf(context);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): shell.closeDrawer,
        const SingleActivator(LogicalKeyboardKey.keyT): shell.goToToday,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Scaffold(
              backgroundColor: AppColors.canvas,
              body: Row(
                children: <Widget>[
                  _Sidebar(
                    repository: scope.repository,
                    isDemoData: isDemoData,
                    section: shell.section,
                    onSection: shell.showSection,
                    onOpenProject: shell.openProject,
                  ),
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        _TopBar(
                          shell: shell,
                          repository: scope.repository,
                          databasePath: databasePath,
                          isDemoData: isDemoData,
                          cloud: cloud,
                        ),
                        Expanded(
                          child: _Workspace(
                            repository: scope.repository,
                            shell: shell,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 云账号抽屉浮在右侧，不改变月历布局（见 features/cloud_account）。
            if (cloud != null) CloudAccountOverlay(controller: cloud),
          ],
        ),
      ),
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.repository, required this.shell});

  final PlannerRepository repository;
  final PlannerShellState shell;

  @override
  Widget build(BuildContext context) {
    final padded = Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        shell.isDrawerOpen && shell.section == AppSection.calendar
            ? 0
            : AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: _content(context),
    );
    return padded;
  }

  Widget _content(BuildContext context) {
    switch (shell.section) {
      case AppSection.calendar:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: CalendarMonthView(
                repository: repository,
                month: shell.visibleMonth,
                today: shell.today,
                selectedDate: shell.selectedDate,
                onSelectDate: shell.selectDate,
                // 双击同一天 = 展开 / 收起当日面板；双击另一天则切过去。
                onOpenDay: shell.toggleDay,
                onRangeSelected: (start, end) =>
                    _createSpanFromRange(context, start, end),
                onOpenSpan: (span) => _editSpanFromCalendar(context, span),
              ),
            ),
            AnimatedContainer(
              duration: AppMotion.drawer,
              curve: AppMotion.curve,
              width: shell.isDrawerOpen ? AppSizes.drawerWidth : 0,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: shell.isDrawerOpen
                  ? DayDetailPanel(
                      repository: repository,
                      date: shell.selectedDate,
                      today: shell.today,
                      onClose: shell.closeDrawer,
                      onDateChange: shell.selectDate,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        );
      case AppSection.projects:
        return ProjectsPage(repository: repository, shell: shell);
      case AppSection.archive:
        return ProjectsPage(
          repository: repository,
          shell: shell,
          archivedOnly: true,
        );
      case AppSection.tasks:
        return TasksPage(
          repository: repository,
          shell: shell,
          completed: false,
        );
      case AppSection.completed:
        return TasksPage(repository: repository, shell: shell, completed: true);
    }
  }

  /// 月历上右键拖选了一段日期：弹出「新建跨天安排」。
  ///
  /// 弹窗里只填 名称 / 颜色 / 起止 / 状态 / 说明 —— 不选项目；
  /// 保存后先归入「未归类」，之后可以双击横条改到具体项目。
  /// 组件只负责"选中哪几天"，弹窗与写库都留在外壳里（与每日面板同样的分工）。
  Future<void> _createSpanFromRange(
    BuildContext context,
    LocalDate start,
    LocalDate end,
  ) async {
    final result = await showSpanEditorDialog(
      context,
      title: '新建跨天安排',
      initialStart: start,
      initialEnd: end,
      footerHint: '保存后先放在「未归类」，之后双击月历上的横条可以归类到项目',
    );
    if (result == null || !context.mounted) return;

    try {
      // 「未归类」分组按需创建：只是打开弹窗又取消的话，不会多出一个空分组。
      final unfiled = await ensureUnfiledProject(repository);
      if (!context.mounted) return;
      await repository.createSpan(
        PlanSpanDraft(
          projectId: result.projectId ?? unfiled.id,
          title: result.title,
          startDate: result.start,
          endDate: result.end,
          status: result.status,
          description: result.description,
          color: result.color,
        ),
      );
      if (!context.mounted) return;
      shell.selectDate(result.start);
      _notify(context, '已添加安排「${result.title}」');
    } on PlannerException catch (error) {
      if (!context.mounted) return;
      _notify(context, error.message, error: true);
    }
  }

  /// 双击月历上的跨天横条：编辑名称/颜色/起止/状态/说明，并可以改「归属项目」。
  ///
  /// 换项目时把它名下（`spanId` 指向它）的任务一起搬过去，
  /// 否则会违反"任务必须与所属阶段同项目"的数据约束。
  Future<void> _editSpanFromCalendar(
    BuildContext context,
    PlanSpan span,
  ) async {
    Project unfiled;
    List<Project> projects;
    try {
      unfiled = await ensureUnfiledProject(repository);
      projects = await repository.watchProjects(includeArchived: true).first;
    } on PlannerException catch (error) {
      if (context.mounted) _notify(context, error.message, error: true);
      return;
    }
    if (!context.mounted) return;

    if (!projects.any((project) => project.id == unfiled.id)) {
      projects = <Project>[...projects, unfiled];
    }

    final result = await showSpanEditorDialog(
      context,
      title: '编辑跨天安排',
      initialTitle: span.title,
      initialDescription: span.description,
      initialStart: span.startDate,
      initialEnd: span.endDate,
      initialStatus: span.status,
      initialColor: span.color,
      initialProjectId: span.projectId,
      projects: projects,
      allowDelete: true,
    );
    if (result == null || !context.mounted) return;

    if (result.delete) {
      try {
        await repository.deleteSpan(span.id);
        if (!context.mounted) return;
        _notify(context, '安排已删除「${span.title}」');
      } on PlannerException catch (error) {
        if (!context.mounted) return;
        _notify(context, error.message, error: true);
      }
      return;
    }

    final targetProjectId = result.projectId ?? unfiled.id;
    final projectMoved = targetProjectId != span.projectId;
    try {
      await repository.updateSpan(
        span.copyWith(
          projectId: targetProjectId,
          title: result.title,
          startDate: result.start,
          endDate: result.end,
          status: result.status,
          description: result.description,
          color: result.color,
        ),
      );
      if (projectMoved) {
        final tasks = await repository.watchAllTasks().first;
        for (final task in tasks) {
          if (task.spanId != span.id) continue;
          await repository.updateTask(
            task.copyWith(projectId: targetProjectId),
          );
        }
      }
      if (!context.mounted) return;
      _notify(
        context,
        projectMoved
            ? '已更新并归类到「${_projectName(projects, targetProjectId)}」'
            : '安排已更新',
      );
    } on PlannerException catch (error) {
      if (!context.mounted) return;
      _notify(context, error.message, error: true);
    }
  }

  String _projectName(List<Project> projects, String id) {
    for (final project in projects) {
      if (project.id == id) return project.name;
    }
    return '未归类';
  }

  void _notify(BuildContext context, String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: error ? AppColors.danger : null,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 顶部工具栏
// -----------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.shell,
    required this.repository,
    required this.databasePath,
    required this.isDemoData,
    this.cloud,
  });

  final PlannerShellState shell;
  final PlannerRepository repository;
  final String? databasePath;
  final bool isDemoData;
  final CloudAccountController? cloud;

  void _notify(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.topBarHeight,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: <Widget>[
          _MonthNav(shell: shell),
          const SizedBox(width: AppSpacing.lg),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(monthTitle(shell.visibleMonth), style: AppText.h1),
              const SizedBox(height: 1),
              Text(
                '${weekNumberLabel(shell.today)} · 今天 ${monthDayWithWeekday(shell.today)}',
                style: AppText.caption,
              ),
            ],
          ),
          const Spacer(),
          _SearchBox(onTap: () => _notify(context, '搜索将在后续版本提供')),
          const SizedBox(width: AppSpacing.xxs),
          IconButton(
            key: const ValueKey<String>('topbar-backup'),
            tooltip: '本地备份与恢复',
            icon: const Icon(Icons.settings_backup_restore_rounded),
            onPressed: () => showBackupDialog(context, repository: repository),
          ),
          if (cloud != null)
            CloudSyncEntryButton(controller: cloud!)
          else
            IconButton(
              key: const ValueKey<String>('topbar-cloud-disabled'),
              tooltip: '演示模式不连接云端，数据只保存在内存',
              icon: const Icon(Icons.cloud_off_outlined),
              onPressed: () => _notify(context, '演示模式不连接云端；以正式模式启动后可登录'),
            ),
          IconButton(
            key: const ValueKey<String>('topbar-settings'),
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsDialog(
              context,
              databasePath: databasePath,
              isDemoData: isDemoData,
              cloud: cloud,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton.icon(
            onPressed: () {
              shell.showSection(AppSection.calendar);
              shell.openDay(shell.selectedDate);
            },
            icon: const Icon(Icons.add_rounded, size: AppSizes.iconSm),
            label: const Text('新建安排'),
          ),
        ],
      ),
    );
  }
}

class _MonthNav extends StatelessWidget {
  const _MonthNav({required this.shell});

  final PlannerShellState shell;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.control,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _NavIconButton(
            tooltip: '上个月',
            icon: Icons.chevron_left_rounded,
            onPressed: () => shell.shiftMonth(-1),
          ),
          const _NavDivider(),
          Tooltip(
            message: '回到今天（T）',
            child: InkWell(
              borderRadius: AppRadius.control,
              onTap: shell.goToToday,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Center(
                  child: Text(
                    '今天',
                    style: AppText.bodyStrong.copyWith(fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
          const _NavDivider(),
          _NavIconButton(
            tooltip: '下个月',
            icon: Icons.chevron_right_rounded,
            onPressed: () => shell.shiftMonth(1),
          ),
        ],
      ),
    );
  }
}

class _NavDivider extends StatelessWidget {
  const _NavDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 14, color: AppColors.border);
  }
}

class _NavIconButton extends StatelessWidget {
  const _NavIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: AppRadius.control,
        onTap: onPressed,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icon,
            size: AppSizes.iconMd,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _SearchBox extends StatefulWidget {
  const _SearchBox({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '搜索将在后续版本提供',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            width: 160,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            decoration: BoxDecoration(
              color: _hovered
                  ? AppColors.surfaceHover
                  : AppColors.surfaceSunken,
              borderRadius: AppRadius.control,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.search_rounded,
                  size: AppSizes.iconSm,
                  color: AppColors.textTertiary,
                ),
                const SizedBox(width: AppSpacing.xs + 2),
                Expanded(
                  child: Text(
                    '搜索任务',
                    style: AppText.body.copyWith(
                      fontSize: 13,
                      color: AppColors.textTertiary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const _KeyCap(label: '/'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(label, style: AppText.micro.copyWith(fontSize: 10)),
    );
  }
}

// -----------------------------------------------------------------------------
// 左侧导航
// -----------------------------------------------------------------------------

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.repository,
    required this.isDemoData,
    required this.section,
    required this.onSection,
    required this.onOpenProject,
  });

  final PlannerRepository repository;
  final bool isDemoData;
  final AppSection section;
  final ValueChanged<AppSection> onSection;
  final ValueChanged<String> onOpenProject;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppSizes.sidebarWidth,
      decoration: const BoxDecoration(
        color: AppColors.surfaceSunken,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: <Widget>[
          const _SidebarBrand(),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _SectionLabel('视图'),
                  _NavItem(
                    key: const ValueKey<String>('nav-calendar'),
                    icon: Icons.calendar_month_outlined,
                    label: '日历',
                    active: section == AppSection.calendar,
                    onTap: () => onSection(AppSection.calendar),
                  ),
                  _NavItem(
                    key: const ValueKey<String>('nav-projects'),
                    icon: Icons.folder_outlined,
                    label: '项目',
                    active: section == AppSection.projects,
                    onTap: () => onSection(AppSection.projects),
                  ),
                  _NavItem(
                    key: const ValueKey<String>('nav-tasks'),
                    icon: Icons.checklist_rounded,
                    label: '任务',
                    active: section == AppSection.tasks,
                    onTap: () => onSection(AppSection.tasks),
                  ),
                  _NavItem(
                    key: const ValueKey<String>('nav-completed'),
                    icon: Icons.task_alt_rounded,
                    label: '已完成',
                    active: section == AppSection.completed,
                    onTap: () => onSection(AppSection.completed),
                  ),
                  _NavItem(
                    key: const ValueKey<String>('nav-archive'),
                    icon: Icons.archive_outlined,
                    label: '归档',
                    active: section == AppSection.archive,
                    onTap: () => onSection(AppSection.archive),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  _ProjectsSection(
                    repository: repository,
                    onOpenProject: onOpenProject,
                    onManageProjects: () => onSection(AppSection.projects),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          _SidebarFooter(isDemoData: isDemoData),
        ],
      ),
    );
  }
}

class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSizes.topBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Row(
          children: <Widget>[
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(AppRadius.sm + 1),
              ),
              child: const Icon(
                Icons.calendar_today_rounded,
                size: 14,
                color: AppColors.textInverse,
              ),
            ),
            const SizedBox(width: AppSpacing.sm + 2),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('计划台', style: AppText.h2.copyWith(fontSize: 15)),
                Text(
                  'PLANNER',
                  style: AppText.micro.copyWith(
                    fontSize: 9,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xs + 2,
      ),
      child: Row(
        children: <Widget>[
          Text(
            text,
            style: AppText.micro.copyWith(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (trailing != null) Text(trailing!, style: AppText.micro),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? AppColors.accent : AppColors.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onHover: (_) {
        // 兜底：指针仍在本项上时，任何一次移动都把 hover 补回来。
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          height: 34,
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 1,
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2),
          decoration: BoxDecoration(
            // 选中 = 浅蓝（accentSoft）；悬停 = 浅灰。两者都只在 alpha 上过渡，
            // 避免从透明黑补间时闪一下深灰。
            color: widget.active
                ? AppColors.accentSoft
                : _sunkenHoverColor.withValues(alpha: _hovered ? 1 : 0),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: <Widget>[
              Icon(widget.icon, size: AppSizes.iconSm + 1, color: color),
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: Text(
                  widget.label,
                  style: AppText.body.copyWith(
                    fontSize: 13,
                    fontWeight: widget.active
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: widget.active
                        ? AppColors.accent
                        : AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectsSection extends StatelessWidget {
  const _ProjectsSection({
    required this.repository,
    required this.onOpenProject,
    required this.onManageProjects,
  });

  final PlannerRepository repository;
  final ValueChanged<String> onOpenProject;
  final VoidCallback onManageProjects;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Project>>(
      stream: repository.watchProjects(),
      builder: (context, projectsSnapshot) {
        final projects = projectsSnapshot.data ?? const <Project>[];
        return StreamBuilder<List<PlannerTask>>(
          stream: repository.watchAllTasks(),
          builder: (context, tasksSnapshot) {
            final tasks = tasksSnapshot.data ?? const <PlannerTask>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _SectionLabel('项目', trailing: '${projects.length}'),
                for (final project in projects)
                  _ProjectRow(
                    key: ValueKey<String>('sidebar-project-${project.id}'),
                    label: project.name,
                    color: project.color,
                    count: tasks
                        .where(
                          (task) =>
                              task.projectId == project.id && !task.isDone,
                        )
                        .length,
                    onTap: () => onOpenProject(project.id),
                  ),
                if (projects.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.xs,
                    ),
                    child: Text('还没有项目', style: AppText.micro),
                  ),
                _ProjectRow(
                  icon: Icons.tune_rounded,
                  label: '管理项目',
                  count: 0,
                  onTap: onManageProjects,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ProjectRow extends StatefulWidget {
  const _ProjectRow({
    super.key,
    required this.label,
    required this.count,
    required this.onTap,
    this.color,
    this.icon,
  });

  final String label;
  final int count;
  final VoidCallback onTap;
  final ProjectColor? color;
  final IconData? icon;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onHover: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          height: 32,
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 1,
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2),
          decoration: BoxDecoration(
            color: _sunkenHoverColor.withValues(alpha: _hovered ? 1 : 0),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: <Widget>[
              if (widget.icon != null)
                Icon(
                  widget.icon,
                  size: AppSizes.iconSm,
                  color: AppColors.textTertiary,
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.color?.uiColor ?? AppColors.textTertiary,
                    shape: BoxShape.circle,
                  ),
                ),
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: Text(
                  widget.label,
                  style: AppText.body.copyWith(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.count > 0)
                Text(
                  '${widget.count}',
                  style: AppText.micro.copyWith(color: AppColors.textTertiary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({required this.isDemoData});

  final bool isDemoData;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (isDemoData)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs + 2,
              ),
              decoration: BoxDecoration(
                color: AppColors.warningSoft,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: const Color(0xFFF3DFB6)),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.science_outlined,
                    size: 14,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Expanded(
                    child: Text(
                      '演示数据 · 未接入本地库',
                      style: AppText.micro.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (isDemoData) const SizedBox(height: AppSpacing.sm + 2),
          Row(
            children: <Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.xs + 2),
              const Expanded(
                child: Text('本地优先 · 云同步可选', style: AppText.micro),
              ),
              const Text('v2.0.0', style: AppText.micro),
            ],
          ),
        ],
      ),
    );
  }
}
