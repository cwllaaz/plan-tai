import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';

/// 每日任务列表里的一行（整行 ≥56dp，勾选圈独立 48dp 命中区）。
class MobileTaskRow extends StatelessWidget {
  const MobileTaskRow({
    super.key,
    required this.task,
    required this.projects,
    required this.today,
    required this.onTap,
    required this.onToggle,
    this.showDateLabel = false,
    this.pending = false,
  });

  final PlannerTask task;
  final Map<String, Project> projects;
  final LocalDate today;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  /// 是否显示排期日期（今日页 / 逾期页用）。
  final bool showDateLabel;

  /// 正在写库，忽略重复点击。
  final bool pending;

  Project? get _project {
    final projectId = task.projectId;
    if (projectId == null) return null;
    return projects[projectId];
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    final done = task.isDone;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: MobileMetrics.taskRowMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.only(right: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _ToggleButton(
                key: ValueKey<String>('mobile-task-toggle-${task.id}'),
                done: done,
                pending: pending,
                onTap: onToggle,
                taskTitle: task.title,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong.copyWith(
                          fontSize: 15,
                          height: 1.35,
                          color: done
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                          decoration: done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 3),
                      _buildMeta(project),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.textDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeta(Project? project) {
    final children = <Widget>[];
    if (task.timeSlot != null) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.schedule_rounded,
              size: 12,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 3),
            Text(
              task.timeSlot!.label,
              style: AppText.numeric.copyWith(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }
    if (showDateLabel && task.scheduledDate != null) {
      if (children.isNotEmpty) children.add(const _MetaDot());
      children.add(
        Text(
          relativeDay(task.scheduledDate!, today),
          style: AppText.micro.copyWith(fontSize: 11.5),
        ),
      );
    }
    if (project != null) {
      if (children.isNotEmpty) children.add(const _MetaDot());
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ProjectColorDot(color: project.color, size: 8),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption,
              ),
            ),
          ],
        ),
      );
    }
    if (task.priority != TaskPriority.normal) {
      if (children.isNotEmpty) children.add(const _MetaDot());
      children.add(PriorityBadge(priority: task.priority));
    }
    if (children.isEmpty) {
      return Text(
        '未归项目 · 未排具体时间',
        style: AppText.micro.copyWith(fontSize: 11.5),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

class _MetaDot extends StatelessWidget {
  const _MetaDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2,
      height: 2,
      decoration: const BoxDecoration(
        color: AppColors.textDisabled,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 勾选圈：48dp 命中区，24dp 可视圆圈。
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    super.key,
    required this.done,
    required this.pending,
    required this.onTap,
    required this.taskTitle,
  });

  final bool done;
  final bool pending;
  final VoidCallback onTap;
  final String taskTitle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: done ? '取消完成：$taskTitle' : '标记完成：$taskTitle',
      checked: done,
      button: true,
      child: InkResponse(
        onTap: pending ? null : onTap,
        radius: MobileMetrics.minTapTarget / 2,
        child: SizedBox(
          width: MobileMetrics.minTapTarget,
          height: MobileMetrics.taskRowMinHeight,
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.hover,
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: done ? AppColors.accent : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: done ? AppColors.accent : AppColors.borderStrong,
                  width: 1.4,
                ),
              ),
              child: done
                  ? const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: AppColors.textInverse,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
