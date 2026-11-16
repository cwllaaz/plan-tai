import '../../core/models/models.dart';

/// 月历每周从哪一天开始（ISO 星期：1 = 周一 … 7 = 周日）。
///
/// 月历模块 工单要求"周日到周六"的七列，因此这里取周日起始。
/// 《PRODUCT_SPEC》与《MODULE_API》写的是"周一开头"，两者冲突已上报维护者；
/// 若最终确认改回周一，只改这一个常量即可 —— 所有布局函数都接受 [weekStart] 参数，
/// 测试同时覆盖周日起始与周一起始两种排布。
const int kCalendarWeekStart = DateTime.sunday;

/// 一个月的整周网格：`6 × 7` 或 `5 × 7` 个日期，首尾补齐相邻月。
///
/// 纯数据 + 纯函数，不依赖 Flutter，可被单测直接覆盖。
final class MonthGrid {
  const MonthGrid._({
    required this.month,
    required this.weekStart,
    required this.gridStart,
    required this.gridEnd,
    required this.weeks,
  });

  /// 以 [month] 所在月份铺网格；[month] 只需是该月任意一天。
  ///
  /// [minWeeks] 用来避免"刚好四周"的月份（如 2026 年 2 月）比别的月份矮一截：
  /// 不足时向后补齐整周，保持 5–6 行的稳定节奏。
  factory MonthGrid.of(
    LocalDate month, {
    int weekStart = kCalendarWeekStart,
    int minWeeks = 5,
  }) {
    requireValidWeekStart(weekStart);
    final gridStart = month.firstDayOfMonth.startOfWeek(weekStart: weekStart);
    var gridEnd = month.lastDayOfMonth.endOfWeek(weekStart: weekStart);
    var totalDays = gridEnd.differenceInDays(gridStart) + 1;
    if (totalDays < minWeeks * 7) {
      totalDays = minWeeks * 7;
      gridEnd = gridStart.addDays(totalDays - 1);
    }
    final weeks = <List<LocalDate>>[
      for (var offset = 0; offset < totalDays; offset += 7)
        <LocalDate>[
          for (var column = 0; column < 7; column++)
            gridStart.addDays(offset + column),
        ],
    ];
    return MonthGrid._(
      month: month,
      weekStart: weekStart,
      gridStart: gridStart,
      gridEnd: gridEnd,
      weeks: List<List<LocalDate>>.unmodifiable(
        weeks.map(List<LocalDate>.unmodifiable),
      ),
    );
  }

  /// 可见月份（原样保存，不修改调用方传入的值）。
  final LocalDate month;

  /// 每周起始日的 ISO 星期值。
  final int weekStart;

  /// 网格第一格（首周首日）。
  final LocalDate gridStart;

  /// 网格最后一格（末周末日）。
  final LocalDate gridEnd;

  /// 按周分组的全部网格日期。
  final List<List<LocalDate>> weeks;

  int get weekCount => weeks.length;

  /// 网格覆盖的数据范围，直接交给 `watchTasksInRange` / `watchSpansInRange`。
  LocalDateRange get range => LocalDateRange(gridStart, gridEnd);

  /// 网格内的全部日期，按行优先展开。
  Iterable<LocalDate> get days => weeks.expand((week) => week);

  /// 本月第一天在网格里的第几列（0 起）。
  int get leadingDays => month.firstDayOfMonth.differenceInDays(gridStart);

  /// [date] 在所在周的列号（0 起）；不在网格内时返回 -1。
  int columnOf(LocalDate date) {
    if (date.isBefore(gridStart) || date.isAfter(gridEnd)) return -1;
    return date.differenceInDays(gridStart) % 7;
  }
}

/// 跨天阶段在**某一周内**的可见片段。
///
/// 跨周、跨月时按周切成多段：只有真实起点的段有左圆角，只有真实终点的段有右圆角，
/// 中间段两侧都是直角并紧贴格子边界，视觉上与其他段连成一条。
final class SpanSegment {
  const SpanSegment({
    required this.span,
    required this.weekStart,
    required this.start,
    required this.end,
    required this.lane,
  });

  /// 原始阶段（标题、项目、状态都从这里取）。
  final PlanSpan span;

  /// 所属周的起始日。
  final LocalDate weekStart;

  /// 裁剪到本周后的起始日。
  final LocalDate start;

  /// 裁剪到本周后的结束日。
  final LocalDate end;

  /// 车道号（0 为最上一行）。
  final int lane;

