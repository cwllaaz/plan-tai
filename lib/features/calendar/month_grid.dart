import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'calendar_style.dart';
import 'day_cell.dart';
import 'month_layout.dart';
import 'span_bar.dart';

/// 星期表头：单字 `日 一 二 三 四 五 六`（顺序随 [MonthGrid.weekStart]）。
class WeekdayHeaderRow extends StatelessWidget {
  const WeekdayHeaderRow({super.key, required this.grid});

  final MonthGrid grid;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: CalendarMetrics.weekdayHeaderHeight,
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
                  weekdayHeader(grid.gridStart.addDays(column)),
                  style: AppText.caption.copyWith(
                    fontSize: 11,
                    height: 1.0,
                    fontWeight: FontWeight.w500,
                    color: grid.gridStart.addDays(column).isWeekend
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
}

/// 月历网格：按周铺开，每行是一整条"星期行"，跨天条以覆盖层的形式横跨格子。
///
/// 另外负责**右键拖选**：按住右键从某天拖到另一天，会像桌面框选一样拉出一个
/// 半透明选择框，松手后通过 [onRangeSelected] 把起止日期交给外壳
/// （外壳据此弹出"新建跨天安排"）。左键的选中/双击语义不受影响。
class MonthGridBody extends StatefulWidget {
  const MonthGridBody({
    super.key,
    required this.grid,
    required this.spanLayout,
    required this.tasksByDate,
    required this.projects,
    required this.spansPerDay,
    required this.today,
    required this.selectedDate,
    required this.width,
    required this.height,
    required this.onSelectDate,
    required this.onOpenDay,
    required this.onTaskTap,
    this.onRangeSelected,
    this.onOpenSpan,
  });

  final MonthGrid grid;
  final Map<LocalDate, WeekSpanLayout> spanLayout;
  final Map<LocalDate, List<PlannerTask>> tasksByDate;
  final Map<String, Project> projects;
  final Map<LocalDate, int> spansPerDay;
  final LocalDate today;
  final LocalDate selectedDate;
  final double width;
  final double height;
  final ValueChanged<LocalDate> onSelectDate;
  final ValueChanged<LocalDate> onOpenDay;
  final ValueChanged<PlannerTask> onTaskTap;

  /// 右键拖选松手时回调（闭区间、已按时间排序）；为 null 时右键拖选不生效。
  final void Function(LocalDate start, LocalDate end)? onRangeSelected;

  /// 双击跨天条时回调（编辑 / 归类）；为空时双击无动作。
  final ValueChanged<PlanSpan>? onOpenSpan;

  @override
  State<MonthGridBody> createState() => _MonthGridBodyState();
}

class _MonthGridBodyState extends State<MonthGridBody> {
  LocalDate? _anchor;
  LocalDate? _focus;
  Offset? _pointer;
  bool _dragging = false;

  double get _cellWidth => widget.width / 7;

