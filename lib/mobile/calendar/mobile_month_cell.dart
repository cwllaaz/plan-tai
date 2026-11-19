import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../theme/mobile_metrics.dart';

/// 手机/平板月历里的单个日期格。
///
/// 格子内信息克制：日期数字（今天/选中高亮）+ 任务项目圆点（最多 2 个）+ `+N` 计数。
/// 跨天安排横条不在这里画，由 `MobileMonthGrid` 在整行上覆盖，保证跨格连续。
class MobileMonthCell extends StatelessWidget {
  const MobileMonthCell({
    super.key,
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.isWeekend,
    required this.rowHeight,
    required this.tasks,
    required this.projects,
    required this.onTap,
    required this.onDoubleTap,
    this.showBorderRight = true,
    this.showBorderBottom = true,
  });

  final LocalDate date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool isWeekend;
  final double rowHeight;

  /// 当天的任务（仓储顺序）。
  final List<PlannerTask> tasks;

  /// 项目 id → 项目，用于取任务项目色。
  final Map<String, Project> projects;

  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final bool showBorderRight;
  final bool showBorderBottom;

  /// 最多画几个任务圆点，其余折叠成 `+N`。
  static const int maxDots = 2;

  // 跨天横条从日期区下方起画，避免放大字体时盖住日期。
  static double dateBandHeight(BuildContext context) =>
      8 + MediaQuery.textScalerOf(context).scale(13) * 1.2;

  static const double spanTitleSize = 11;
  static const double spanLaneGap = 2;

  static double spanLaneHeight(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(spanTitleSize) * 1.2 + 3)
          .ceilToDouble();

  static double minimumHeight(BuildContext context, {int spanLanes = 1}) =>
      (dateBandHeight(context) +
              spanLanes * spanLaneHeight(context) +
              (spanLanes - 1) * spanLaneGap +
              _dotHeight +
              4)
          .clamp(MobileMetrics.minMonthRowHeight, double.infinity);

  static const double _dotHeight = 12;

  @override
  Widget build(BuildContext context) {
    final background = _background();
    final canShowDots = rowHeight + 0.01 >= minimumHeight(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Semantics(
        button: true,
        selected: isSelected,
        label: _semanticLabel(),
        child: Container(
          height: rowHeight,
          decoration: BoxDecoration(
            color: background,
            border: Border(
              right: showBorderRight
                  ? const BorderSide(color: AppColors.border)
                  : BorderSide.none,
              bottom: showBorderBottom
                  ? const BorderSide(color: AppColors.border)
                  : BorderSide.none,
            ),
          ),
          child: Stack(
            children: <Widget>[
              if (isSelected)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: AppColors.accent),
                ),
              if (isToday)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      dayNumber(date),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: AppText.numeric.copyWith(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: isToday || isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: _ink(),
                        fontFeatures: AppText.tabularFigures,
                      ),
                    ),
                    const Spacer(),
                    if (canShowDots && tasks.isNotEmpty) _buildDots(_dotHeight),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color? _background() {
    if (isSelected) return AppColors.accentSoft;
    if (isToday) return AppColors.todaySoft;
    if (!inMonth) {
      return Color.alphaBlend(
        AppColors.canvas.withValues(alpha: 0.65),
        AppColors.surface,
      );
    }
    if (isWeekend) {
      return Color.alphaBlend(
        AppColors.canvas.withValues(alpha: 0.45),
        AppColors.surface,
      );
    }
    return null;
  }

  Color _ink() {
    if (isToday || isSelected) return AppColors.accent;
    if (!inMonth) return AppColors.textDisabled;
    return AppColors.textPrimary;
  }

  Widget _buildDots(double height) {
    final visible = tasks.take(maxDots).toList(growable: false);
    final hidden = tasks.length - visible.length;
    return SizedBox(
      height: height,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var index = 0; index < visible.length; index++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: MobilePalette.projectDot(_colorOf(visible[index]))
                          .withValues(alpha: visible[index].isDone ? 0.35 : 1),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 1),
                  child: Text(
                    '+$hidden',
                    style: AppText.micro.copyWith(
                      fontSize: 10,
                      height: 1,
                      color: inMonth
                          ? AppColors.textSecondary
                          : AppColors.textDisabled,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  ProjectColor? _colorOf(PlannerTask task) {
    final projectId = task.projectId;
    if (projectId == null) return null;
    return projects[projectId]?.color;
  }

  String _semanticLabel() {
    final buffer = StringBuffer(monthDayWithWeekday(date));
    if (!inMonth) buffer.write('，非本月');
    if (isToday) buffer.write('，今天');
    if (isSelected) buffer.write('，已选中');
    if (tasks.isNotEmpty) buffer.write('，${tasks.length} 项任务');
    return buffer.toString();
  }
}
