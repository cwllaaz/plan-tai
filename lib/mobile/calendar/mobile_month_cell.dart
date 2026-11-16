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

  @override
  Widget build(BuildContext context) {
    final background = _background();
    final textScaler = MediaQuery.textScalerOf(context);
    // 字体放大时压缩文字层级，仍然只显示日期数字，避免撑破格子。
    final scaleFactor = textScaler.scale(13) / 13;
    final canShowDots = rowHeight >= 42 && scaleFactor <= 1.35;
    final canShowDotOverflow = rowHeight >= 40;

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
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 2, 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
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
                    if (canShowDots) _buildDots(canShowDotOverflow),
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
    if (!inMonth) return AppColors.textDisabled;
    if (isToday) return AppColors.accent;
    if (isSelected) return AppColors.accent;
    return AppColors.textPrimary;
  }

  Widget _buildDots(bool showOverflow) {
    if (tasks.isEmpty) return const SizedBox(height: 10);
    final visible = tasks.take(maxDots).toList(growable: false);
    final hidden = tasks.length - visible.length;
    return SizedBox(
      height: 10,
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
              if (hidden > 0 && showOverflow)
                Padding(
                  padding: const EdgeInsets.only(left: 1),
                  child: Text(
                    '+$hidden',
                    style: AppText.micro.copyWith(
                      fontSize: 9,
                      height: 1,
                      color: inMonth
                          ? AppColors.textTertiary
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
