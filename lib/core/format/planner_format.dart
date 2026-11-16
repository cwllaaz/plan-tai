import '../models/models.dart';

/// 全应用统一的日期/时间文案。所有模块都从这里取，避免各写一套导致不一致。
///
/// 纯 Dart 实现，可被单测直接覆盖（test/core/format_test.dart）。

const List<String> _weekdayShort = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];
const List<String> _weekdayLong = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];
const List<String> _weekdayHeader = <String>['一', '二', '三', '四', '五', '六', '日'];

/// `2026年11月`
String monthTitle(LocalDate date) => '${date.year}年${date.month}月';

/// `周一`
String weekdayShort(LocalDate date) => _weekdayShort[date.isoWeekday - 1];

/// `星期一`
String weekdayLong(LocalDate date) => _weekdayLong[date.isoWeekday - 1];

/// 月历表头的单字：`一`…`日`
String weekdayHeader(LocalDate date) => _weekdayHeader[date.isoWeekday - 1];

/// `11月14日`
String monthDay(LocalDate date) => '${date.month}月${date.day}日';

/// `11月14日 周五`
String monthDayWithWeekday(LocalDate date) =>
    '${monthDay(date)} ${weekdayShort(date)}';

/// `2026-11-14`
String isoDate(LocalDate date) => date.iso;

/// 相对日期：今天 / 明天 / 昨天 / 11月20日
String relativeDay(LocalDate date, LocalDate today) {
  final diff = date.differenceInDays(today);
  return switch (diff) {
    0 => '今天',
    1 => '明天',
    -1 => '昨天',
    _ => monthDayWithWeekday(date),
  };
}

/// ISO 8601 周数（周一为一周第一天，包含 1 月 4 日的那周是第 1 周）。
int isoWeekNumber(LocalDate date) {
  final thursday = date.addDays(4 - date.isoWeekday);
  final jan4 = LocalDate(thursday.year, 1, 4);
  final firstThursday = jan4.addDays(4 - jan4.isoWeekday);
  return thursday.differenceInDays(firstThursday) ~/ 7 + 1;
}

/// `第 46 周`
String weekNumberLabel(LocalDate date) => '第 ${isoWeekNumber(date)} 周';

/// 时间区间文案：`09:00–10:30`；无时刻时返回 `未定时间`。
String timeSlotLabel(TimeSlot? slot) => slot?.label ?? '未定时间';

/// 任务的时间文案；无时刻返回空串，方便直接拼接。
String taskTimeLabel(PlannerTask task) => task.timeSlot?.startLabel ?? '';

/// 日期在月历格子里显示的数字。
String dayNumber(LocalDate date) => '${date.day}';
