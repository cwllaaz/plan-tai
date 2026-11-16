import 'local_date.dart';
import 'planner_exception.dart';

/// 日期闭区间 `[start, end]`，首尾两天都包含。
///
/// 跨天阶段（[PlanSpan]）用的就是这套语义：`2026-11-03 ~ 2026-11-07` 是 5 天，
/// 不是 4 天。查询与重叠判断统一用闭区间，避免"结束日 = 下一条开始日"被误判。
final class LocalDateRange {
  LocalDateRange(this.start, this.end) {
    if (end.isBefore(start)) {
      throw PlannerValidationException('日期区间结束日 ${end.iso} 早于开始日 ${start.iso}');
    }
  }

  /// 单日区间。
  factory LocalDateRange.singleDay(LocalDate date) =>
      LocalDateRange(date, date);

  factory LocalDateRange.monthOf(LocalDate date) =>
      LocalDateRange(date.firstDayOfMonth, date.lastDayOfMonth);

  factory LocalDateRange.weekOf(LocalDate date, {int weekStart = 1}) =>
      LocalDateRange(
        date.startOfWeek(weekStart: weekStart),
        date.endOfWeek(weekStart: weekStart),
      );

  final LocalDate start;
  final LocalDate end;

  /// 包含首尾的天数。
  int get lengthInDays => end.differenceInDays(start) + 1;

  bool contains(LocalDate date) => date.isWithin(start, end);

  /// 闭区间重叠：任何一天有交集即算重叠。
  bool overlaps(LocalDateRange other) =>
      !other.start.isAfter(end) && !other.end.isBefore(start);

  /// 从 [start] 到 [end] 的每一天（含首尾）。
  Iterable<LocalDate> get days sync* {
    for (var cursor = start; !cursor.isAfter(end); cursor = cursor.addDays(1)) {
      yield cursor;
    }
  }

  /// 裁掉区间两端之外的部分，用于跨周/跨月分段渲染。
  LocalDateRange clamp(LocalDateRange bounds) {
    final clampedStart = start.isBefore(bounds.start) ? bounds.start : start;
    final clampedEnd = end.isAfter(bounds.end) ? bounds.end : end;
    if (clampedEnd.isBefore(clampedStart)) {
      throw const PlannerValidationException('区间与裁剪范围没有交集');
    }
    return LocalDateRange(clampedStart, clampedEnd);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalDateRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '${start.iso}~${end.iso}';
}
