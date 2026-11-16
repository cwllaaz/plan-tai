import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/theme/theme.dart';

/// 移动端布局档位：按**内容区可用宽度**判断，不按设备类型。
///
/// 与 `docs/android/UI_SPEC.md` §3 一致：
/// - `compact`（< 600dp）：手机竖屏，单列 + 底部导航；
/// - `medium`（600–839dp）：大手机 / 折叠屏 / 竖屏平板，月历与当日列表上下排布；
/// - `expanded`（≥ 840dp）：平板横屏，项目导航 + 月历 + 右侧当日面板三栏。
enum MobileLayout { compact, medium, expanded }

/// 宽度 → 布局档位。
///
/// [availableHeight] 传入时额外做一条保护：横屏手机（高度很小）即使宽度达到
/// 平板断点，也不使用三栏布局，避免三栏在 400dp 高度里挤成一团。
MobileLayout mobileLayoutFor(double width, {double? availableHeight}) {
  final tallEnough = availableHeight == null || availableHeight >= 520;
  if (width >= MobileBreakpoints.expanded && tallEnough) {
    return MobileLayout.expanded;
  }
  if (width >= MobileBreakpoints.medium) return MobileLayout.medium;
  return MobileLayout.compact;
}

abstract final class MobileBreakpoints {
  /// ≥ 该宽度视为平板横屏三栏布局。
  static const double expanded = 840;

  /// ≥ 该宽度起使用 NavigationRail 而不是底部导航。
  static const double medium = 600;
}

/// 触摸优先的尺寸常量。
///
/// 全部复用 `AppSpacing` / `AppRadius` / `AppText` 令牌，只补移动端需要的触摸尺寸。
abstract final class MobileMetrics {
  /// 可点击目标最小边长（Material / Android 无障碍指南）。
  static const double minTapTarget = 48;

  /// 底部导航栏高度（不含系统栏安全区）。
  static const double bottomNavHeight = 56;

  /// 平板左侧导航栏宽度（图标 + 文字）。
  static const double navRailWidth = 84;

  /// 平板三栏布局里项目导航栏宽度。
  static const double projectNavWidth = 216;

  /// 平板三栏布局里右侧当日面板宽度。
  static const double dayPanelWidth = 360;

  /// 页面左右内边距：手机 16，平板 20。
  static const double pagePadding = AppSpacing.lg;
  static const double pagePaddingWide = AppSpacing.xl;

  /// 顶栏高度。
  static const double topBarHeight = 56;

  /// 星期表头高度。
  static const double weekdayHeaderHeight = 30;

  /// 月历一行格子最小 / 最大高度。
  static const double minMonthRowHeight = 44;
  static const double maxMonthRowHeight = 132;

  /// 任务行最小高度。
  static const double taskRowMinHeight = 56;

  /// 列表行最小高度。
  static const double listRowMinHeight = 56;

  /// 底部面板 / 编辑表单的最大宽度（平板居中，不铺满整屏）。
  static const double sheetMaxWidth = 560;

  /// 底部面板占屏幕高度的比例。
  static const double daySheetHeightFactor = 0.92;
  static const double editorSheetHeightFactor = 0.92;

  /// 返回顶端对齐的日期选择器间距。
  static const EdgeInsets pageInsets = EdgeInsets.symmetric(
    horizontal: pagePadding,
  );
}

/// 移动端派生色：只从 [AppColors] 组合，不新增色值。
abstract final class MobilePalette {
  /// 底部导航 / 侧栏未选中项。
  static Color get navIdle => AppColors.textTertiary;

  /// 导航选中底色。
  static Color get navSelectedBackground => AppColors.accentSoft;

  /// 底部面板遮罩，与桌面浮层一致。
  static Color get sheetScrim => AppColors.scrim;

  /// 月历格子内非本月日期文字。
  static Color get outsideMonthInk => AppColors.textDisabled;

  /// 跨天条填充（沿用桌面推导规则）。
  static Color spanFill(ProjectColor color) => Color.alphaBlend(
    color.uiColor.withValues(alpha: 0.13),
    AppColors.surface,
  );

  /// 跨天条文字色。
  static Color spanInk(ProjectColor color) => Color.alphaBlend(
    color.uiColor.withValues(alpha: 0.45),
    AppColors.textPrimary,
  );

  /// 项目圆点；没有项目时用中性灰。
  static Color projectDot(ProjectColor? color) =>
      color?.uiColor ?? AppColors.textDisabled;

  /// 选中日期格背景。
  static Color get selectedDay => AppColors.accentSoft;

  /// 今天格背景。
  static Color get todayDay => AppColors.todaySoft;
}
