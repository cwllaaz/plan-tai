import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/shell_state.dart';
import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../day/mobile_task_actions.dart';
import '../day/mobile_task_list.dart';
import '../day/mobile_task_row.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import '../util/mobile_tasks.dart';

/// 「今日」分区：今天要做的事、逾期未完成、收件箱（未排期）。
class MobileTodayPage extends StatefulWidget {
  const MobileTodayPage({
    super.key,
    required this.repository,
    required this.shell,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;

  @override
  State<MobileTodayPage> createState() => _MobileTodayPageState();
}

class _MobileTodayPageState extends State<MobileTodayPage> {
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  List<PlannerTask> _todayTasks = const <PlannerTask>[];
  List<PlannerTask> _overdue = const <PlannerTask>[];
  List<PlannerTask> _unscheduled = const <PlannerTask>[];
  List<Project> _projects = const <Project>[];

  Map<String, Project> get _projectsById => <String, Project>{
    for (final project in _projects) project.id: project,
  };

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant MobileTodayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _listen() {
    final repository = widget.repository;
    final today = widget.shell.today;
    _subscriptions
      ..add(
        repository.watchTasksInRange(LocalDateRange.singleDay(today)).listen((
          List<PlannerTask> tasks,
        ) {
          if (mounted) setState(() => _todayTasks = tasks);
        }),
      )
      ..add(
        repository
            .watchTasksInRange(
              LocalDateRange(today.addDays(-90), today.addDays(-1)),
            )
            .listen((List<PlannerTask> tasks) {
              if (mounted) {
                setState(() => _overdue = overdueTasksOf(tasks, today));
              }
            }),
      )
      ..add(
        repository.watchUnscheduledTasks().listen((List<PlannerTask> tasks) {
          if (mounted) setState(() => _unscheduled = tasks);
        }),
      )
      ..add(
        repository.watchProjects().listen((List<Project> projects) {
          if (mounted) setState(() => _projects = projects);
        }),
      );
  }

  Future<void> _newTask() async {
    await openMobileTaskEditor(
      context,
      repository: widget.repository,
      projects: _projects,
      defaultDate: widget.shell.today,
      today: widget.shell.today,
    );
  }

  Future<void> _editTask(PlannerTask task) async {
    await openMobileTaskEditor(
      context,
      repository: widget.repository,
      projects: _projects,
      defaultDate: widget.shell.selectedDate,
      today: widget.shell.today,
      initial: task,
    );
  }

  Future<void> _toggle(PlannerTask task) async {
    await toggleMobileTaskDone(
      context,
      repository: widget.repository,
      task: task,
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = widget.shell.today;
    return ListView(
      key: const ValueKey<String>('mobile-today-page'),
      padding: const EdgeInsets.fromLTRB(
        MobileMetrics.pagePadding,
        AppSpacing.md,
        MobileMetrics.pagePadding,
        AppSpacing.xxxl,
      ),
      children: <Widget>[
        _TodaySummary(today: today, tasks: _todayTasks),
        const SizedBox(height: AppSpacing.md),
        MobileCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xs,
                ),
                child: MobileSectionHeader(
                  title: '今日任务',
                  subtitle: dayCountLabel(_todayTasks),
                  trailing: MobileTextButton(
                    label: '新建',
                    icon: Icons.add_rounded,
                    onPressed: _newTask,
                  ),
                ),
              ),
              MobileTaskList(
                repository: widget.repository,
                tasks: _todayTasks,
                projects: _projectsById,
                today: today,
                onEditTask: _editTask,
                onAddTask: _newTask,
                emptyTitle: '今天还没有任务',
                emptyMessage: '先加一件最重要的事，其余的可以慢慢排。',
                addLabel: '新建今天的任务',
              ),
            ],
          ),
        ),
        if (_overdue.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _SectionHeader(
            title: '逾期未完成',
            subtitle: '${_overdue.length} 项',
            icon: Icons.warning_amber_rounded,
            iconColor: AppColors.warning,
          ),
          MobileCard(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final task in _overdue)
                  MobileTaskRow(
                    key: ValueKey<String>('mobile-overdue-${task.id}'),
                    task: task,
                    projects: _projectsById,
                    today: today,
                    showDateLabel: true,
                    onTap: () => _editTask(task),
                    onToggle: () => _toggle(task),
                  ),
              ],
            ),
          ),
        ],
        if (_unscheduled.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _SectionHeader(
            title: '收件箱',
            subtitle: '${_unscheduled.length} 项未排期',
            icon: Icons.inbox_outlined,
            iconColor: AppColors.textTertiary,
          ),
          MobileCard(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final task in _unscheduled)
                  MobileTaskRow(
                    key: ValueKey<String>('mobile-inbox-${task.id}'),
                    task: task,
                    projects: _projectsById,
                    today: today,
                    onTap: () => _editTask(task),
                    onToggle: () => _toggle(task),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _TodaySummary extends StatelessWidget {
  const _TodaySummary({required this.today, required this.tasks});

  final LocalDate today;
  final List<PlannerTask> tasks;

  @override
  Widget build(BuildContext context) {
    final stats = splitDayTasks(tasks);
    final done = tasks.where((PlannerTask task) => task.isDone).length;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('今天', style: AppText.h1.copyWith(fontSize: 20)),
              const SizedBox(width: AppSpacing.sm),
              Text(
                monthDayWithWeekday(today),
                style: AppText.caption.copyWith(fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            tasks.isEmpty
                ? '今天还没有安排，先加一件小事开始。'
                : '已完成 $done / ${tasks.length} 项 · 还有 ${stats.timed.length + stats.untimed.length - done} 项待完成',
            style: AppText.small.copyWith(fontSize: 13),
          ),
          if (tasks.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm + 2),
            CompletionBar(done: done, total: tasks.length),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(title, style: AppText.bodyStrong.copyWith(fontSize: 14)),
          const SizedBox(width: AppSpacing.sm),
          Text(subtitle, style: AppText.caption.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}