  final ScrollController _scroll = ScrollController();
  late List<double> _rowEdges;
  late List<double> _rowHeights;
  int? _dragPointer;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MonthGridBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width != widget.width || oldWidget.height != widget.height) {
      _clearSelection();
    }
  }

  /// 空闲周让出空间给密集周；空间充足时仍然等高。
  void _measureRows() {
    final minima = <double>[
      for (final week in widget.grid.weeks)
        CalendarMetrics.requiredRowHeight(
          widget.spanLayout[week.first]?.laneCount ?? 0,
          week.fold(
            0,
            (max, date) => math.max(max, widget.tasksByDate[date]?.length ?? 0),
          ),
        ),
    ];
    var remaining = widget.height;
    var rows = minima.length;
    var commonHeight = 0.0;
    for (final minimum in minima.toList()..sort((a, b) => b.compareTo(a))) {
      if (remaining / rows >= minimum) {
        commonHeight = math.min(remaining / rows, CalendarMetrics.maxRowHeight);
        break;
      }
      remaining -= minimum;
      rows--;
    }
    _rowHeights = [
      for (final minimum in minima) math.max(minimum, commonHeight),
    ];
    var edge = 0.0;
    _rowEdges = [0, for (final height in _rowHeights) edge += height];
  }

  @override
  Widget build(BuildContext context) {
    _measureRows();
    final rows = Column(
      children: <Widget>[
        for (var index = 0; index < widget.grid.weeks.length; index++)
          SizedBox(
            key: ValueKey<String>('week-${widget.grid.weeks[index].first.iso}'),
            height: _rowHeights[index],
            child: _WeekRow(
              week: widget.grid.weeks[index],
              month: widget.grid.month,
              isLastRow: index == widget.grid.weeks.length - 1,
              rowHeight: _rowHeights[index],
              width: widget.width,
              layout:
                  widget.spanLayout[widget.grid.weeks[index].first] ??
                  WeekSpanLayout.empty(widget.grid.weeks[index].first),
              tasksByDate: widget.tasksByDate,
              projects: widget.projects,
              spansPerDay: widget.spansPerDay,
              today: widget.today,
              selectedDate: widget.selectedDate,
              onSelectDate: widget.onSelectDate,
              onOpenDay: widget.onOpenDay,
              onTaskTap: widget.onTaskTap,
              onOpenSpan: widget.onOpenSpan,
            ),
          ),
      ],
    );

    // 保留同一视口，缩放变化时不重建日期格或滚动控制器。
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: _rowEdges.last > widget.height + 0.001,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _scroll,
          child: _interactive(
            extent: math.max(_rowEdges.last, widget.height),
            rows: rows,
          ),
        ),
      ),
    );
  }

  Widget _interactive({required double extent, required Widget rows}) {
    final selection = _selection;
    return SizedBox(
      width: widget.width,
      height: extent,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleDown,
        onPointerMove: _handleMove,
        onPointerUp: _handleUp,
        onPointerCancel: _handleCancel,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(child: rows),
            if (selection != null) _selectionBox(selection),
            if (_dragging && selection != null && _pointer != null)
              _rangeHint(selection, extent),
          ],
        ),
      ),
    );
  }

  void _handleDown(PointerDownEvent event) {
    if (widget.onRangeSelected == null ||
        _dragPointer != null ||
        (event.buttons & kSecondaryButton) == 0) {
      return;
    }
    final date = _dateAt(event.localPosition);
    if (date == null) return;
    setState(() {
      _dragPointer = event.pointer;
      _anchor = date;
      _focus = date;
      _pointer = event.localPosition;
      _dragging = false;
    });
  }

  void _handleMove(PointerMoveEvent event) {
    if (_dragPointer != event.pointer) return;
    final date = _dateAt(event.localPosition);
    setState(() {
      _pointer = event.localPosition;
      if (date != null) {
        _focus = date;
        _dragging = _anchor != date;
      }
    });
  }

  void _handleUp(PointerUpEvent event) {
    if (_dragPointer != event.pointer) return;
    final selection = _selection;
    final shouldFire = _dragging && selection != null;
    final callback = widget.onRangeSelected;
    setState(_clearSelection);
    if (shouldFire) callback?.call(selection.start, selection.end);
  }

  void _handleCancel(PointerCancelEvent event) {
    if (_dragPointer != event.pointer) return;
    setState(_clearSelection);
  }

  void _clearSelection() {
    _dragPointer = null;
    _anchor = null;
    _focus = null;
    _pointer = null;
    _dragging = false;
  }

  /// 指针位置 → 网格里的日期；落在网格外返回 null（拖出边界时保持上一次结果）。
  LocalDate? _dateAt(Offset position) {
    final column = (position.dx / _cellWidth).floor();
    final row = _rowEdges.indexWhere((edge) => edge > position.dy) - 1;
    if (column < 0 || column > 6 || row < 0 || row >= widget.grid.weekCount) {
      return null;
    }
    return widget.grid.gridStart.addDays(row * 7 + column);
  }

  _DaySelection? get _selection {
    final anchor = _anchor;
    final focus = _focus;
    if (anchor == null || focus == null) return null;
    final a = anchor.differenceInDays(widget.grid.gridStart);
    final b = focus.differenceInDays(widget.grid.gridStart);
    final low = a <= b ? a : b;
    final high = a <= b ? b : a;
    return _DaySelection(
      firstIndex: low,
      lastIndex: high,
      start: widget.grid.gridStart.addDays(low),
      end: widget.grid.gridStart.addDays(high),
    );
  }

  Widget _selectionBox(_DaySelection selection) {
    return Positioned.fill(
      child: CalendarRangeOverlay(
        key: const ValueKey<String>('calendar-range-box'),
        runs: _selectionRuns(selection),
      ),
    );
  }

  /// 把「连续日期」切成每周一条横向区间。
  ///
  /// 拖选 11/3–11/11 时，选中集合是 3、4、5、6、7、8、9、10、11 这 9 天，
  /// 而不是"3–4 与 10–11 组成的矩形"。跨周时按周折返：第一周从起始列到周六，
  /// 中间整周铺满，最后一周从周日起到结束列。
  List<Rect> _selectionRuns(_DaySelection selection) {
    final runs = <Rect>[];
    for (var row = selection.firstRow; row <= selection.lastRow; row++) {
      final firstColumn = row == selection.firstRow ? selection.firstColumn : 0;
      final lastColumn = row == selection.lastRow ? selection.lastColumn : 6;
      final left = firstColumn * _cellWidth + 1;
      final right = (lastColumn + 1) * _cellWidth - 1;
      // 相邻周之间不留缝，并集后才能画成一整块连续区域。
      final top = _rowEdges[row] + (row == selection.firstRow ? 1 : 0);
      final bottom = _rowEdges[row + 1] - (row == selection.lastRow ? 1 : 0);
      runs.add(Rect.fromLTRB(left, top, right, bottom));
    }
    return runs;
  }

  Widget _rangeHint(_DaySelection selection, double extent) {
    final pointer = _pointer!;
    const hintWidth = 168.0;
    final left = (pointer.dx + 14)
        .clamp(4.0, math.max(4.0, widget.width - hintWidth - 4))
        .toDouble();
    final top = (pointer.dy + 18).clamp(4.0, extent - 30);
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey<String>('calendar-range-hint'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.textPrimary,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            '${monthDay(selection.start)} – ${monthDay(selection.end)}'
            ' · ${selection.dayCount} 天',
            style: AppText.micro.copyWith(
              fontSize: 10.5,
              height: 1.2,
              color: AppColors.textInverse,
            ),
          ),
        ),
      ),
    );
  }
}

