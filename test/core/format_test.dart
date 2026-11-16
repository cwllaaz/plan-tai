import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/format/format.dart';
import 'package:jihuatai/core/models/models.dart';

void main() {
  final today = LocalDate(2026, 11, 14);

  test('月份与日期标题', () {
    expect(monthTitle(today), '2026年11月');
    expect(monthDay(today), '11月14日');
    expect(monthDayWithWeekday(today), '11月14日 周六');
    expect(weekdayShort(today), '周六');
    expect(weekdayLong(today), '星期六');
    expect(weekdayHeader(today), '六');
    expect(dayNumber(today), '14');
    expect(isoDate(today), '2026-11-14');
  });

  test('相对日期', () {
    expect(relativeDay(today, today), '今天');
    expect(relativeDay(today.addDays(1), today), '明天');
    expect(relativeDay(today.addDays(-1), today), '昨天');
    expect(relativeDay(today.addDays(7), today), '11月21日 周六');
    expect(relativeDay(today.addDays(-14), today), '10月31日 周六');
  });

  test('ISO 周数', () {
    expect(isoWeekNumber(LocalDate(2026, 1, 1)), 1);
    expect(isoWeekNumber(today), 46);
    expect(isoWeekNumber(LocalDate(2026, 1, 5)), 2);
    expect(isoWeekNumber(LocalDate(2024, 12, 30)), 1);
    expect(isoWeekNumber(LocalDate(2027, 1, 1)), 53);
    expect(weekNumberLabel(today), '第 46 周');
  });

  test('时间文案', () {
    expect(timeSlotLabel(null), '未定时间');
    expect(
      timeSlotLabel(TimeSlot.at(hour: 9, minute: 5, durationMinutes: 55)),
      '09:05–10:00',
    );
  });
}
