import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'day_detail_math.dart';

/// 时间轴上的单条任务。
///
/// 桌面端信息密度优先：时间列、项目色竖条、标题、项目/优先级/重叠标记、备注摘要，
/// 高度控制在 44–64 之间；hover 才出现编辑/删除，避免视觉噪音。
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
              _TimeColumn(task: task, done: done),
              const SizedBox(width: AppSpacing.sm),
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
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: done
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                          decoration: done
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          decorationColor: AppColors.textTertiary,
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
                        Text(
                          task.notes,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.micro.copyWith(
                            fontSize: 11,
                            color: AppColors.textTertiary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              SizedBox(
                width: 40,
                height: 22,
                child: _hovered
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          _MiniIconButton(
                            key: ValueKey<String>('task-edit-${task.id}'),
                            icon: Icons.edit_outlined,
                            tooltip: '编辑任务',
                            onTap: widget.onEdit,
                          ),
                          _MiniIconButton(
                            key: ValueKey<String>('task-delete-${task.id}'),
                            icon: Icons.delete_outline_rounded,
                            tooltip: '删除任务',
                            onTap: widget.onDelete,
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
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
              fontSize: 10,
              color: AppColors.textDisabled,
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
    return Container(
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
          Text(
            name,
            style: AppText.micro.copyWith(
              fontSize: 10,
              color: AppColors.textTertiary,
            ),
          ),
        ],
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

/// 行尾的小图标按钮（编辑 / 删除），只在 hover 时出现。
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

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: AppRadius.control,
        onTap: onTap,
        child: SizedBox(
          width: 20,
          height: 22,
          child: Icon(icon, size: 14, color: AppColors.textTertiary),
        ),
      ),
    );
  }
}
