import '../../core/models/models.dart';

/// 当天任务的完成情况统计，供面板头部展示（`完成 3/5 · 60%`）。
///
/// 纯计算、无 BuildContext，方便单测直接覆盖。
final class DayTaskStats {
  const DayTaskStats({required this.total, required this.done});

  /// 没有任务时的空统计。
  static const DayTaskStats empty = DayTaskStats(total: 0, done: 0);

  /// 当天任务总数。
  final int total;

  /// 当天已完成任务数。
  final int done;

  int get remaining => total - done;

  /// 完成率 0–1。
  double get ratio => total == 0 ? 0 : done / total;

  /// 完成率百分比（四舍五入到整数）。
  int get percent => (ratio * 100).round();

  /// 是否全部完成（用于进度条换色）。
  bool get allDone => total > 0 && done == total;

  /// `完成 3/5`
  String get countLabel => '完成 $done/$total';

  /// `完成 3/5 · 60%`（数量格式见 docs/UI_SPEC.md §9）。
  String get summaryLabel => '$countLabel · $percent%';
}

/// 统计当天任务的完成情况。
DayTaskStats computeDayTaskStats(Iterable<PlannerTask> tasks) {
  var total = 0;
  var done = 0;
  for (final task in tasks) {
    total += 1;
    if (task.isDone) done += 1;
  }
  return DayTaskStats(total: total, done: done);
}

/// 有固定时刻的任务，保持仓储给的顺序（开始时间升序）。
List<PlannerTask> timedTasksOf(Iterable<PlannerTask> tasks) =>
    tasks.where((task) => task.timeSlot != null).toList(growable: false);

/// 没有固定时刻的任务，沉到「未安排时间」分组。
List<PlannerTask> untimedTasksOf(Iterable<PlannerTask> tasks) =>
    tasks.where((task) => task.timeSlot == null).toList(growable: false);

/// 当天第几分钟 → `09:00`；`1440` 表示次日 00:00。
String formatMinuteOfDay(int minute) {
  final safe = minute < 0 ? 0 : (minute > 1440 ? 1440 : minute);
  final hour = safe ~/ 60;
  final rest = safe % 60;
  return '${hour.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

/// 解析用户输入的时刻：`9:00` / `09:00` / `09：00` / `9` 都接受，非法返回 null。
///
/// 允许全角冒号是桌面中文输入法下的常见误输入，宽容处理比报错更友好。
int? parseTimeOfDay(String raw) {
  final text = raw.trim().replaceAll('：', ':').replaceAll('．', ':');
  if (text.isEmpty) return null;
  if (text.contains(':')) {
    final parts = text.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0].trim());
    final minuteText = parts[1].trim();
    final minute = minuteText.isEmpty ? 0 : int.tryParse(minuteText);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }
  final hour = int.tryParse(text);
  if (hour == null || hour < 0 || hour > 23) return null;
  return hour * 60;
}

/// 校验开始/结束时间输入；合法返回 null，否则返回可直接展示的中文提示。
String? validateTimeInputs({
  required String startText,
  required String endText,
}) {
  final start = parseTimeOfDay(startText);
  if (start == null) return '开始时间格式应为 09:00';
  final end = parseTimeOfDay(endText);
  if (end == null) return '结束时间格式应为 09:00';
  if (end <= start) return '结束时间必须晚于开始时间';
  return null;
}

/// 把已校验的输入转成 [TimeSlot]；输入非法时抛 [PlannerValidationException]。
TimeSlot timeSlotFromInputs({
  required String startText,
  required String endText,
}) {
  final error = validateTimeInputs(startText: startText, endText: endText);
  if (error != null) throw PlannerValidationException(error);
  return TimeSlot.startEnd(
    startMinute: parseTimeOfDay(startText)!,
    endMinute: parseTimeOfDay(endText)!,
  );
}

/// 填完开始时间后，给一个合理的默认结束时间（+30 分钟）。
String defaultEndTimeText(String startText) {
  final start = parseTimeOfDay(startText);
  if (start == null) return startText;
  final end = start + 30;
  return formatMinuteOfDay(end > 1439 ? 1439 : end);
}

/// 与 [task] 时间重叠的其他任务（相邻不算重叠），按开始时间升序。
List<PlannerTask> overlappingTasks(
  PlannerTask task,
  Iterable<PlannerTask> all,
) {
  final slot = task.timeSlot;
  if (slot == null) return const <PlannerTask>[];
  final overlaps = all
      .where(
        (other) =>
            other.id != task.id &&
            other.timeSlot != null &&
            slot.overlaps(other.timeSlot!),
      )
      .toList(growable: false);
  return overlaps;
}

/// 重叠提示文案（见 docs/MODULE_API.md §3.3 第 6 条）。
String overlapHint(PlannerTask task, PlannerTask other) {
  final slot = other.timeSlot;
  if (slot == null) return '与「${other.title}」的安排重叠';
  return '与你 ${slot.label}「${other.title}」的安排重叠';
}
