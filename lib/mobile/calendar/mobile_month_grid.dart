import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../../features/calendar/month_layout.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_month_cell.dart';

/// 移动端月历：七列网格 + 今天/选中高亮 + 带标题的跨天安排横条 + 任务圆点与 `+N` 计数。
///
/// - `weekMode = false`：整月网格（5–6 行），填满给定高度；
/// - `weekMode = true`：只显示选中日期所在的一周（紧凑周历），高度按内容；
/// - 左右滑动 → [onSwipePeriod]（外壳决定换月还是换周）。
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
              final minHeight = MobileMonthCell.minimumHeight(context);
              final fit = constraints.maxHeight.isFinite
                  ? constraints.maxHeight / weeks.length
                  : 64.0;
              // 至少给标题、日期和任务圆点各留一行。空间够时显示第二条重叠的安排。
              final rowHeight = fit < minHeight ? minHeight : fit;
              final maxLanes =
                  rowHeight >=
                      MobileMonthCell.minimumHeight(context, spanLanes: 2)
                  ? 2
                  : 1;
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
                      layout: layoutWeekSpans(
                        spans,
                        week.first,
                        maxLanes: maxLanes,
                      ),
                      isLastRow: week == weeks.last,
                    ),
                  ),
              ];
              final gridHeight = rowHeight * weeks.length;
              final scrolls =
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
        _buildSpanBar(context, segment, cellWidth, projectsById),
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
    BuildContext context,
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
    final width = right - left;
    if (width <= 0) return const SizedBox.shrink();
    final radiusLeft = segment.continuesBefore
        ? Radius.zero
        : const Radius.circular(3);
    final radiusRight = segment.continuesAfter
        ? Radius.zero
        : const Radius.circular(3);
    final laneHeight = MobileMonthCell.spanLaneHeight(context);
    return Positioned(
      left: left,
      top:
          MobileMonthCell.dateBandHeight(context) +
          segment.lane * (laneHeight + MobileMonthCell.spanLaneGap),
      width: width,
      height: laneHeight,
      child: GestureDetector(
        key: ValueKey<String>(
          'mobile-spanbar-${segment.span.id}-${segment.weekStart.iso}',
        ),
        behavior: widget.onOpenSpan == null
            ? HitTestBehavior.deferToChild
            : HitTestBehavior.opaque,
        onTap: widget.onOpenSpan == null
            ? null
            : () => widget.onOpenSpan!(segment.span),
        child: IgnorePointer(
          ignoring: widget.onOpenSpan == null,
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: radiusLeft,
              bottomLeft: radiusLeft,
              topRight: radiusRight,
              bottomRight: radiusRight,
            ),
            child: ColoredBox(
              color: MobilePalette.spanFill(color),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (segment.beginsHere)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 2,
                      child: ColoredBox(color: color.uiColor),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        segment.span.title,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        semanticsLabel: '跨天安排：${segment.span.title}',
                        style: AppText.micro.copyWith(
                          fontSize: MobileMonthCell.spanTitleSize,
                          height: 1.1,
                          fontWeight: FontWeight.w500,
                          color: MobilePalette.spanInk(color),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
