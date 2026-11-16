import 'package:material_ui/material_ui.dart';

import '../../app/shell_state.dart';
import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_navigation.dart';

/// 平板三栏布局的左侧项目导航（200–240dp）：
/// 分区入口 + 项目列表（颜色点 + 名称 + 任务计数）+ 管理项目入口。
class MobileProjectNav extends StatelessWidget {
  const MobileProjectNav({
    super.key,
    required this.repository,
    required this.shell,
    required this.current,
    required this.onSelect,
    required this.onOpenProject,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;
  final MobileTab current;
  final ValueChanged<MobileTab> onSelect;

  /// 点击项目时直接打开项目详情（平板大屏不需要先切列表再点一次）。
  final ValueChanged<String> onOpenProject;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MobileMetrics.projectNavWidth,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _Brand(),
          for (final tab in MobileTab.values)
            _NavRow(
              tab: tab,
              selected: tab == current,
              onTap: () => onSelect(tab),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Divider(height: 1),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Text(
                  '项目',
                  style: AppText.caption.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                StreamBuilder<List<Project>>(
                  stream: repository.watchProjects(),
                  builder:
                      (BuildContext context, AsyncSnapshot<List<Project>> s) {
                        final count = s.data?.length ?? 0;
                        return Text(
                          '$count',
                          style: AppText.micro.copyWith(fontSize: 11),
                        );
                      },
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Project>>(
              stream: repository.watchProjects(),
              builder: (BuildContext context, AsyncSnapshot<List<Project>> s) {
                final projects = s.data ?? const <Project>[];
                if (projects.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(
                      '还没有项目',
                      style: AppText.micro.copyWith(fontSize: 11.5),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  children: <Widget>[
                    for (final project in projects)
                      _ProjectRow(
                        project: project,
                        selected:
                            shell.focusedProjectId == project.id &&
                            current == MobileTab.projects,
                        onTap: () {
                          shell.openProject(project.id);
                          onOpenProject(project.id);
                        },
                      ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              '本地优先 · 云同步可选',
              style: AppText.micro.copyWith(fontSize: 10.5),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(
              Icons.calendar_month_rounded,
              size: 16,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('计划台', style: AppText.h2.copyWith(fontSize: 15)),
                Text(
                  'PLANNER',
                  style: AppText.micro.copyWith(
                    fontSize: 9,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final MobileTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return InkWell(
      key: ValueKey<String>('mobile-nav-${tab.name}'),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 1,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 9,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 18,
              color: color,
            ),
            const SizedBox(width: AppSpacing.sm + 2),
            Text(
              tab.label,
              style: AppText.bodyStrong.copyWith(fontSize: 13.5, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.selected,
    required this.onTap,
  });

  final Project project;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey<String>('mobile-nav-project-${project.id}'),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 1,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: project.color.uiColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(
                  fontSize: 13,
                  color: selected ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
