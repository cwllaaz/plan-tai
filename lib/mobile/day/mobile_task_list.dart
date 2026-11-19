import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../../features/day_detail/day_detail_math.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import '../util/mobile_tasks.dart';
import 'mobile_task_row.dart';

/// 每日任务列表：有固定时间 → 未安排时间 → 「新建任务」。
///
/// 勾选完成在列表内部直接写仓储（写失败提示并保留原状态，流会自动回滚显示）。
/// 点击行 → [onEditTask] 打开编辑面板；[onAddTask] 打开新建面板。
class MobileTaskList extends StatefulWidget {
  const MobileTaskList({
    super.key,
    required this.repository,
    required this.tasks,
    required this.projects,
    required this.today,
    required this.onEditTask,
    required this.onAddTask,
    this.scrollable = false,
    this.showDateLabel = false,
    this.emptyTitle = '这一天还没有任务',
    this.emptyMessage = '把要做的事记下来，完成情况会自动统计。',
    this.addLabel = '新建任务',
    this.showAddButton = true,
    this.compactEmpty = false,
  });

  final PlannerRepository repository;
  final List<PlannerTask> tasks;
  final Map<String, Project> projects;
  final LocalDate today;
  final ValueChanged<PlannerTask> onEditTask;
  final VoidCallback onAddTask;
  final bool scrollable;
  final bool showDateLabel;
  final String emptyTitle;
  final String emptyMessage;
  final String addLabel;
  final bool showAddButton;
  final bool compactEmpty;

  @override
  State<MobileTaskList> createState() => _MobileTaskListState();
}

class _MobileTaskListState extends State<MobileTaskList> {
  final Set<String> _pending = <String>{};

  Future<void> _toggle(PlannerTask task) async {
    if (_pending.contains(task.id)) return;
    setState(() => _pending.add(task.id));
    final next = task.isDone ? TaskStatus.todo : TaskStatus.done;
    try {
      await widget.repository.updateTask(task.copyWith(status: next));
    } on PlannerException catch (error) {
      if (mounted) {
        showMobileSnack(context, error.message, error: true);
      }
    } on Object {
      if (mounted) {
        showMobileSnack(context, '更新任务状态失败，请稍后重试', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _pending.remove(task.id));
      } else {
        _pending.remove(task.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final split = splitDayTasks(widget.tasks);
    final children = <Widget>[
      if (widget.tasks.isEmpty && widget.compactEmpty)
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(widget.emptyTitle, style: AppText.caption),
        )
      else if (widget.tasks.isEmpty)
        MobileEmptyState(
          title: widget.emptyTitle,
          message: widget.emptyMessage,
          icon: Icons.task_alt_rounded,
          actionLabel: widget.showAddButton ? widget.addLabel : null,
          onAction: widget.showAddButton ? widget.onAddTask : null,
        )
      else ...<Widget>[
        for (final task in split.timed)
          MobileTaskRow(
            key: ValueKey<String>('mobile-task-${task.id}'),
            task: task,
            projects: widget.projects,
            today: widget.today,
            showDateLabel: widget.showDateLabel,
            pending: _pending.contains(task.id),
            onTap: () => widget.onEditTask(task),
            onToggle: () => _toggle(task),
          ),
        if (split.timed.isNotEmpty && split.untimed.isNotEmpty)
          _UntimedDivider(count: split.untimed.length),
        for (final task in split.untimed)
          MobileTaskRow(
            key: ValueKey<String>('mobile-task-${task.id}'),
            task: task,
            projects: widget.projects,
            today: widget.today,
            showDateLabel: widget.showDateLabel,
            pending: _pending.contains(task.id),
            onTap: () => widget.onEditTask(task),
            onToggle: () => _toggle(task),
          ),
        if (widget.showAddButton)
          _AddTaskRow(onTap: widget.onAddTask, label: widget.addLabel),
      ],
    ];

    if (widget.scrollable) {
      return ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
        children: children,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _UntimedDivider extends StatelessWidget {
  const _UntimedDivider({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '未安排时间',
            style: AppText.micro.copyWith(
              fontSize: 11.5,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Container(height: 1, color: AppColors.border)),
          const SizedBox(width: AppSpacing.sm),
          Text('$count 项', style: AppText.micro.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

class _AddTaskRow extends StatelessWidget {
  const _AddTaskRow({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey<String>('mobile-add-task'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: MobileMetrics.listRowMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.add_rounded,
                  size: 16,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                label,
                style: AppText.bodyStrong.copyWith(
                  fontSize: 14,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 当天完成率摘要行：`完成 1/3 · 60%` + 进度条。
class MobileDayStatsRow extends StatelessWidget {
  const MobileDayStatsRow({super.key, required this.tasks});

  final List<PlannerTask> tasks;

  @override
  Widget build(BuildContext context) {
    final stats = computeDayTaskStats(tasks);
    if (stats.total == 0) {
      return Text('暂无任务', style: AppText.caption.copyWith(fontSize: 12));
    }
    return Row(
      children: <Widget>[
        Text(stats.summaryLabel, style: AppText.caption.copyWith(fontSize: 12)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: CompletionBar(done: stats.done, total: stats.total),
        ),
      ],
    );
  }
}
