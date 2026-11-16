import 'planner_exception.dart';

/// 纯日期（`YYYY-MM-DD`），**不含时区、不含时刻**。
///
/// 这是计划台里最重要的一个值对象：任务排在哪一天、阶段跨哪几天、每日备注属于
/// 哪一天，全部用它表达。绝对不要用 [DateTime] 或 UTC 时间戳表示"某一天"，
/// 否则跨时区时会出现"任务漂移一天"（见 docs/DATA_CONTRACT.md §1）。
///
/// 所有日期运算都基于 UTC 零点，因此不受夏令时影响。
final class LocalDate implements Comparable<LocalDate> {
  const LocalDate._(this.year, this.month, this.day);

  /// 构造并校验一个日历日期。
  factory LocalDate(int year, int month, int day) {
    if (year < 1 || year > 9999) {
      throw PlannerValidationException('年份超出支持范围：$year');
    }
    final probe = DateTime.utc(year, month, day);
    if (probe.year != year || probe.month != month || probe.day != day) {
      throw PlannerValidationException('无效日期：$year-$month-$day');
    }
    return LocalDate._(year, month, day);
  }

  /// 取 [dateTime] 的**本地**日历部分。跨时区数据不要走这里，先明确语义。
  factory LocalDate.fromDateTime(DateTime dateTime) =>
      LocalDate(dateTime.year, dateTime.month, dateTime.day);

  static final RegExp _isoPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// 严格解析 `YYYY-MM-DD`（不接受 `2026-3-5`、`2026/03/05`）。
  static LocalDate parse(String value) {
    final match = _isoPattern.firstMatch(value.trim());
    if (match == null) {
      throw PlannerValidationException('日期必须是 YYYY-MM-DD 格式：$value');
    }
    return LocalDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  static LocalDate? tryParse(String value) {
    try {
      return parse(value);
    } on PlannerValidationException {
      return null;
    }
  }

  /// 本机时区的"今天"。
  static LocalDate today([DateTime? now]) =>
      LocalDate.fromDateTime(now ?? DateTime.now());

  final int year;
  final int month;
  final int day;

  /// 规范化的 ISO 字符串 `YYYY-MM-DD`，可直接作为数据库字段。
  String get iso =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// 本地日历的零点 [DateTime]。仅用于 UI 绘制，不要持久化。
  DateTime get startOfDay => DateTime(year, month, day);

  /// UTC 零点，供日期运算使用。
  DateTime get _utcMidnight => DateTime.utc(year, month, day);

  /// ISO 8601 星期：1 = 周一 … 7 = 周日。
  int get isoWeekday => _utcMidnight.weekday;

  bool get isWeekend => isoWeekday >= 6;

  int get daysInMonth => DateTime.utc(year, month + 1, 0).day;

  LocalDate get firstDayOfMonth => LocalDate(year, month, 1);

  LocalDate get lastDayOfMonth => LocalDate(year, month, daysInMonth);

  /// 加/减天数，跨月跨年自动进位。
  LocalDate addDays(int days) {
    final shifted = _utcMidnight.add(Duration(days: days));
    return LocalDate._(shifted.year, shifted.month, shifted.day);
  }

  /// 加/减月份；目标月没有该日时收敛到月末（1 月 31 日 + 1 月 = 2 月 28/29 日）。
  LocalDate addMonths(int months) {
    final totalMonths = year * 12 + (month - 1) + months;
    final nextYear = totalMonths ~/ 12;
    final nextMonth = totalMonths % 12 + 1;
    if (nextYear < 1 || nextYear > 9999) {
      throw const PlannerValidationException('月份超出支持范围');
    }
    final last = DateTime.utc(nextYear, nextMonth + 1, 0).day;
    return LocalDate(nextYear, nextMonth, day <= last ? day : last);
  }

  /// [other] 与当前日期的整天差（当前 - other）。
  int differenceInDays(LocalDate other) =>
      _utcMidnight.difference(other._utcMidnight).inDays;

  /// 所在周的起始日。[weekStart] 用 ISO 星期表示（1 = 周一，7 = 周日）。
  LocalDate startOfWeek({int weekStart = 1}) {
    requireValidWeekStart(weekStart);
    final offset = (isoWeekday - weekStart) % 7;
    return addDays(-offset);
  }

  LocalDate endOfWeek({int weekStart = 1}) =>
      startOfWeek(weekStart: weekStart).addDays(6);

  bool isBefore(LocalDate other) => compareTo(other) < 0;

  bool isAfter(LocalDate other) => compareTo(other) > 0;

  bool isSameMonthAs(LocalDate other) =>
      year == other.year && month == other.month;

  /// 是否落在 [start, end] 闭区间内（首尾都算）。
  bool isWithin(LocalDate start, LocalDate end) =>
      !isBefore(start) && !isAfter(end);

  @override
  int compareTo(LocalDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}

/// 每周起始日只能是 ISO 星期 1–7。
void requireValidWeekStart(int weekStart) {
  if (weekStart < 1 || weekStart > 7) {
    throw const PlannerValidationException('每周起始日必须是 1–7（1 = 周一）');
  }
}
