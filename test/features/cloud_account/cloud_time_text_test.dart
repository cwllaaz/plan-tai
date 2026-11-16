import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/features/cloud_account/util/cloud_time_text.dart';

void main() {
  final now = DateTime(2026, 11, 15, 14, 0);

  group('同步时间文案', () {
    test('未同步过', () {
      expect(formatSyncTime(null, now: now), '还没有成功同步过');
    });

    test('一分钟内显示刚刚', () {
      expect(
        formatSyncTime(now.subtract(const Duration(seconds: 20)), now: now),
        '刚刚',
      );
    });

    test('一小时内显示 N 分钟前', () {
      expect(
        formatSyncTime(now.subtract(const Duration(minutes: 8)), now: now),
        '8 分钟前',
      );
    });

    test('今天更早的时间显示钟点', () {
      expect(
        formatSyncTime(DateTime(2026, 11, 15, 11, 5), now: now),
        '今天 11:05',
      );
    });

    test('昨天显示昨天', () {
      expect(
        formatSyncTime(DateTime(2026, 11, 14, 9, 12), now: now),
        '昨天 09:12',
      );
    });

    test('更早显示月日', () {
      expect(
        formatSyncTime(DateTime(2026, 10, 14, 9, 12), now: now),
        '10月14日 09:12',
      );
    });

    test('跨年显示年份', () {
      expect(
        formatSyncTime(DateTime(2025, 12, 1, 9, 12), now: now),
        '2025年12月1日 09:12',
      );
    });

    test('绝对时间', () {
      expect(
        formatSyncTimeAbsolute(DateTime(2026, 11, 15, 9, 5)),
        '2026年11月15日 09:05',
      );
      expect(formatSyncTimeAbsolute(null), '从未同步');
    });
  });
}
