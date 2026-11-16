import '../../core/models/models.dart';
import '../../features/day_detail/day_detail_math.dart';

/// 从任务生成「重新创建」用的草稿，供删除撤销使用。
///
/// 仓储的撤销语义是「立即从列表移除 + SnackBar 可撤销」；软删除无法把原 id
/// 复活（仓储不暴露 undelete），因此撤销走 `createTask` 重建同一份内容
/// （标题/项目/安排/日期/时间/优先级/状态/顺序都保留）。
PlannerTaskDraft draftForRecreate(PlannerTask task) => PlannerTaskDraft(
  title: task.title,
  projectId: task.projectId,
  spanId: task.spanId,
  notes: task.notes,
  scheduledDate: task.scheduledDate,
  timeSlot: task.timeSlot,
  priority: task.priority,
  status: task.status,
  sortOrder: task.sortOrder,
);

/// 逾期任务：排期在今天之前且尚未完成。
List<PlannerTask> overdueTasksOf(Iterable<PlannerTask> tasks, LocalDate today) {
  final result = <PlannerTask>[];
  for (final task in tasks) {
    final day = task.scheduledDate;
    if (day == null || task.isDone) continue;
    if (day.isBefore(today)) result.add(task);
  }
  result.sort((PlannerTask a, PlannerTask b) {
    final byDate = a.scheduledDate!.compareTo(b.scheduledDate!);
    if (byDate != 0) return byDate;
    return a.title.compareTo(b.title);
  });
  return result;
}

/// 未完成的任务（保持仓储顺序）。
List<PlannerTask> undoneTasksOf(Iterable<PlannerTask> tasks) => <PlannerTask>[
  for (final task in tasks)
    if (!task.isDone) task,
];

/// 当天已完成 / 全部任务的简要文案：`3 项 · 完成 1 项`。
String dayCountLabel(Iterable<PlannerTask> tasks) {
  final stats = computeDayTaskStats(tasks);
  if (stats.total == 0) return '暂无任务';
  if (stats.done == 0) return '${stats.total} 项任务';
  return '${stats.total} 项 · 完成 ${stats.done} 项';
}

/// 完成率圆环上的文案：`60%`。
String completionPercentLabel(Iterable<PlannerTask> tasks) {
  final stats = computeDayTaskStats(tasks);
  if (stats.total == 0) return '';
  return '${stats.percent}%';
}

/// 任务在一行里展示的时间前缀；没有固定时间返回空串。
String taskTimePrefix(PlannerTask task) => task.timeSlot?.startLabel ?? '';

/// 任务按「有固定时间」和「未安排时间」分组，供每日面板分区展示。
({List<PlannerTask> timed, List<PlannerTask> untimed}) splitDayTasks(
  Iterable<PlannerTask> tasks,
) {
  final list = tasks.toList(growable: false);
  return (timed: timedTasksOf(list), untimed: untimedTasksOf(list));
}
