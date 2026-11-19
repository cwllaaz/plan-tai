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
import 'mobile_month_cell.dart';
import 'mobile_month_grid.dart';

/// 手机/平板的月历主页面。
///
/// - compact / medium：顶部月份栏 + 月历（可收起为周历）+ 选中日任务摘要；
/// - expanded（平板三栏）：只负责中间的月历与右侧的当日面板并排。
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
  final _gridKey = GlobalKey();
  final _dayPanelKey = GlobalKey();

  bool get _showsWeek => !_isExpanded && _weekMode;

  bool get _isExpanded => widget.layout == MobileLayout.expanded;

  void _toggleWeekMode() {
    setState(() => _weekMode = !_weekMode);
  }

  void _shiftPeriod(int delta) {
    if (_showsWeek) {
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = widget.layout == MobileLayout.compact
            ? MobileMetrics.pagePadding
            : MobileMetrics.pagePaddingWide;
        final weekCount = _showsWeek
            ? 1
            : MonthGrid.of(widget.shell.visibleMonth).weekCount;
        final minGridHeight =
            MobileMetrics.weekdayHeaderHeight +
            weekCount * MobileMonthCell.minimumHeight(context) +
            2;
        final preferredMax = _showsWeek
            ? MobileMetrics.weekdayHeaderHeight + 76
            : weekCount * MobileMetrics.maxMonthRowHeight +
                  MobileMetrics.weekdayHeaderHeight;
        final maxGridHeight = preferredMax < minGridHeight
            ? minGridHeight
            : preferredMax;
        final panelWidth = (constraints.maxWidth * 0.36)
            .clamp(300.0, MobileMetrics.dayPanelWidth)
            .toDouble();

        final calendar = _MobileCalendarTopBar(
          shell: widget.shell,
          weekMode: _showsWeek,
          onPrevious: () => _shiftPeriod(-1),
          onNext: () => _shiftPeriod(1),
          onToday: widget.shell.goToToday,
          onOpenCloud: widget.onOpenCloud,
          onToggleMode: _isExpanded ? null : _toggleWeekMode,
        );
        final grid = MobileMonthGrid(
          key: _gridKey,
          repository: widget.repository,
          month: widget.shell.visibleMonth,
          today: widget.shell.today,
          selectedDate: widget.shell.selectedDate,
          onSelectDate: widget.shell.selectDate,
          onOpenDay: _openDaySheet,
          weekMode: _showsWeek,
          onSwipePeriod: _shiftPeriod,
        );
        // 横屏/分屏太矮时，整月与当日事项共用一个纵向滚动区，
        // 避免日期格和任务列表各只剩一小条独立的视口。
        const toolbarHeight = MobileMetrics.minTapTarget * 2;
        final available = constraints.maxHeight - toolbarHeight;
        final scrollTogether = !_isExpanded && available < minGridHeight + 142;
        final gridHeight = scrollTogether
            ? (_showsWeek ? maxGridHeight : minGridHeight)
            : (available * 0.55).clamp(minGridHeight, maxGridHeight).toDouble();
        final calendarBlock = Padding(
          padding: EdgeInsets.symmetric(horizontal: padding),
          child: Column(
            children: [
              calendar,
              if (_isExpanded)
                Expanded(child: grid)
              else
                SizedBox(height: gridHeight, child: grid),
            ],
          ),
        );
        final dayPanel = MobileDayPanel(
          key: _dayPanelKey,
          repository: widget.repository,
          date: widget.shell.selectedDate,
          today: widget.shell.today,
          showHeaderDivider: _isExpanded,
          showNote: _isExpanded,
          keepNoteOnResize: true,
          addInHeader: true,
          leading: scrollTogether ? calendarBlock : null,
          onDateChange: _isExpanded ? widget.shell.selectDate : null,
          onOpenFullDay: _isExpanded
              ? null
              : () => _openDaySheet(widget.shell.selectedDate),
        );
        if (_isExpanded) {
          return Row(
            children: [
              Expanded(child: calendarBlock),
              Container(
                width: panelWidth,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(left: BorderSide(color: AppColors.border)),
                ),
                child: dayPanel,
              ),
            ],
          );
        }
        if (scrollTogether) return dayPanel;
        return Column(
          children: [
            calendarBlock,
            Expanded(
              child: Container(
                margin: EdgeInsets.fromLTRB(padding, AppSpacing.sm, padding, 0),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: AppColors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: dayPanel,
              ),
            ),
          ],
        );
      },
    );
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
    this.onToggleMode,
  });

  final PlannerShellState shell;
  final bool weekMode;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback? onOpenCloud;
  final VoidCallback? onToggleMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: MobileMetrics.minTapTarget,
          child: Row(
            children: [
              MobileIconButton(
                key: const ValueKey<String>('mobile-prev-period'),
                icon: Icons.chevron_left_rounded,
                tooltip: weekMode ? '上一周' : '上个月',
                onPressed: onPrevious,
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      monthTitle(shell.visibleMonth),
                      maxLines: 1,
                      style: AppText.h1,
                    ),
                  ),
                ),
              ),
              MobileIconButton(
                key: const ValueKey<String>('mobile-next-period'),
                icon: Icons.chevron_right_rounded,
                tooltip: weekMode ? '下一周' : '下个月',
                onPressed: onNext,
              ),
              Tooltip(
                message: '回到今天',
                child: MobileTextButton(
                  key: const ValueKey<String>('mobile-today'),
                  label: '今天',
                  onPressed: onToday,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: MobileMetrics.minTapTarget,
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: Text(
                    _subtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ),
              ),
              if (onToggleMode != null)
                MobileTextButton(
                  key: const ValueKey<String>('mobile-calendar-mode'),
                  label: weekMode ? '展开整月' : '收起为周历',
                  onPressed: onToggleMode,
                ),
              _CloudStatusButton(onPressed: onOpenCloud),
            ],
          ),
        ),
      ],
    );
  }

  String _subtitle() {
    if (weekMode) {
      final weekStart = shell.selectedDate.startOfWeek(
        weekStart: kCalendarWeekStart,
      );
      final weekEnd = weekStart.addDays(6);
      return '${weekStart.month}/${weekStart.day} – '
          '${weekEnd.month}/${weekEnd.day}';
    }
    return monthDayWithWeekday(shell.today);
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
