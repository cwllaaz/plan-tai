import 'package:material_ui/material_ui.dart';

import '../../app/shell_state.dart';
import '../../app/unfiled_group.dart';
import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_project_detail_page.dart';
import 'mobile_project_editor_sheet.dart';

/// 项目分区：全部项目（可切换显示已归档）、任务计数、颜色、进入项目详情。
class MobileProjectsPage extends StatefulWidget {
  const MobileProjectsPage({
    super.key,
    required this.repository,
    required this.shell,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;

  @override
  State<MobileProjectsPage> createState() => _MobileProjectsPageState();
}

class _MobileProjectsPageState extends State<MobileProjectsPage> {
  bool _showArchived = false;

  Future<void> _createProject() async {
    final saved = await showMobileProjectEditorSheet(
      context,
      repository: widget.repository,
    );
    if (!saved || !mounted) return;
    showMobileSnack(context, '已创建项目');
  }

  Future<void> _openProject(String projectId) async {
    widget.shell.focusProject(projectId);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => MobileProjectDetailPage(
          repository: widget.repository,
          projectId: projectId,
          today: widget.shell.today,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Project>>(
      stream: widget.repository.watchProjects(includeArchived: true),
      builder: (BuildContext context, AsyncSnapshot<List<Project>> projects) {
        return StreamBuilder<List<PlannerTask>>(
          stream: widget.repository.watchAllTasks(),
          builder: (BuildContext context, AsyncSnapshot<List<PlannerTask>> tasks) {
            final allProjects = projects.data ?? const <Project>[];
            final allTasks = tasks.data ?? const <PlannerTask>[];
            final visible = allProjects
                .where(
                  (Project project) => _showArchived || !project.isArchived,
                )
                .toList(growable: false);
            final counts = <String, int>{};
            for (final task in allTasks) {
              final projectId = task.projectId;
              if (projectId == null) continue;
              counts[projectId] = (counts[projectId] ?? 0) + 1;
            }
            return ListView(
              key: const ValueKey<String>('mobile-projects-page'),
              padding: const EdgeInsets.fromLTRB(
                MobileMetrics.pagePadding,
                AppSpacing.md,
                MobileMetrics.pagePadding,
                AppSpacing.xxxl,
              ),
              children: <Widget>[
                MobileSectionHeader(
                  title: '项目',
                  subtitle:
                      '共 ${allProjects.length} 个 · 归档 ${allProjects.where((Project p) => p.isArchived).length} 个',
                  trailing: MobileTextButton(
                    key: const ValueKey<String>('mobile-project-create'),
                    label: '新建',
                    icon: Icons.add_rounded,
                    onPressed: _createProject,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                MobileCard(
                  padding: EdgeInsets.zero,
                  child: MobileSwitchRow(
                    key: const ValueKey<String>('mobile-projects-archived'),
                    title: '显示已归档项目',
                    subtitle: '归档项目默认不出现在月历中',
                    value: _showArchived,
                    onChanged: (bool value) =>
                        setState(() => _showArchived = value),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm + 2),
                if (visible.isEmpty)
                  MobileEmptyState(
                    title: _showArchived ? '还没有项目' : '还没有进行中的项目',
                    message: '新建一个项目，把相关任务与跨天安排归在一起。',
                    icon: Icons.folder_outlined,
                    actionLabel: '新建项目',
                    onAction: _createProject,
                  )
                else
                  for (final project in visible) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _ProjectCard(
                        project: project,
                        taskCount: counts[project.id] ?? 0,
                        onTap: () => _openProject(project.id),
                      ),
                    ),
                  ],
              ],
            );
          },
        );
      },
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.taskCount,
    required this.onTap,
  });

  final Project project;
  final int taskCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isUnfiled = project.name == kUnfiledProjectName;
    return MobileCard(
      key: ValueKey<String>('mobile-project-${project.id}'),
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 4,
            height: 38,
            decoration: BoxDecoration(
              color: project.color.uiColor,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong.copyWith(fontSize: 15),
                      ),
                    ),
                    if (project.status != ProjectStatus.active) ...<Widget>[
                      const SizedBox(width: AppSpacing.xs + 2),
                      MobileTag(
                        label: project.status.label,
                        color: project.isArchived
                            ? AppColors.textTertiary
                            : AppColors.warning,
                      ),
                    ],
                    if (isUnfiled) ...<Widget>[
                      const SizedBox(width: AppSpacing.xs + 2),
                      const MobileTag(
                        label: '系统分组',
                        color: AppColors.textTertiary,
                      ),
                    ],
                  ],
                ),
                if (project.description.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    project.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(fontSize: 12),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '$taskCount 项任务',
                  style: AppText.micro.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: AppColors.textDisabled,
          ),
        ],
      ),
    );
  }
}
