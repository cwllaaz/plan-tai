import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/theme/theme.dart';

/// 月历模块内部的尺寸与配色推导。
///
/// 这里只允许**派生**令牌：底色、边框、字号全部来自 [AppColors] / [AppText]，
/// 项目色一律从 [ProjectColor] 推导（不写死十六进制），
/// 这样 V1.5 换暗色主题时只改 `tokens.dart` 即可。
abstract final class CalendarMetrics {
  /// 月历头（"月历 + 统计 + 图例"）高度。
  static const double headerHeight = 38;

  /// 星期表头高度。
  static const double weekdayHeaderHeight = 30;

  /// 格子最小/最大高度：窗口小到放不下时整块纵向滚动，不允许 7 列横向滚动。
  static const double minRowHeight = 96;
  static const double maxRowHeight = 260;

  /// 格子内边距（UI_SPEC §3：6）。
  static const double cellPadding = AppSizes.monthCellPadding;

  /// 日期行与日期徽标。
  static const double dateRowHeight = 22;
  static const double dateBadgeSize = 22;

  /// 跨天条：车道高、车道间距、日期行与车道之间的间距。
  static const double laneHeight = 18;
  static const double laneGap = 3;
  static const double laneTopGap = 3;
  static const int maxLanes = 2;

  /// 跨天条：圆角、左侧项目色竖条、真实起点/终点处的横向内缩。
  static const double spanRadius = 5;
  static const double spanStripeWidth = 3;
  static const double spanEdgeInset = 4;

  /// 任务行。
  static const double taskRowHeight = 17;
  static const double taskDotSize = 5;
  static const double taskTimeWidth = 30;
  static const int maxTasks = 3;

  /// `+N 项` / `+N` 折叠行高度（含一点点上间距）。
  static const double overflowRowHeight = 13;

  /// 格子宽度小于该值时收起任务时间，只留圆点 + 标题。
  static const double compactCellWidth = 108;

  /// 日期行与车道之间、车道与任务之间的总预留高度。
  static double laneBandHeight(int laneCount) =>
      laneCount <= 0 ? 0 : laneCount * laneHeight + (laneCount - 1) * laneGap;

  /// 任务区可用高度。
  static double taskAreaHeight({
    required double rowHeight,
    required int laneCount,
  }) {
    final reservedLanes = laneCount <= 0
        ? 0
        : laneTopGap + laneBandHeight(laneCount) + 2;
    return rowHeight -
        cellPadding * 2 -
        dateRowHeight -
        reservedLanes -
        // 误差余量，避免 RenderFlex 因浮点差溢出 1px。
        1;
  }
}

/// 月历用到的派生色。
abstract final class CalendarPalette {
  /// 非本月格子：极淡的灰底，避免与本月抢注意力。
  static Color get outsideMonth => Color.alphaBlend(
    AppColors.canvas.withValues(alpha: 0.65),
    AppColors.surface,
  );

  /// 选中格：accentSoft 55% 叠白（UI_SPEC §5）。
  static Color get selected => Color.alphaBlend(
    AppColors.accentSoft.withValues(alpha: 0.55),
    AppColors.surface,
  );

  /// 跨天条填充：项目色的低饱和实心。
  static Color spanFill(ProjectColor color) => Color.alphaBlend(
    color.uiColor.withValues(alpha: 0.13),
    AppColors.surface,
  );

  /// 跨天条 hover 填充。
  static Color spanFillHover(ProjectColor color) => Color.alphaBlend(
    color.uiColor.withValues(alpha: 0.19),
    AppColors.surface,
  );

  /// 跨天条文字：项目色压深、混入墨色保证对比度（≥ 4.5:1）。
  static Color spanInk(ProjectColor color) => Color.alphaBlend(
    color.uiColor.withValues(alpha: 0.45),
    AppColors.textPrimary,
  );

  /// 跨天条左侧项目色竖条。
  static Color spanStripe(ProjectColor color) => color.uiColor;

  /// 任务项目圆点。
  static Color taskDot(ProjectColor? color) =>
      color?.uiColor ?? AppColors.textDisabled;

  /// 已完成任务的文字。
  static Color taskDoneInk(bool inMonth) =>
      inMonth ? AppColors.textTertiary : AppColors.textDisabled;

  /// 任务时间文字。
  static Color taskTimeInk(bool inMonth) =>
      inMonth ? AppColors.textTertiary : AppColors.textDisabled;
}
