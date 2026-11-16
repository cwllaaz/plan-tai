import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';

void main() {
  group('LocalDate 构造与解析', () {
    test('合法性校验拒绝不存在的日期', () {
      expect(
        () => LocalDate(2026, 2, 30),
        throwsA(isA<PlannerValidationException>()),
      );
      expect(
        () => LocalDate(2026, 13, 1),
        throwsA(isA<PlannerValidationException>()),
      );
      expect(
        () => LocalDate(0, 1, 1),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('parse 只接受严格的 YYYY-MM-DD', () {
      expect(LocalDate.parse('2026-11-14'), LocalDate(2026, 11, 14));
      for (final bad in <String>[
        '2026-11-4',
        '2026/11/14',
        '26-11-14',
        '2026-11-14T00:00',
        '',
      ]) {
        expect(
          () => LocalDate.parse(bad),
          throwsA(isA<PlannerValidationException>()),
          reason: bad,
        );
      }
      expect(LocalDate.tryParse('2026-02-30'), isNull);
    });

    test('iso 输出补零', () {
      expect(LocalDate(2026, 1, 5).iso, '2026-01-05');
      expect(LocalDate(2026, 1, 5).toString(), '2026-01-05');
    });
  });

  group('LocalDate 运算', () {
    test('addDays 跨月跨年', () {
      expect(LocalDate(2026, 12, 31).addDays(1), LocalDate(2027, 1, 1));
      expect(LocalDate(2026, 3, 1).addDays(-1), LocalDate(2026, 2, 28));
      expect(LocalDate(2028, 3, 1).addDays(-1), LocalDate(2028, 2, 29));
    });

    test('addMonths 收敛到月末', () {
      expect(LocalDate(2026, 1, 31).addMonths(1), LocalDate(2026, 2, 28));
      expect(LocalDate(2028, 1, 31).addMonths(1), LocalDate(2028, 2, 29));
      expect(LocalDate(2026, 11, 14).addMonths(-11), LocalDate(2025, 12, 14));
      expect(LocalDate(2026, 1, 1).addMonths(-1), LocalDate(2025, 12, 1));
    });

    test('differenceInDays 不受夏令时影响', () {
      // 美国 2026-03-08 有夏令时切换；日历天数差仍必须是 1。
      expect(LocalDate(2026, 3, 9).differenceInDays(LocalDate(2026, 3, 8)), 1);
      expect(
        LocalDate(2026, 11, 14).differenceInDays(LocalDate(2026, 11, 1)),
        13,
      );
    });

    test('星期与周起始', () {
      final d = LocalDate(2026, 11, 14);
      expect(d.isoWeekday, 6); // 周六
      expect(d.isWeekend, isTrue);
      expect(d.startOfWeek(), LocalDate(2026, 11, 9)); // 周一
      expect(d.endOfWeek(), LocalDate(2026, 11, 15)); // 周日
      expect(d.startOfWeek(weekStart: 7), LocalDate(2026, 11, 8)); // 周日起
      expect(d.endOfWeek(weekStart: 7), LocalDate(2026, 11, 14));
      expect(
        () => d.startOfWeek(weekStart: 0),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('月份边界', () {
      expect(LocalDate(2026, 2, 10).daysInMonth, 28);
      expect(LocalDate(2028, 2, 10).daysInMonth, 29);
      expect(LocalDate(2026, 11, 14).firstDayOfMonth, LocalDate(2026, 11, 1));
      expect(LocalDate(2026, 11, 14).lastDayOfMonth, LocalDate(2026, 11, 30));
    });

    test('比较、相等与包含判断', () {
      final a = LocalDate(2026, 11, 14);
      final b = LocalDate(2026, 11, 15);
      expect(a.isBefore(b), isTrue);
      expect(b.isAfter(a), isTrue);
      expect(a.compareTo(a), 0);
      expect(a == LocalDate(2026, 11, 14), isTrue);
      expect(a.hashCode, LocalDate(2026, 11, 14).hashCode);
      expect(
        a.isWithin(LocalDate(2026, 11, 1), LocalDate(2026, 11, 30)),
        isTrue,
      );
      expect(a.isWithin(a, a), isTrue);
      expect(a.isSameMonthAs(b), isTrue);
      expect(a.isSameMonthAs(LocalDate(2026, 12, 1)), isFalse);
    });
  });

  group('LocalDateRange', () {
    test('闭区间包含首尾，长度正确', () {
      final range = LocalDateRange(
        LocalDate(2026, 11, 3),
        LocalDate(2026, 11, 7),
      );
      expect(range.lengthInDays, 5);
      expect(range.contains(LocalDate(2026, 11, 3)), isTrue);
      expect(range.contains(LocalDate(2026, 11, 7)), isTrue);
      expect(range.contains(LocalDate(2026, 11, 8)), isFalse);
      expect(range.days.length, 5);
      expect(range.days.last, LocalDate(2026, 11, 7));
    });

    test('结束日早于开始日直接拒绝', () {
      expect(
        () => LocalDateRange(LocalDate(2026, 11, 7), LocalDate(2026, 11, 3)),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('重叠判断用闭区间，接触即重叠', () {
      final a = LocalDateRange(LocalDate(2026, 11, 1), LocalDate(2026, 11, 5));
      final b = LocalDateRange(LocalDate(2026, 11, 5), LocalDate(2026, 11, 9));
      final c = LocalDateRange(LocalDate(2026, 11, 6), LocalDate(2026, 11, 9));
      expect(a.overlaps(b), isTrue);
      expect(a.overlaps(c), isFalse);
    });

    test('clamp 裁出交集', () {
      final month = LocalDateRange(
        LocalDate(2026, 11, 1),
        LocalDate(2026, 11, 30),
      );
      final span = LocalDateRange(
        LocalDate(2026, 10, 28),
        LocalDate(2026, 11, 3),
      );
      final clamped = span.clamp(month);
      expect(clamped.start, LocalDate(2026, 11, 1));
      expect(clamped.end, LocalDate(2026, 11, 3));
    });

    test('weekOf / monthOf 便捷构造', () {
      expect(
        LocalDateRange.weekOf(LocalDate(2026, 11, 14)),
        LocalDateRange(LocalDate(2026, 11, 9), LocalDate(2026, 11, 15)),
      );
      expect(
        LocalDateRange.monthOf(LocalDate(2026, 2, 14)),
        LocalDateRange(LocalDate(2026, 2, 1), LocalDate(2026, 2, 28)),
      );
    });
  });
}
