import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../../features/calendar/month_layout.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_month_cell.dart';

/// 移动端月历：七列网格 + 今天/选中高亮 + 跨天安排细横条 + 任务圆点与 `+N` 计数。
///
/// - `weekMode = false`：整月网格（5–6 行），填满给定高度；
/// - `weekMode = true`：只显示选中日期所在的一周（紧凑周历），高度按内容；
/// - 左右滑动 → [onSwipePeriod]（外壳决定换月还是换周）；上下滑动 → [onToggleMode]。
///
/// 数据只来自 [PlannerRepository] 的三条流（整月一次性订阅，不按天循环）。
class MobileMonthGrid extends StatefulWidget {
  const MobileMonthGrid({
    super.key,
    required this.repository,
    required this.month,
    required this.today,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDay,
    this.onOpenSpan,
    this.weekMode = false,
    this.onSwipePeriod,
    this.onToggleMode,
    this.showWeekdayHeader = true,
  });

  final PlannerRepository repository;

  /// 可见月份（约定为 1 号）。
  final LocalDate month;

  final LocalDate today;
  final LocalDate selectedDate;
  final ValueChanged<LocalDate> onSelectDate;
  final ValueChanged<LocalDate> onOpenDay;
  final ValueChanged<PlanSpan>? onOpenSpan;

  /// 是否紧凑周历（仅显示一周）。
  final bool weekMode;

  /// 左右滑动：+1 = 下一个周期，-1 = 上一个周期。
  final ValueChanged<int>? onSwipePeriod;

  /// 上下滑动切换展开月历 / 紧凑周历。
  final VoidCallback? onToggleMode;

  final bool showWeekdayHeader;

  @override
  State<MobileMonthGrid> createState() => _MobileMonthGridState();
}

