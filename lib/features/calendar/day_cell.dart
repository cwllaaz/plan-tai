import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'calendar_style.dart';
import 'month_layout.dart';

/// 月历里的一格（一天）。
///
/// 命中层级（从下往上）：
/// 1. 底色与 1px 网格线（纯绘制，不吃指针）；
/// 2. 命中区：[Listener] 在**按下**时就上报选中，双击触发 `onOpenDay`
///    —— 不用 `onTap`，避免"注册了双击后单击要等 300ms"的迟滞；
/// 3. 内容层：日期数字、任务条目、`+N 项` —— 任务行自己吃点击，空白处继续下传到命中区。
class DayCell extends StatefulWidget {
  const DayCell({
    super.key,
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.isLastColumn,
    required this.isLastRow,
    required this.width,
    required this.height,
    required this.laneCount,
    required this.tasks,
    required this.projects,
    required this.spanCount,
    required this.onSelect,
    required this.onOpenDay,
    required this.onTaskTap,
    this.hiddenSpanCount = 0,
  });

  final LocalDate date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool isLastColumn;
  final bool isLastRow;

  /// 格子宽度，用于决定是否收起任务时间。
  final double width;

  /// 格子高度，用于决定能放几条任务。
  final double height;

  /// 本周的跨天条车道数（0–2），决定要为车道预留多高。
  final int laneCount;

  /// 当天的全部任务（契约顺序，已排期）。
  final List<PlannerTask> tasks;

  /// 项目索引，用于取颜色与名称。
  final Map<String, Project> projects;

  /// 当天覆盖的跨天阶段数量（只用于无障碍文案）。
  final int spanCount;

  /// 本周被折叠的跨天条数量；只有每周最后一列会显示 `+N`。
  final int hiddenSpanCount;

  /// 单击格子空白（指针按下即触发）。
  final VoidCallback onSelect;

  /// 双击格子空白 / 点 `+N` 折叠提示。
  final VoidCallback onOpenDay;

  /// 单击任务：交给上层选中该任务所在的那一天（不直接开抽屉）。
  final ValueChanged<PlannerTask> onTaskTap;

  @override
  State<DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<DayCell> {
  bool _hovered = false;

  Color get _background {
    if (widget.isSelected) return CalendarPalette.selected;
    if (widget.isToday) return AppColors.todaySoft;
    if (!widget.inMonth) return CalendarPalette.outsideMonth;
    if (_hovered) return AppColors.surfaceHover;
    // 本月内的格子一律白底：周末不再单独上灰，避免"整列发灰"被误读成非本月。
    return AppColors.surface;
  }

  @override
  Widget build(BuildContext context) {
    final taskLayout = layoutDayTasks(
      widget.tasks,
      maxTasks: CalendarMetrics.maxTasks,
      availableHeight: CalendarMetrics.taskAreaHeight(
        rowHeight: widget.height,
        laneCount: widget.laneCount,
      ),
      taskRowHeight: CalendarMetrics.taskRowHeight,
      overflowRowHeight: CalendarMetrics.overflowRowHeight,
    );

    final showTime = widget.width >= CalendarMetrics.compactCellWidth;
    final laneReserve = widget.laneCount <= 0
        ? 0.0
        : CalendarMetrics.laneTopGap +
              CalendarMetrics.laneBandHeight(widget.laneCount) +
              2;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        container: true,
        selected: widget.isSelected,
        label: _semanticsLabel(),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 1. 底色 + 网格线
            DecoratedBox(
              decoration: BoxDecoration(
                color: _background,
                border: Border(
                  left: widget.isSelected
                      ? const BorderSide(color: AppColors.accent, width: 2)
                      : BorderSide.none,
                  right: widget.isLastColumn
                      ? BorderSide.none
                      : const BorderSide(color: AppColors.border),
                  bottom: widget.isLastRow
                      ? BorderSide.none
                      : const BorderSide(color: AppColors.border),
                ),
              ),
            ),
            // 2. 命中区
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.onOpenDay,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if ((event.buttons & kPrimaryButton) != 0) {
                      widget.onSelect();
                    }
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // 3. 内容
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(CalendarMetrics.cellPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      height: CalendarMetrics.dateRowHeight,
                      child: Row(
                        children: <Widget>[
                          _DateBadge(
                            date: widget.date,
                            inMonth: widget.inMonth,
                            isToday: widget.isToday,
                            isSelected: widget.isSelected,
                          ),
                          const Spacer(),
                          if (widget.hiddenSpanCount > 0)
                            _SpanOverflowBadge(
                              count: widget.hiddenSpanCount,
                              onTap: widget.onOpenDay,
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: laneReserve),
                    for (final task in taskLayout.visible)
                      _TaskRow(
                        key: ValueKey<String>('task-${task.id}'),
                        task: task,
                        project: task.projectId == null
                            ? null
                            : widget.projects[task.projectId],
                        inMonth: widget.inMonth,
                        showTime: showTime,
                        onSelect: () => widget.onTaskTap(task),
                        onOpenDay: widget.onOpenDay,
                      ),
                    if (taskLayout.hiddenCount > 0)
                      _TaskOverflowRow(
                        key: ValueKey<String>(
                          'day-overflow-${widget.date.iso}',
                        ),
                        count: taskLayout.hiddenCount,
                        onTap: widget.onOpenDay,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _semanticsLabel() {
    final parts = <String>[monthDayWithWeekday(widget.date)];
    if (widget.isToday) parts.add('今天');
    if (widget.isSelected) parts.add('已选中');
    if (widget.tasks.isNotEmpty) parts.add('${widget.tasks.length} 项任务');
    if (widget.spanCount > 0) parts.add('${widget.spanCount} 条跨天安排');
    return parts.join('，');
  }
}

/// 日期数字徽标：今天 = accent 实底白字；选中 = 白底 + accent 描边；非本月 = 灰字。
class _DateBadge extends StatelessWidget {
  const _DateBadge({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
  });

  final LocalDate date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final Color textColor;
    if (isToday) {
      textColor = AppColors.textInverse;
    } else if (!inMonth) {
      textColor = AppColors.textDisabled;
    } else if (isSelected) {
      textColor = AppColors.accent;
    } else {
      textColor = AppColors.textPrimary;
    }

    final BoxDecoration? decoration;
    if (isToday) {
      decoration = const BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
      );
    } else if (isSelected) {
      decoration = BoxDecoration(
        color: AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.accent),
      );
    } else {
      decoration = null;
    }

    return Container(
      key: ValueKey<String>('day-badge-${date.iso}'),
      width: CalendarMetrics.dateBadgeSize,
      height: CalendarMetrics.dateBadgeSize,
      alignment: Alignment.center,
      decoration: decoration,
      child: Text(
        dayNumber(date),
        style: AppText.numeric.copyWith(
          fontSize: 12,
          height: 1.0,
          fontWeight: isToday || isSelected ? FontWeight.w600 : FontWeight.w500,
          color: textColor,
        ),
      ),
    );
  }
}

/// 一行任务：项目色圆点 + 时间 + 标题；完成态加删除线。
///
/// 交互：单击 = 选中该日（与点格子空白一致，不打断浏览）；双击 = 打开当日面板。
/// 这样整格"单击选中 / 双击展开"的语义保持一致，也不会因为任务行挡住格子中心
/// 而误开抽屉。
class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.project,
    required this.inMonth,
    required this.showTime,
    required this.onSelect,
    required this.onOpenDay,
  });