/// 右键拖选出来的一段日期（闭区间）。
class _DaySelection {
  const _DaySelection({
    required this.firstIndex,
    required this.lastIndex,
    required this.start,
    required this.end,
  });

  /// 相对网格首日的下标。
  final int firstIndex;
  final int lastIndex;
  final LocalDate start;
  final LocalDate end;

  int get firstRow => firstIndex ~/ 7;
  int get firstColumn => firstIndex % 7;
  int get lastRow => lastIndex ~/ 7;
  int get lastColumn => lastIndex % 7;

  int get dayCount => lastIndex - firstIndex + 1;
}

/// 拖选时盖在网格上的"连续日期"选择层。
///
/// [runs] 是每周围出来的横向区间（彼此贴合）；绘制时先把它们并成一个路径，
/// 再一次性填充 + 描边，所以跨周的选择看起来仍是**一整块连着的区域**，
/// 不会出现"矩形框只框住首尾两列"的错觉。
class CalendarRangeOverlay extends StatelessWidget {
  const CalendarRangeOverlay({super.key, required this.runs, this.color});

  final List<Rect> runs;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _RangePainter(runs: runs, color: color ?? AppColors.accent),
      ),
    );
  }
}

class _RangePainter extends CustomPainter {
  const _RangePainter({required this.runs, required this.color});

