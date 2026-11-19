import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'day_detail_math.dart';

/// 时间轴上的单条任务。
///
/// 标题优先，时间单独成列；项目和备注可悬停读全，编辑始终可见。
class TaskTile extends StatefulWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.project,
    required this.overlap,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.busy = false,
  });

  final PlannerTask task;

  /// 任务所属项目；null = 未归项目。
  final Project? project;

  /// 第一条与它时间重叠的任务；null = 无重叠。
  final PlannerTask? overlap;

  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// 写操作进行中时禁用勾选框，避免连续点击产生并发写。
  final bool busy;

  @override
  State<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<TaskTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final done = task.isDone;
    final projectColor =
        widget.project?.color.uiColor ?? AppColors.borderStrong;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onEdit,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            7,
            AppSpacing.sm,
            7,
          ),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.surfaceHover : Colors.transparent,
            borderRadius: AppRadius.control,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: Checkbox(
                    value: done,
                    onChanged: widget.busy
                        ? null
                        : (bool? value) => widget.onToggle(),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: const BorderSide(
                      color: AppColors.borderStrong,
                      width: 1.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs + 2),
              if (task.timeSlot != null) ...<Widget>[
                _TimeColumn(task: task, done: done),
                const SizedBox(width: AppSpacing.sm),
              ],
              Container(
                width: 2.5,
                height: 34,
                decoration: BoxDecoration(
                  color: done ? AppColors.borderStrong : projectColor,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: AnimatedOpacity(
                  duration: AppMotion.hover,
                  opacity: done ? 0.62 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Tooltip(
                        message: task.title,
                        child: Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStrong.copyWith(
                            height: 1.35,
                            color: done
                                ? AppColors.textSecondary
                                : AppColors.textPrimary,
                            decoration: done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: AppSpacing.xs + 2,
                        runSpacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          _ProjectChip(project: widget.project),
                          _PriorityChip(priority: task.priority, muted: done),
                          if (widget.overlap != null)
                            _OverlapChip(task: task, other: widget.overlap!),
                        ],
                      ),
                      if (task.notes.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 3),
                        Tooltip(
                          message: task.notes,
                          child: Text(
                            task.notes,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              color: AppColors.textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _MiniIconButton(
                    key: ValueKey<String>('task-edit-${task.id}'),
                    icon: Icons.edit_outlined,
                    tooltip: '编辑任务',
                    onTap: widget.onEdit,
                  ),
                  if (_hovered)
                    _MiniIconButton(
                      key: ValueKey<String>('task-delete-${task.id}'),
                      icon: Icons.delete_outline_rounded,
                      tooltip: '删除任务',
                      onTap: widget.onDelete,
                    )
                  else
                    const SizedBox(width: _MiniIconButton.extent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 开始/结束时间列，等宽数字避免行与行之间抖动。
class _TimeColumn extends StatelessWidget {
  const _TimeColumn({required this.task, required this.done});

  final PlannerTask task;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final slot = task.timeSlot;
    if (slot == null) return const SizedBox(width: 40);
    return SizedBox(
      width: 40,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            slot.startLabel,
            style: AppText.numeric.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: done ? AppColors.textTertiary : AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            slot.endLabel,
            style: AppText.numeric.copyWith(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectChip extends StatelessWidget {
  const _ProjectChip({required this.project});

  final Project? project;

  @override
  Widget build(BuildContext context) {
    final name = project?.name ?? '未归项目';
    return Tooltip(
      message: name,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: project?.color.uiColor ?? AppColors.textDisabled,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.micro.copyWith(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PriorityChip extends StatelessWidget {
  const _PriorityChip({required this.priority, required this.muted});

  final TaskPriority priority;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final Color foreground;
    final Color background;
    switch (priority) {
      case TaskPriority.urgent:
        foreground = muted ? AppColors.textTertiary : AppColors.danger;
        background = muted ? AppColors.surfaceSunken : AppColors.dangerSoft;
      case TaskPriority.high:
        foreground = muted ? AppColors.textTertiary : AppColors.warning;
        background = muted ? AppColors.surfaceSunken : AppColors.warningSoft;
      case TaskPriority.normal:
      case TaskPriority.low:
        foreground = AppColors.textTertiary;
        background = AppColors.surfaceSunken;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        priority.label,
        style: AppText.micro.copyWith(fontSize: 10, color: foreground),
      ),
    );
  }
}

class _OverlapChip extends StatelessWidget {
  const _OverlapChip({required this.task, required this.other});

  final PlannerTask task;
  final PlannerTask other;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: overlapHint(task, other),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.warningSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.error_outline_rounded,
              size: 11,
              color: AppColors.warning,
            ),
            const SizedBox(width: 2),
            Text(
              '时间重叠',
              style: AppText.micro.copyWith(
                fontSize: 10,
                color: AppColors.warning,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 行尾操作固定宽度，悬停时不会挤动标题。
class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  static const double extent = 26;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: AppRadius.control,
        onTap: onTap,
        child: SizedBox(
          width: extent,
          height: extent,
          child: Icon(icon, size: 15, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