  int get startColumn => start.differenceInDays(weekStart);

  int get endColumn => end.differenceInDays(weekStart);

  /// 本段占用的格子数（≥ 1）。
  int get columnCount => endColumn - startColumn + 1;

  /// 真实起点在更早的周（或更早的月份）。
  bool get continuesBefore => span.startDate.isBefore(weekStart);

  /// 真实终点在更晚的周（或更晚的月份）。
  bool get continuesAfter => span.endDate.isAfter(weekStart.addDays(6));

  /// 是否包含阶段的真实起点。
  bool get beginsHere => !continuesBefore;

  /// 是否包含阶段的真实终点。
  bool get endsHere => !continuesAfter;

  @override
  String toString() =>
      'SpanSegment(${span.title}, ${start.iso}~${end.iso}, lane=$lane)';
}

/// 某一周里的跨天条排布结果。
final class WeekSpanLayout {
  const WeekSpanLayout({
    required this.weekStart,
    required this.visible,
    required this.hidden,
    required this.laneCount,
  });

  /// 空排布（该周没有任何阶段）。
  factory WeekSpanLayout.empty(LocalDate weekStart) => WeekSpanLayout(
    weekStart: weekStart,
    visible: const <SpanSegment>[],
    hidden: const <PlanSpan>[],
    laneCount: 0,
  );

  final LocalDate weekStart;

  /// 真正画出来的段（车道号 < 可见车道数）。
  final List<SpanSegment> visible;

  /// 车道放不下、被折叠成 `+N 条安排` 的阶段。
  final List<PlanSpan> hidden;

  /// 本周实际使用的可见车道数（0–2）。
  final int laneCount;

  bool get isEmpty => visible.isEmpty && hidden.isEmpty;

  int get hiddenCount => hidden.length;

  /// 取某条车道上的段，按列号升序。
  List<SpanSegment> laneSegments(int lane) => <SpanSegment>[
    for (final segment in visible)
      if (segment.lane == lane) segment,
  ];
}

/// 把一个月的跨天阶段按周切开并分配车道。
Map<LocalDate, WeekSpanLayout> layoutMonthSpans(
  Iterable<PlanSpan> spans,
  MonthGrid grid, {
  int maxLanes = 2,
}) {
  final list = spans.toList(growable: false);
  return <LocalDate, WeekSpanLayout>{
    for (final week in grid.weeks)
      week.first: layoutWeekSpans(list, week.first, maxLanes: maxLanes),
  };
}