class _MobileMonthGridState extends State<MobileMonthGrid> {
  late MonthGrid _grid;
  late Stream<List<PlannerTask>> _tasks;
  late Stream<List<PlanSpan>> _spans;
  late Stream<List<Project>> _projects;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant MobileMonthGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final monthChanged = !oldWidget.month.isSameMonthAs(widget.month);
    if (monthChanged || oldWidget.repository != widget.repository) {
      _bind();
    }
  }

  void _bind() {
    _grid = MonthGrid.of(widget.month);
    _tasks = widget.repository.watchTasksInRange(_grid.range);
    _spans = widget.repository.watchSpansInRange(_grid.range);
    _projects = widget.repository.watchProjects();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PlannerTask>>(
      stream: _tasks,
      builder: (BuildContext context, AsyncSnapshot<List<PlannerTask>> tasks) {
        return StreamBuilder<List<PlanSpan>>(
          stream: _spans,
          builder: (BuildContext context, AsyncSnapshot<List<PlanSpan>> spans) {
            return StreamBuilder<List<Project>>(
              stream: _projects,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<Project>> projects,
                  ) {
                    return _buildBody(
                      tasks: tasks.data ?? const <PlannerTask>[],
                      spans: spans.data ?? const <PlanSpan>[],
                      projects: projects.data ?? const <Project>[],
                    );
                  },
            );
          },
        );
      },
    );
  }

  Widget _buildBody({
    required List<PlannerTask> tasks,
    required List<PlanSpan> spans,
    required List<Project> projects,
  }) {
    final tasksByDate = groupTasksByDate(tasks);
    final projectsById = indexProjects(projects);
    final spanLayouts = layoutMonthSpans(spans, _grid, maxLanes: 1);
    final weeks = widget.weekMode
        ? <List<LocalDate>>[_visibleWeek()]
        : _grid.weeks;

    final content = Column(
      children: <Widget>[
        if (widget.showWeekdayHeader) _buildWeekdayHeader(),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final width = constraints.maxWidth;
              if (width <= 1) return const SizedBox.shrink();
              final cellWidth = width / 7;
              final double rowHeight;
              if (widget.weekMode) {
                final available = constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : 64.0;
                var height = available.clamp(52.0, 96.0).toDouble();
                if (height > available) height = available;
                rowHeight = height;
              } else {
                final fit = constraints.maxHeight.isFinite
                    ? constraints.maxHeight / weeks.length
                    : 64.0;
                // 整月模式铺满给定高度；只有低于最小可读高度时才内部滚动。
                rowHeight = fit < MobileMetrics.minMonthRowHeight
                    ? MobileMetrics.minMonthRowHeight
                    : fit;
              }
              final rows = <Widget>[
                for (final week in weeks)
                  SizedBox(
                    height: rowHeight,
                    child: _buildWeekRow(
                      week: week,
                      cellWidth: cellWidth,
                      rowHeight: rowHeight,
                      tasksByDate: tasksByDate,
                      projectsById: projectsById,
                      layout:
                          spanLayouts[week.first] ??
                          WeekSpanLayout.empty(week.first),
                      isLastRow: week == weeks.last,
                    ),
                  ),
              ];
              final gridHeight = rowHeight * weeks.length;
              final scrolls =
                  !widget.weekMode &&
                  constraints.maxHeight.isFinite &&
                  gridHeight > constraints.maxHeight + 0.5;
              final table = SizedBox(
                width: width,
                height: gridHeight,
                child: Column(children: rows),
              );
              if (scrolls) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: table,
                );
              }
              return table;
            },
          ),
        ),
      ],
    );

    return GestureDetector(
      onHorizontalDragEnd: (DragEndDetails details) {
        final velocity = details.velocity.pixelsPerSecond.dx;
        if (velocity.abs() < 220) return;
        widget.onSwipePeriod?.call(velocity < 0 ? 1 : -1);
      },
      onVerticalDragEnd: (DragEndDetails details) {
        final velocity = details.velocity.pixelsPerSecond.dy;
        if (velocity.abs() < 220) return;
        widget.onToggleMode?.call();
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }

  /// 紧凑周历要显示的一周：选中日期所在的自然周（周日起始，与桌面一致）。
  List<LocalDate> _visibleWeek() {
    final weekStart = widget.selectedDate.startOfWeek(
      weekStart: kCalendarWeekStart,
    );
    return <LocalDate>[
      for (var index = 0; index < 7; index++) weekStart.addDays(index),
    ];
  }

  Widget _buildWeekdayHeader() {
    final labels = <String>[
      for (var column = 0; column < 7; column++)
        weekdayHeader(_grid.gridStart.addDays(column)),
    ];
    return Container(
      height: MobileMetrics.weekdayHeaderHeight,
      decoration: const BoxDecoration(
        color: AppColors.surfaceSunken,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          for (var column = 0; column < 7; column++)
            Expanded(
              child: Center(
                child: Text(
                  labels[column],
                  style: AppText.caption.copyWith(
                    fontSize: 11.5,
                    height: 1,
                    fontWeight: FontWeight.w500,
                    color: column == 0 || column == 6
                        ? AppColors.textTertiary
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWeekRow({
    required List<LocalDate> week,
    required double cellWidth,
    required double rowHeight,
    required Map<LocalDate, List<PlannerTask>> tasksByDate,
    required Map<String, Project> projectsById,
    required WeekSpanLayout layout,
    required bool isLastRow,
  }) {
    final bars = <Widget>[
      for (final segment in layout.visible)
        _buildSpanBar(segment, cellWidth, projectsById),
    ];

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: Row(
            children: <Widget>[
              for (var column = 0; column < 7; column++)
                Expanded(
                  child: MobileMonthCell(
                    key: ValueKey<String>('mobile-day-${week[column].iso}'),
                    date: week[column],
                    inMonth: week[column].isSameMonthAs(widget.month),
                    isToday: week[column] == widget.today,
                    isSelected: week[column] == widget.selectedDate,
                    isWeekend: week[column].isWeekend,
                    rowHeight: rowHeight,
                    tasks: tasksByDate[week[column]] ?? const <PlannerTask>[],
                    projects: projectsById,
                    onTap: () => widget.onSelectDate(week[column]),
                    onDoubleTap: () => widget.onOpenDay(week[column]),
                    showBorderRight: column != 6,
                    showBorderBottom: !isLastRow,
                  ),
                ),
            ],
          ),
        ),
        ...bars,
      ],
    );
  }

  Widget _buildSpanBar(
    SpanSegment segment,
    double cellWidth,
    Map<String, Project> projectsById,
  ) {
    const inset = 3.0;
    final left =
        segment.startColumn * cellWidth + (segment.continuesBefore ? 0 : inset);
    final right =
        (segment.endColumn + 1) * cellWidth -
        (segment.continuesAfter ? 0 : inset);
    final color = spanColorOf(
      segment.span,
      projectsById[segment.span.projectId],
    );
    final radius = Radius.circular(
      segment.continuesBefore && segment.continuesAfter ? 0 : 2,
    );
    final radiusLeft = segment.continuesBefore ? Radius.zero : radius;
    final radiusRight = segment.continuesAfter ? Radius.zero : radius;
    return Positioned(
      left: left,
      top: 23,
      width: (right - left).clamp(4, cellWidth * 7).toDouble(),
      height: 4,
      child: GestureDetector(
        key: ValueKey<String>(
          'mobile-spanbar-${segment.span.id}-${segment.weekStart.iso}',
        ),
        behavior: HitTestBehavior.opaque,
        onTap: () => _handleSpanTap(segment.span),
        child: Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              color.uiColor.withValues(alpha: 0.5),
              AppColors.surface,
            ),
            borderRadius: BorderRadius.only(
              topLeft: radiusLeft,
              bottomLeft: radiusLeft,
              topRight: radiusRight,
              bottomRight: radiusRight,
            ),
          ),
        ),
      ),
    );
  }

  /// 点击跨天条：优先编辑安排，否则定位到安排起点。
  void _handleSpanTap(PlanSpan span) {
    final handler = widget.onOpenSpan;
    if (handler != null) {
      handler(span);
      return;
    }
    widget.onSelectDate(span.startDate);
  }
}
