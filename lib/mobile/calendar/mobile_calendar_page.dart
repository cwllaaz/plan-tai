import 'package:material_ui/material_ui.dart';

import '../../app/cloud_scope.dart';
import '../../app/shell_state.dart';
import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../../features/calendar/month_layout.dart';
import '../day/mobile_day_panel.dart';
import '../settings/mobile_cloud_visual.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_month_grid.dart';

/// 手机/平板的月历主页面。
///
/// - compact / medium：顶部月份栏 + 月历（可收起为周历）+ 选中日任务摘要；
/// - expanded（平板三栏）：只负责中间的月历区，右侧当日面板由外壳提供。
class MobileCalendarPage extends StatefulWidget {
  const MobileCalendarPage({
    super.key,
    required this.repository,
    required this.shell,
    required this.layout,
    required this.onOpenCloud,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;
  final MobileLayout layout;
  final VoidCallback? onOpenCloud;

  @override
  State<MobileCalendarPage> createState() => _MobileCalendarPageState();
}

class _MobileCalendarPageState extends State<MobileCalendarPage> {
  /// 是否收起为紧凑周历（只显示选中日期所在的一周）。
  bool _weekMode = false;

  bool get _isExpanded => widget.layout == MobileLayout.expanded;

  void _toggleWeekMode() {
    setState(() => _weekMode = !_weekMode);
  }

  void _shiftPeriod(int delta) {
    if (_weekMode) {
      widget.shell.selectDate(widget.shell.selectedDate.addDays(7 * delta));
      return;
    }
    widget.shell.shiftMonth(delta);
  }

  Future<void> _openDaySheet(LocalDate date) async {
    widget.shell.selectDate(date);
    await showMobileDaySheet(
      context,
      repository: widget.repository,
      date: date,
      today: widget.shell.today,
      onDateChange: widget.shell.selectDate,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showDaySection = !_isExpanded;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final padding = widget.layout == MobileLayout.compact
            ? MobileMetrics.pagePadding
            : MobileMetrics.pagePaddingWide;
        final calendarColumn = Padding(
          padding: EdgeInsets.fromLTRB(padding, AppSpacing.xs, padding, 0),
          child: Column(
            children: <Widget>[
              _MobileCalendarTopBar(
                shell: widget.shell,
                weekMode: _weekMode,
                onPrevious: () => _shiftPeriod(-1),
                onNext: () => _shiftPeriod(1),
                onToday: widget.shell.goToToday,
                onOpenCloud: widget.onOpenCloud,
              ),
              if (showDaySection)
                _WeekModeHandle(weekMode: _weekMode, onTap: _toggleWeekMode),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints inner) {
                    final available = inner.maxHeight;
                    final gridHeight = _gridHeight(available, showDaySection);
                    return Column(
                      children: <Widget>[
                        SizedBox(
                          height: gridHeight,
                          child: MobileMonthGrid(
                            repository: widget.repository,
                            month: widget.shell.visibleMonth,
                            today: widget.shell.today,
                            selectedDate: widget.shell.selectedDate,
                            onSelectDate: widget.shell.selectDate,
                            onOpenDay: _openDaySheet,
                            weekMode: showDaySection && _weekMode,
                            onSwipePeriod: _shiftPeriod,
                            onToggleMode: showDaySection
                                ? _toggleWeekMode
                                : null,
                          ),
                        ),
                        if (showDaySection)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.sm,
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                  border: Border.all(color: AppColors.border),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: MobileDayPanel(
                                  repository: widget.repository,
                                  date: widget.shell.selectedDate,
                                  today: widget.shell.today,
                                  showHeaderDivider: false,
                                  showNote: false,
                                  onOpenFullDay: () =>
                                      _openDaySheet(widget.shell.selectedDate),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
        if (!_isExpanded) return calendarColumn;
        final panelWidth = (constraints.maxWidth * 0.36)
            .clamp(300.0, MobileMetrics.dayPanelWidth)
            .toDouble();
        return Row(
          children: <Widget>[
            Expanded(child: calendarColumn),
            Container(
              width: panelWidth,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(left: BorderSide(color: AppColors.border)),
              ),
              child: MobileDayPanel(
                repository: widget.repository,
                date: widget.shell.selectedDate,
                today: widget.shell.today,
                onDateChange: widget.shell.selectDate,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 月历高度：下方要留出当日摘要区；极矮屏幕时至少给月历一半高度。
  ///
  /// 整月模式下按「该月实际周数 × 单个日期格最大高度」封顶，避免平板竖屏把
  /// 月历格子拉得过高、下方摘要区被挤没；多出来的高度留给当日列表。
  double _gridHeight(double available, bool showDaySection) {
    if (!showDaySection) return available;
    if (_weekMode) {
      return MobileMetrics.weekdayHeaderHeight + 96;
    }
    final section = (available * 0.34).clamp(132.0, 260.0).toDouble();
    final grid = available - section;
    final weekCount = MonthGrid.of(widget.shell.visibleMonth).weekCount;
    final cap =
        weekCount * MobileMetrics.maxMonthRowHeight +
        MobileMetrics.weekdayHeaderHeight;
    final capped = grid > cap ? cap : grid;
    if (capped < 150) return available * 0.55;
    return capped;
  }
}

/// 顶部栏：上下月、月份标题、回到今天、云端状态入口。
class _MobileCalendarTopBar extends StatelessWidget {
  const _MobileCalendarTopBar({
    required this.shell,
    required this.weekMode,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
    required this.onOpenCloud,
  });

  final PlannerShellState shell;
  final bool weekMode;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback? onOpenCloud;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MobileMetrics.topBarHeight,
      child: Row(
        children: <Widget>[
          MobileIconButton(
            key: const ValueKey<String>('mobile-prev-period'),
            icon: Icons.chevron_left_rounded,
            tooltip: weekMode ? '上一周' : '上个月',
            onPressed: onPrevious,
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  monthTitle(shell.visibleMonth),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.h1.copyWith(fontSize: 19),
                ),
                Text(
                  _subtitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          MobileIconButton(
            key: const ValueKey<String>('mobile-next-period'),
            icon: Icons.chevron_right_rounded,
            tooltip: weekMode ? '下一周' : '下个月',
            onPressed: onNext,
          ),
          MobileIconButton(
            key: const ValueKey<String>('mobile-today'),
            icon: Icons.today_rounded,
            tooltip: '回到今天',
            onPressed: onToday,
          ),
          _CloudStatusButton(onPressed: onOpenCloud),
        ],
      ),
    );
  }

  String _subtitle() {
    if (weekMode) {
      final weekStart = shell.selectedDate.startOfWeek(
        weekStart: kCalendarWeekStart,
      );
      final weekEnd = weekStart.addDays(6);
      return '周历 · ${monthDay(weekStart)} – ${monthDay(weekEnd)}';
    }
    return '今天 ${monthDayWithWeekday(shell.today)}';
  }
}

/// 顶部云端状态图标（只表达状态，点击进入「账号与同步」）。
class _CloudStatusButton extends StatelessWidget {
  const _CloudStatusButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final controller = CloudScope.controllerOf(context);
    if (controller == null) {
      return MobileIconButton(
        key: const ValueKey<String>('mobile-cloud-entry'),
        icon: Icons.cloud_off_outlined,
        tooltip: '离线 · 云同步未启用',
        color: AppColors.textDisabled,
        onPressed: onPressed,
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final visual = mobileCloudVisual(controller);
        return MobileIconButton(
          key: const ValueKey<String>('mobile-cloud-entry'),
          icon: visual.icon,
          tooltip: visual.label,
          color: visual.color,
          onPressed: onPressed,
        );
      },
    );
  }
}

/// 收起/展开月历的手势条（点击或上下滑动）。
class _WeekModeHandle extends StatelessWidget {
  const _WeekModeHandle({required this.weekMode, required this.onTap});

  final bool weekMode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey<String>('mobile-calendar-mode'),
      onTap: onTap,
      child: SizedBox(
        height: 24,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              weekMode
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_up_rounded,
              size: 16,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 2),
            Text(
              weekMode ? '展开整月' : '收起为周历',
              style: AppText.micro.copyWith(fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}