/// 计算某一周的跨天条车道。
///
/// 规则：
/// 1. 只保留与本周（闭区间）有交集的阶段，并裁剪到本周；
/// 2. 排序：开始早的在上、更长的在上、其次按 `sortOrder` 与 `id`，保证同一份数据渲染稳定；
/// 3. 贪心装箱：放进第一条"上一段已经结束"的车道，放不下就新开一条；
/// 4. 超过 [maxLanes] 的车道折叠进 [WeekSpanLayout.hidden]，由格子显示 `+N 条安排`。
WeekSpanLayout layoutWeekSpans(
  Iterable<PlanSpan> spans,
  LocalDate weekStart, {
  int maxLanes = 2,
}) {
  final weekEnd = weekStart.addDays(6);
  final weekRange = LocalDateRange(weekStart, weekEnd);

  final clipped = <({PlanSpan span, LocalDate start, LocalDate end})>[];
  for (final span in spans) {
    if (!span.overlaps(weekRange)) continue;
    clipped.add((
      span: span,
      start: span.startDate.isBefore(weekStart) ? weekStart : span.startDate,
      end: span.endDate.isAfter(weekEnd) ? weekEnd : span.endDate,
    ));
  }

  clipped.sort((
    ({PlanSpan span, LocalDate start, LocalDate end}) a,
    ({PlanSpan span, LocalDate start, LocalDate end}) b,
  ) {
    final byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    final byLength = b.end
        .differenceInDays(b.start)
        .compareTo(a.end.differenceInDays(a.start));
    if (byLength != 0) return byLength;
    final byOrder = a.span.sortOrder.compareTo(b.span.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.span.id.compareTo(b.span.id);
  });

  final laneLastColumn = <int>[];
  final visible = <SpanSegment>[];
  final hidden = <PlanSpan>[];

  for (final item in clipped) {
    final startColumn = item.start.differenceInDays(weekStart);
    final endColumn = item.end.differenceInDays(weekStart);

    var lane = 0;
    while (lane < laneLastColumn.length &&
        laneLastColumn[lane] >= startColumn) {
      lane++;
    }
    if (lane == laneLastColumn.length) {
      laneLastColumn.add(endColumn);
    } else {
      laneLastColumn[lane] = endColumn;
    }

    if (lane < maxLanes) {
      visible.add(
        SpanSegment(
          span: item.span,
          weekStart: weekStart,
          start: item.start,
          end: item.end,
          lane: lane,
        ),
      );
    } else {
      hidden.add(item.span);
    }
  }

  if (clipped.isEmpty) return WeekSpanLayout.empty(weekStart);

  return WeekSpanLayout(
    weekStart: weekStart,
    visible: List<SpanSegment>.unmodifiable(visible),
    hidden: List<PlanSpan>.unmodifiable(hidden),
    laneCount: laneLastColumn.length < maxLanes
        ? laneLastColumn.length
        : maxLanes,
  );
}

/// 按日期分组当日任务；未排期任务被忽略（月历不显示收件箱）。
///
/// 保持仓储给出的顺序（`scheduledDate` → 有时间的在前 → 开始时间 → 优先级 …），
/// 不在这里重新排序，避免与 DATA_CONTRACT §8 的排序规则打架。
Map<LocalDate, List<PlannerTask>> groupTasksByDate(
  Iterable<PlannerTask> tasks,
) {
  final byDate = <LocalDate, List<PlannerTask>>{};
  for (final task in tasks) {
    final day = task.scheduledDate;
    if (day == null) continue;
    final bucket = byDate[day];
    if (bucket == null) {
      byDate[day] = <PlannerTask>[task];
    } else {
      bucket.add(task);
    }
  }
  return byDate;
}

/// 项目 id → 项目，用于把任务/阶段映射到颜色与名称。
Map<String, Project> indexProjects(Iterable<Project> projects) =>
    <String, Project>{for (final project in projects) project.id: project};

/// 阶段颜色：阶段自带颜色优先，否则继承项目色，再退回默认蓝。
ProjectColor spanColorOf(PlanSpan span, Project? project) =>
    span.color ?? project?.color ?? ProjectColor.blue;

/// 任务颜色：无项目（收件箱）时返回 null，由界面决定用什么灰。
ProjectColor? taskColorOf(PlannerTask task, Map<String, Project> projects) {
  final projectId = task.projectId;
  if (projectId == null) return null;
  return projects[projectId]?.color;
}

/// 某一天的任务分组结果：`visible` 是要画出来的前 N 条，`hiddenCount` 是折叠的数量。
final class DayTaskLayout {
  const DayTaskLayout({
    required this.all,
    required this.visible,
    required this.hiddenCount,
  });

  /// 当天的全部任务（契约顺序）。
  final List<PlannerTask> all;

  /// 实际画进格子的任务。
  final List<PlannerTask> visible;

  /// 被折叠成 `+N 项` 的任务数量。
  final int hiddenCount;

  bool get isEmpty => all.isEmpty;
}

/// 按可用高度决定一个格子能放几条任务。
///
/// [availableHeight] 是日期行与跨天条车道之外剩下的高度；
/// 有折叠时必须预留一行 `+N 项`，否则宁可少画一条也不要撑破格子。
DayTaskLayout layoutDayTasks(
  List<PlannerTask> tasks, {
  required int maxTasks,
  required double availableHeight,
  required double taskRowHeight,
  required double overflowRowHeight,
}) {
  if (tasks.isEmpty) {
    return const DayTaskLayout(
      all: <PlannerTask>[],
      visible: <PlannerTask>[],
      hiddenCount: 0,
    );
  }

  final capacity = maxTasks.clamp(0, tasks.length);
  var fitByHeight = _fitCount(availableHeight, taskRowHeight, capacity);

  // 放不下全部任务时必须再让出一行给 `+N 项`，否则少算一行会把格子撑破。
  if (fitByHeight < tasks.length) {
    fitByHeight = _fitCount(
      availableHeight - overflowRowHeight,
      taskRowHeight,
      capacity,
    );
  }

  return DayTaskLayout(
    all: tasks,
    visible: List<PlannerTask>.unmodifiable(tasks.take(fitByHeight)),
    hiddenCount: tasks.length - fitByHeight,
  );
}

int _fitCount(double height, double rowHeight, int cap) {
  if (height <= 0 || rowHeight <= 0) return 0;
  final fit = (height / rowHeight).floor();
  return fit < cap ? fit : cap;
}
