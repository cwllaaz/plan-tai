import 'planner_exception.dart';
import 'validation.dart';

/// 一天之内的任务时间区间，用「当天第几分钟 + 持续分钟」表示。
///
/// 为什么不用 `DateTime`：任务的"09:00"是**墙上的钟**，不是时间戳。
/// 存成时间戳会引入时区换算，23:59 变成 15:59 这类问题在月历上会直接错位。
/// 这里也不允许跨午夜——跨天的安排应该用 [PlanSpan] 表达。
final class TimeSlot {
  TimeSlot({required this.startMinute, this.durationMinutes = 30}) {
    requireInRange(startMinute, field: '开始分钟', min: 0, max: 1439);
    requireInRange(durationMinutes, field: '持续分钟', min: 1, max: 1440);
    if (startMinute + durationMinutes > 1440) {
      throw const PlannerValidationException('任务不能跨越午夜，请改用跨天阶段表达');
    }
  }

  /// 以「时:分」创建，便于界面代码书写。
  factory TimeSlot.at({
    required int hour,
    int minute = 0,
    int durationMinutes = 30,
  }) {
    requireInRange(hour, field: '小时', min: 0, max: 23);
    requireInRange(minute, field: '分钟', min: 0, max: 59);
    return TimeSlot(
      startMinute: hour * 60 + minute,
      durationMinutes: durationMinutes,
    );
  }

  /// 以开始/结束分钟创建；结束分钟是开区间边界，`1440` 表示次日 00:00。
  factory TimeSlot.startEnd({
    required int startMinute,
    required int endMinute,
  }) {
    requireInRange(startMinute, field: '开始分钟', min: 0, max: 1439);
    requireInRange(endMinute, field: '结束分钟', min: 1, max: 1440);
    if (endMinute <= startMinute) {
      throw const PlannerValidationException('结束时间必须晚于开始时间');
    }
    return TimeSlot(
      startMinute: startMinute,
      durationMinutes: endMinute - startMinute,
    );
  }

  /// 当天第几分钟（0 = 00:00，1439 = 23:59）。
  final int startMinute;

  /// 持续分钟数（1–1440），且 `startMinute + durationMinutes <= 1440`。
  final int durationMinutes;

  /// 当天第几分钟结束（开区间，1439 + 1 = 1440 即次日 00:00）。
  int get endMinute => startMinute + durationMinutes;

  int get startHour => startMinute ~/ 60;

  int get startMinuteOfHour => startMinute % 60;

  int get endHour => endMinute ~/ 60;

  int get endMinuteOfHour => endMinute % 60;

  String get startLabel =>
      '${startHour.toString().padLeft(2, '0')}:${startMinuteOfHour.toString().padLeft(2, '0')}';

  String get endLabel =>
      '${endHour.toString().padLeft(2, '0')}:${endMinuteOfHour.toString().padLeft(2, '0')}';

  /// 形如 `09:00–10:30`，用于抽屉里的时间列。
  String get label => '$startLabel–$endLabel';

  /// 半开区间重叠判断：相邻（10:00 结束、10:00 开始）不算重叠。
  bool overlaps(TimeSlot other) =>
      startMinute < other.endMinute && other.startMinute < endMinute;

  TimeSlot copyWith({int? startMinute, int? durationMinutes}) => TimeSlot(
    startMinute: startMinute ?? this.startMinute,
    durationMinutes: durationMinutes ?? this.durationMinutes,
  );

  @override
  bool operator ==(Object other) =>
      other is TimeSlot &&
      startMinute == other.startMinute &&
      durationMinutes == other.durationMinutes;

  @override
  int get hashCode => Object.hash(startMinute, durationMinutes);

  @override
  String toString() => 'TimeSlot($label)';
}
