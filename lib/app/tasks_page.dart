import 'package:material_ui/material_ui.dart';

import '../core/contracts/contracts.dart';
import '../core/format/format.dart';
import '../core/models/models.dart';
import '../core/theme/theme.dart';
import 'shell_state.dart';

/// 「任务」与「已完成」两个入口共用的列表页。
///
/// 数据来自 `watchAllTasks()`（V1 量级允许），按日期分组；点任务会回到月历并
/// 打开当天面板，编辑仍然只发生在每日面板里（单一编辑入口）。
class TasksPage extends StatelessWidget {
  const TasksPage({
    super.key,
    required this.repository,
    required this.shell,
    required this.completed,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;

  /// true = 已完成列表；false = 待办列表。
  final bool completed;

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

  Future<void> _toggle(
    BuildContext context,
    PlannerTask task,
  ) async {
    try {
      await repository.updateTask(
        task.copyWith(
          status: task.isDone ? TaskStatus.todo : TaskStatus.done,
        ),
      );
    } on PlannerException catch (error) {
      if (!context.mounted) return;
      _notify(context, error.message, error: true);
    }
  }

  void _open(PlannerTask task) {
    final date = task.scheduledDate ?? shell.today;
    shell.showSection(AppSection.calendar);
    shell.openDay(date);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Header(completed: completed),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.panel,
              border: Border.all(color: AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: StreamBuilder<List<PlannerTask>>(
              stream: repository.watchAllTasks(),
              builder: (context, snapshot) {
                final all = snapshot.data ?? const <PlannerTask>[];
                final tasks =
                    all.where((task) => task.isDone == completed).toList()
                      ..sort(_compareTasks);
                if (tasks.isEmpty) {
                  return _Empty(completed: completed);
                }
                final rows = <Widget>[];
                LocalDate? lastDate;
                for (final task in tasks) {
                  final date = task.scheduledDate;
                  if (date != lastDate) {
                    lastDate = date;
                    rows.add(
                      _DateHeader(
                        label: date == null
                            ? '未排期'
                            : monthDayWithWeekday(date),
                        count: tasks
                            .where((t) => t.scheduledDate == date)
                            .length,
                      ),
                    );
                  }
                  rows.add(
                    _TaskRow(
                      key: ValueKey<String>('task-row-${task.id}'),
                      task: task,
                      onToggle: () => _toggle(context, task),
                      onOpen: () => _open(task),
                    ),
                  );
                }
                return ListView(padding: const EdgeInsets.all(AppSpacing.md), children: rows);
              },
            ),
          ),
        ),
      ],
    );
  }

  static int _compareTasks(PlannerTask a, PlannerTask b) {
    final aDate = a.scheduledDate;
    final bDate = b.scheduledDate;
    if (aDate == null && bDate != null) return 1;
    if (aDate != null && bDate == null) return -1;
    if (aDate != null && bDate != null) {
      final byDate = aDate.compareTo(bDate);
      if (byDate != 0) return byDate;
    }
    final aSlot = a.timeSlot;
    final bSlot = b.timeSlot;
    if (aSlot != null && bSlot == null) return -1;
    if (aSlot == null && bSlot != null) return 1;
    if (aSlot != null && bSlot != null) {
      final byTime = aSlot.startMinute.compareTo(bSlot.startMinute);
      if (byTime != 0) return byTime;
    }
    final byPriority = b.priority.level.compareTo(a.priority.level);
    if (byPriority != 0) return byPriority;
    return a.createdAt.compareTo(b.createdAt);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.completed});

  final bool completed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(completed ? '已完成' : '任务', style: AppText.h1),
        const SizedBox(height: 2),
        Text(
          completed
              ? '已完成的任务仍保留在原日期，可随时取消完成。'
              : '所有已排期与未排期的任务；点击一行回到当天面板编辑。',
          style: AppText.caption,
        ),
      ],
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.xs + 2,
      ),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: AppText.micro.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('$count', style: AppText.micro),
        ],
      ),
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onOpen,
  });

  final PlannerTask task;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onHover: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            // 只在 alpha 上过渡：用 Colors.transparent 补间会经过半透明黑，
            // 进出时各闪一下深灰。
            color: AppColors.surfaceHover.withValues(alpha: _hovered ? 1 : 0),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: Checkbox(
                  value: task.isDone,
                  onChanged: (_) => widget.onToggle(),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: AppColors.borderStrong),
                ),
              ),
              if (task.projectId != null) ...<Widget>[
                const SizedBox(width: AppSpacing.xs),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.textTertiary,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  task.title,
                  style: AppText.body.copyWith(
                    fontSize: 13,
                    decoration: task.isDone ? TextDecoration.lineThrough : null,
                    color: task.isDone
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (task.timeSlot != null) ...<Widget>[
                Text(timeSlotLabel(task.timeSlot), style: AppText.micro),
                const SizedBox(width: AppSpacing.md),
              ],
              if (task.priority.level >= 2)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: task.priority.level >= 3
                        ? AppColors.dangerSoft
                        : AppColors.warningSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    task.priority.label,
                    style: AppText.micro.copyWith(
                      color: task.priority.level >= 3
                          ? AppColors.danger
                          : AppColors.warning,
                    ),
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right_rounded,
                size: AppSizes.iconSm,
                color: _hovered ? AppColors.textTertiary : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.completed});

  final bool completed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            completed
                ? Icons.task_alt_rounded
                : Icons.checklist_rtl_rounded,
            size: 44,
            color: AppColors.textDisabled,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            completed ? '还没有完成的任务' : '还没有任务',
            style: AppText.h2,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            completed ? '在每日面板勾选完成后，任务会出现在这里。' : '双击月历上的日期，在右侧面板新建任务。',
            style: AppText.caption,
          ),
        ],
      ),
    );
  }
}
