import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/features/calendar/month_layout.dart';

/// 一段跨天阶段的测试替身（走真实模型，保证与生产逻辑一致）。
PlanSpan span(
  String id,
  LocalDate start,
  LocalDate end, {
  String projectId = 'p1',
  String title = '阶段',
  int sortOrder = 0,
  PlanSpanStatus status = PlanSpanStatus.planned,
}) {
  final created = DateTime.utc(2026, 1, 1);
  return PlanSpan(
    id: id,
    createdAt: created,
    updatedAt: created,
    revision: 1,
    projectId: projectId,
    title: title,
    startDate: start,
    endDate: end,
    sortOrder: sortOrder,
    status: status,
  );
}

PlannerTask task(String id, LocalDate date, {String title = '任务'}) {
  final created = DateTime.utc(2026, 1, 1);
  return PlannerTask(
    id: id,
    createdAt: created,
    updatedAt: created,
    revision: 1,
    title: title,
    scheduledDate: date,
  );
}

void main() {
  group('MonthGrid（整周网格）', () {
    test('2026 年 11 月：周日起始为 5 周，1 号正好是周日', () {
      final grid = MonthGrid.of(LocalDate(2026, 11, 14));

      expect(grid.weekCount, 5);
      expect(grid.gridStart, LocalDate(2026, 11, 1));
      expect(grid.gridEnd, LocalDate(2026, 12, 5));
      expect(grid.leadingDays, 0);
      expect(grid.weeks.first.first.isoWeekday, DateTime.sunday);
      expect(grid.weeks.last.last.isoWeekday, DateTime.saturday);
    });

    test('2026 年 11 月：周一起始为 6 周，补齐到 10 月 26 日', () {
      final grid = MonthGrid.of(
        LocalDate(2026, 11, 14),
        weekStart: DateTime.monday,
      );

      expect(grid.weekCount, 6);
      expect(grid.gridStart, LocalDate(2026, 10, 26));
      expect(grid.gridEnd, LocalDate(2026, 12, 6));
      expect(grid.leadingDays, 6);
    });

    test('2026 年 12 月：周日起始从 11 月 29 日开始，跨年到 1 月 2 日', () {
      final grid = MonthGrid.of(LocalDate(2026, 12, 1));

      expect(grid.gridStart, LocalDate(2026, 11, 29));
      expect(grid.gridEnd, LocalDate(2027, 1, 2));
      expect(grid.weekCount, 5);
    });

    test('闰年 2 月（2024）有 29 天，网格为 5 周并包含 2 月 29 日', () {
      final grid = MonthGrid.of(LocalDate(2024, 2, 1));

      expect(LocalDate(2024, 2, 1).daysInMonth, 29);
      expect(grid.weekCount, 5);
      expect(grid.gridStart, LocalDate(2024, 1, 28));
      expect(grid.gridEnd, LocalDate(2024, 3, 2));
      expect(grid.days.contains(LocalDate(2024, 2, 29)), isTrue);
    });

    test('平年 2 月（2023）有 28 天，网格为 5 周且不含 2 月 29 日', () {
      final grid = MonthGrid.of(LocalDate(2023, 2, 1));

      expect(grid.weekCount, 5);
      expect(grid.gridStart, LocalDate(2023, 1, 29));
      expect(grid.gridEnd, LocalDate(2023, 3, 4));
      expect(
        grid.days.where((day) => day.month == 2 && day.day == 29),
        isEmpty,
      );
    });

    test('跨年月份（2027 年 1 月）补齐 12 月末与 2 月初', () {
      final grid = MonthGrid.of(LocalDate(2027, 1, 31));

      expect(grid.weekCount, 6);
      expect(grid.gridStart, LocalDate(2026, 12, 27));
      expect(grid.gridEnd, LocalDate(2027, 2, 6));
    });

    test('"刚好四周"的月份（2026 年 2 月）补到 5 行，节奏稳定', () {
      final grid = MonthGrid.of(LocalDate(2026, 2, 1));

      // 2026-02-01 是周日、2 月 28 日是周六：不足 5 行时向后补一整周。
      expect(grid.weekCount, 5);
      expect(grid.gridStart, LocalDate(2026, 2, 1));
      expect(grid.gridEnd, LocalDate(2026, 3, 7));
    });

    test('任意月份：网格天数 = 7 × 周数，且每月首尾都在网格里', () {
      for (var month = 1; month <= 12; month++) {
        for (final year in <int>[2023, 2024, 2025, 2026, 2027]) {
          final first = LocalDate(year, month, 1);
          final grid = MonthGrid.of(first);
          final last = first.lastDayOfMonth;

          expect(grid.weeks.length, inInclusiveRange(5, 6));
          expect(grid.days.length, grid.weekCount * 7);
          expect(grid.range.contains(first), isTrue);
          expect(grid.range.contains(last), isTrue);
          expect(grid.days.first.isoWeekday, kCalendarWeekStart);
          expect(grid.days.last.isoWeekday, (kCalendarWeekStart + 5) % 7 + 1);
        }
      }
    });

    test('columnOf / leadingDays 与网格一致', () {
      final grid = MonthGrid.of(LocalDate(2026, 11, 1));

      expect(grid.columnOf(LocalDate(2026, 11, 1)), 0);
      expect(grid.columnOf(LocalDate(2026, 11, 7)), 6);
      expect(grid.columnOf(LocalDate(2026, 11, 8)), 0);
      expect(grid.columnOf(LocalDate(2026, 10, 1)), -1);
      expect(grid.columnOf(LocalDate(2027, 1, 1)), -1);
    });

    test('weekStart 非法时抛校验异常', () {
      expect(
        () => MonthGrid.of(LocalDate(2026, 11, 1), weekStart: 0),
        throwsA(isA<PlannerValidationException>()),
      );
    });
  });

  group('layoutWeekSpans（跨天条分段与车道）', () {
    final weekStart = LocalDate(2026, 11, 1);

    test('单周内的阶段：一条车道、包含真实首尾', () {
      final layout = layoutWeekSpans(<PlanSpan>[
        span('a', LocalDate(2026, 11, 3), LocalDate(2026, 11, 7)),
      ], weekStart);

      expect(layout.visible, hasLength(1));
      expect(layout.laneCount, 1);
      expect(layout.hiddenCount, 0);

      final segment = layout.visible.single;
      expect(segment.startColumn, 2);
      expect(segment.endColumn, 6);
      expect(segment.columnCount, 5);
      expect(segment.beginsHere, isTrue);
      expect(segment.endsHere, isTrue);
      expect(segment.continuesBefore, isFalse);
      expect(segment.continuesAfter, isFalse);
    });

    test('跨周阶段：本周末端直角并标记"还会继续"', () {
      final layout = layoutWeekSpans(<PlanSpan>[
        span('a', LocalDate(2026, 11, 3), LocalDate(2026, 11, 20)),
      ], weekStart);

      final segment = layout.visible.single;
      expect(segment.startColumn, 2);
      expect(segment.endColumn, 6);
      expect(segment.beginsHere, isTrue);
      expect(segment.endsHere, isFalse);
      expect(segment.continuesAfter, isTrue);
    });

    test('跨周阶段：下一周首端直角，且不重复绘图到本周之外', () {
      final nextWeek = weekStart.addDays(7);
      final layout = layoutWeekSpans(<PlanSpan>[
        span('a', LocalDate(2026, 11, 3), LocalDate(2026, 11, 20)),
      ], nextWeek);

      final segment = layout.visible.single;
      expect(segment.weekStart, nextWeek);
      expect(segment.startColumn, 0);
      expect(segment.endColumn, 6);
      expect(segment.beginsHere, isFalse);
      expect(segment.continuesBefore, isTrue);
      expect(segment.continuesAfter, isTrue);
    });

    test('跨月阶段：进入本月的第一周只保留本月内的部分', () {
      final layout = layoutWeekSpans(<PlanSpan>[
        span('a', LocalDate(2026, 10, 28), LocalDate(2026, 11, 2)),
      ], weekStart);

      final segment = layout.visible.single;
      expect(segment.startColumn, 0);
      expect(segment.endColumn, 1);
      expect(segment.continuesBefore, isTrue);
      expect(segment.continuesAfter, isFalse);
      expect(segment.beginsHere, isFalse);
      expect(segment.endsHere, isTrue);
    });

    test('完全不在本周的阶段被忽略', () {
      final layout = layoutWeekSpans(<PlanSpan>[
        span('a', LocalDate(2026, 11, 20), LocalDate(2026, 11, 22)),
      ], weekStart);

      expect(layout.isEmpty, isTrue);
      expect(layout.laneCount, 0);
      expect(layout.laneSegments(0), isEmpty);
    });

    test('重叠的阶段换到下一车道，不重叠的可以回到第一条车道', () {
      final layout = layoutWeekSpans(<PlanSpan>[
        span('a', LocalDate(2026, 11, 3), LocalDate(2026, 11, 5)),
        span('b', LocalDate(2026, 11, 4), LocalDate(2026, 11, 6)),
        span('c', LocalDate(2026, 11, 6), LocalDate(2026, 11, 7)),
      ], weekStart);

      expect(layout.laneCount, 2);
      expect(layout.hiddenCount, 0);
      expect(layout.visible, hasLength(3));

      final byId = <String, SpanSegment>{
        for (final segment in layout.visible) segment.span.id: segment,
      };
      expect(byId['a']!.lane, 0);
      expect(byId['b']!.lane, 1);
      // a 在 5 号结束，c 从 6 号开始，可以回到第一条车道。
      expect(byId['c']!.lane, 0);
    });

    test('超过最大车道的阶段折叠进 hidden，并保持车道数上限', () {
      final layout = layoutWeekSpans(
        <PlanSpan>[
          span('a', LocalDate(2026, 11, 2), LocalDate(2026, 11, 6)),
          span('b', LocalDate(2026, 11, 3), LocalDate(2026, 11, 7)),
          span('c', LocalDate(2026, 11, 4), LocalDate(2026, 11, 5)),
        ],
        weekStart,
        maxLanes: 2,
      );

      expect(layout.visible, hasLength(2));
      expect(layout.hiddenCount, 1);
      expect(layout.hidden.single.id, 'c');
      expect(layout.laneCount, 2);
      expect(layout.visible.every((segment) => segment.lane < 2), isTrue);
    });

    test('长条优先占上车道，渲染顺序稳定', () {
      final layout = layoutWeekSpans(<PlanSpan>[
        span('short', LocalDate(2026, 11, 5), LocalDate(2026, 11, 5)),
        span('long', LocalDate(2026, 11, 2), LocalDate(2026, 11, 7)),
      ], weekStart);

      expect(layout.visible.first.span.id, 'long');
      expect(layout.visible.first.lane, 0);
      expect(layout.visible.last.span.id, 'short');
      expect(layout.visible.last.lane, 1);
    });
  });

  group('layoutMonthSpans（整月按周切分）', () {
    test('一条跨三周多的阶段被切成 3 段，首段有真实起点、末段有真实终点', () {
      final month = LocalDate(2026, 11, 1);
      final grid = MonthGrid.of(month);
      final layouts = layoutMonthSpans(<PlanSpan>[
        span('a', LocalDate(2026, 11, 3), LocalDate(2026, 11, 20)),
      ], grid);

      final segments = <SpanSegment>[
        for (final layout in layouts.values) ...layout.visible,
      ];
      expect(segments, hasLength(3));
      expect(segments.first.startColumn, 2);
      expect(segments.first.beginsHere, isTrue);
      expect(segments[1].beginsHere, isFalse);
      expect(segments[1].endsHere, isFalse);
      expect(segments.last.endsHere, isTrue);
      // 11 月 20 日是周五 → 最后一列的前一列。
      expect(segments.last.endColumn, 5);
    });

    test('跨月的阶段在相邻两个月的网格里各自出现（网格会重叠两周）', () {
      final november = MonthGrid.of(LocalDate(2026, 11, 1));
      final december = MonthGrid.of(LocalDate(2026, 12, 1));
      final crossing = span(
        'a',
        LocalDate(2026, 11, 27),
        LocalDate(2026, 12, 4),
      );

      final nov = layoutMonthSpans(<PlanSpan>[crossing], november);
      final dec = layoutMonthSpans(<PlanSpan>[crossing], december);

      // 12 月的网格从 11 月 29 日开始，所以两个月都能看到这条阶段。
      expect(nov.values.expand((l) => l.visible), isNotEmpty);
      expect(dec.values.expand((l) => l.visible), isNotEmpty);
      expect(dec.values.expand((l) => l.visible).first.continuesBefore, isTrue);
      // 11 月网格延伸到 12 月 5 日，阶段在网格内结束 → 本段有真实终点。
      expect(nov.values.expand((l) => l.visible).last.endsHere, isTrue);
    });
  });

  group('任务分组与折叠', () {
    test('按日期分组，未排期任务不进入月历', () {
      final day = LocalDate(2026, 11, 3);
      final grouped = groupTasksByDate(<PlannerTask>[
        task('a', day),
        task('b', day),
        task('c', LocalDate(2026, 11, 4)),
        PlannerTask(
          id: 'inbox',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          revision: 1,
          title: '收件箱任务',
        ),
      ]);

      expect(grouped[day], hasLength(2));
      expect(grouped[LocalDate(2026, 11, 4)], hasLength(1));
      expect(grouped.length, 2);
    });

    test('超过 3 条时折叠为 +N 项，并给折叠行留出高度', () {
      final day = LocalDate(2026, 11, 3);
      final tasks = <PlannerTask>[
        for (var i = 0; i < 12; i++) task('t$i', day, title: '任务 $i'),
      ];

      final layout = layoutDayTasks(
        tasks,
        maxTasks: 3,
        availableHeight: 80,
        taskRowHeight: 17,
        overflowRowHeight: 13,
      );

      expect(layout.visible, hasLength(3));
      expect(layout.hiddenCount, 9);
      expect(layout.all, hasLength(12));
    });

    test('高度不足时宁可少放，也要保证 +N 项 不撑破格子', () {
      final day = LocalDate(2026, 11, 3);
      final tasks = <PlannerTask>[for (var i = 0; i < 2; i++) task('t$i', day)];

      final layout = layoutDayTasks(
        tasks,
        maxTasks: 3,
        // 只够 1 行任务：17，再加折叠行的 13 就放不下，所以一条都不画。
        availableHeight: 20,
        taskRowHeight: 17,
        overflowRowHeight: 13,
      );

      expect(layout.visible, isEmpty);
      expect(layout.hiddenCount, 2);
    });

    test('空任务列表不会产生折叠行', () {
      final layout = layoutDayTasks(
        const <PlannerTask>[],
        maxTasks: 3,
        availableHeight: 80,
        taskRowHeight: 17,
        overflowRowHeight: 13,
      );

      expect(layout.isEmpty, isTrue);
      expect(layout.hiddenCount, 0);
    });
  });
}