  final PlannerTask task;
  final Project? project;
  final bool inMonth;
  final bool showTime;
  final VoidCallback onSelect;
  final VoidCallback onOpenDay;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final done = task.isDone;
    final titleColor = done
        ? CalendarPalette.taskDoneInk(widget.inMonth)
        : (widget.inMonth ? AppColors.textSecondary : AppColors.textDisabled);

    return Tooltip(
      message: _tooltip(task, widget.project?.name ?? ''),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if ((event.buttons & kPrimaryButton) != 0) widget.onSelect();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onOpenDay,
            child: Container(
              height: CalendarMetrics.taskRowHeight,
              padding: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: _hovered
                    ? AppColors.accentSoft.withValues(alpha: 0.45)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: CalendarMetrics.taskDotSize,
                    height: CalendarMetrics.taskDotSize,
                    decoration: BoxDecoration(
                      color: done
                          ? AppColors.success
                          : CalendarPalette.taskDot(widget.project?.color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  if (widget.showTime && task.timeSlot != null) ...<Widget>[
                    SizedBox(
                      width: CalendarMetrics.taskTimeWidth,
                      child: Text(
                        task.timeSlot!.startLabel,
                        maxLines: 1,
                        style: AppText.numeric.copyWith(
                          fontSize: 9.5,
                          height: 1.0,
                          color: CalendarPalette.taskTimeInk(widget.inMonth),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ] else
                    const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.0,
                        color: titleColor,
                        fontWeight: done ? FontWeight.w400 : FontWeight.w500,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: titleColor,
                        fontFamilyFallback: AppText.fontFamilyFallback,
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

  static String _tooltip(PlannerTask task, String projectName) {
    final parts = <String>[
      if (projectName.isNotEmpty) projectName,
      if (task.timeSlot != null) timeSlotLabel(task.timeSlot),
      if (task.isDone) '已完成' else task.priority.label,
    ];
    return '${task.title}\n${parts.join('｜')}';
  }
}

/// `+N 项`：当天任务放不下时的折叠提示，点击交给上层展开当日面板。
class _TaskOverflowRow extends StatelessWidget {
  const _TaskOverflowRow({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: CalendarMetrics.overflowRowHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '+$count 项',
              style: AppText.micro.copyWith(
                fontSize: 10,
                height: 1.0,
                color: AppColors.textTertiary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 本周跨天条超出两条车道时的 `+N` 提示（只在每周最后一列出现）。
class _SpanOverflowBadge extends StatelessWidget {
  const _SpanOverflowBadge({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '本周还有 $count 条安排未展开，双击日期查看当日全部',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceSunken,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              '+$count',
              style: AppText.micro.copyWith(
                fontSize: 9.5,
                height: 1.4,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