  final List<Rect> runs;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (runs.isEmpty) return;
    var merged = Path();
    for (final run in runs) {
      merged = Path.combine(PathOperation.union, merged, Path()..addRect(run));
    }
    canvas.drawPath(
      merged,
      Paint()
        ..color = color.withValues(alpha: 0.10)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      merged,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_RangePainter oldDelegate) =>
      oldDelegate.color != color || !_sameRuns(oldDelegate.runs, runs);

  static bool _sameRuns(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.week,
    required this.month,
    required this.isLastRow,
    required this.rowHeight,
    required this.width,
    required this.layout,
    required this.tasksByDate,
    required this.projects,
    required this.spansPerDay,
    required this.today,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDay,
    required this.onTaskTap,
    required this.onOpenSpan,
  });

  final List<LocalDate> week;
  final LocalDate month;
  final bool isLastRow;
  final double rowHeight;
  final double width;
  final WeekSpanLayout layout;
  final Map<LocalDate, List<PlannerTask>> tasksByDate;
  final Map<String, Project> projects;
  final Map<LocalDate, int> spansPerDay;
  final LocalDate today;
  final LocalDate selectedDate;
  final ValueChanged<LocalDate> onSelectDate;
  final ValueChanged<LocalDate> onOpenDay;
  final ValueChanged<PlannerTask> onTaskTap;
  final ValueChanged<PlanSpan>? onOpenSpan;

  @override
  Widget build(BuildContext context) {
    final cellWidth = width / 7;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Row(
            children: <Widget>[
              for (var column = 0; column < 7; column++)
                Expanded(child: _buildCell(column)),
            ],
          ),
        ),
        for (final segment in layout.visible) _buildSpan(segment, cellWidth),
      ],
    );
  }

  Widget _buildCell(int column) {
    final date = week[column];
    final tasks = tasksByDate[date] ?? const <PlannerTask>[];
    return DayCell(
      key: ValueKey<String>('day-${date.iso}'),
      date: date,
      inMonth: date.isSameMonthAs(month),
      isToday: date == today,
      isSelected: date == selectedDate,
      isLastColumn: column == 6,
      isLastRow: isLastRow,
      width: width / 7,
      height: rowHeight,
      laneCount: layout.laneCount,
      tasks: tasks,
      projects: projects,
      spanCount: spansPerDay[date] ?? 0,
      hiddenSpanCount: layout.hidden
          .where(
            (span) =>
                !date.isBefore(span.startDate) && !date.isAfter(span.endDate),
          )
          .length,
      onSelect: () => onSelectDate(date),
      onOpenDay: () => onOpenDay(date),
      onTaskTap: onTaskTap,
    );
  }

  /// 本周所属月份：取周中点（第 4 天）所在月，避免整周都落在相邻月时判断错误。
  LocalDate get monthOfWeek => week[3];

  Widget _buildSpan(SpanSegment segment, double cellWidth) {
    final left =
        segment.startColumn * cellWidth +
        (segment.continuesBefore ? -0.5 : CalendarMetrics.spanEdgeInset);
    final right =
        (segment.endColumn + 1) * cellWidth -
        (segment.continuesAfter ? -0.5 : CalendarMetrics.spanEdgeInset);
    final barWidth = right - left < 8 ? 8.0 : right - left;
    final top =
        CalendarMetrics.cellPadding +
        CalendarMetrics.dateRowHeight +
        CalendarMetrics.laneTopGap +
        segment.lane * (CalendarMetrics.laneHeight + CalendarMetrics.laneGap);
    final project = projects[segment.span.projectId];

    return Positioned(
      left: left,
      top: top,
      width: barWidth,
      height: CalendarMetrics.laneHeight,
      child: SpanBar(
        key: ValueKey<String>(
          'span-${segment.span.id}-${segment.weekStart.iso}',
        ),
        segment: segment,
        color: spanColorOf(segment.span, project),
        projectName: project?.name ?? '',
        onTap: () => onSelectDate(segment.span.startDate),
        onOpen: onOpenSpan == null ? null : () => onOpenSpan!(segment.span),
      ),
    );
  }
}
