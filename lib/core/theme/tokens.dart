import 'package:material_ui/material_ui.dart';

/// 设计令牌（V1 定版）。
///
/// 数值来自 docs/01 §2.8 与 docs/UI_SPEC.md，语义命名（canvas / surface / border /
/// text-secondary / accent）而不是"第几号灰"，这样 V1.5 加暗色主题只需换这里的值。
///
/// **本文件由维护者维护**，三个 Agent 不得私自定义新色值；缺令牌请提需求。
abstract final class AppColors {
  // 背景与表面
  static const Color canvas = Color(0xFFF7F8FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSunken = Color(0xFFF2F4F7);
  static const Color surfaceHover = Color(0xFFF5F7FA);

  // 边框
  static const Color border = Color(0xFFE6E8EB);
  static const Color borderStrong = Color(0xFFD3D7DD);

  // 文字
  static const Color textPrimary = Color(0xFF171A1F);
  static const Color textSecondary = Color(0xFF5B6472);
  static const Color textTertiary = Color(0xFF8B94A3);
  static const Color textDisabled = Color(0xFFB4BBC6);
  static const Color textInverse = Color(0xFFFFFFFF);

  // 主色
  static const Color accent = Color(0xFF3E63DD);
  static const Color accentHover = Color(0xFF3454C4);
  static const Color accentSoft = Color(0xFFE8EDFB);
  static const Color accentBorder = Color(0xFFC9D5F8);

  // 语义色
  static const Color success = Color(0xFF30A46C);
  static const Color successSoft = Color(0xFFE7F6ED);
  static const Color warning = Color(0xFFF5A524);
  static const Color warningSoft = Color(0xFFFDF3E0);
  static const Color danger = Color(0xFFE5484D);
  static const Color dangerSoft = Color(0xFFFCEBEC);

  // 今天格子的极淡底色
  static const Color todaySoft = Color(0xFFF0F4FE);

  static const Color overlay = Color(0x0F171A1F); // 6% 墨色，浮层遮罩
  static const Color scrim = Color(0x33171A1F);
}

/// 间距一律取 4 的倍数。
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

/// 圆角：控件 6 / 卡片 8 / 面板 10。
abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 10;
  static const double xl = 14;
  static const double pill = 999;

  static BorderRadius get control => BorderRadius.circular(sm);
  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get panel => BorderRadius.circular(lg);
}

/// 布局尺寸（逻辑像素）。窗口最小 1100×700。
abstract final class AppSizes {
  static const double sidebarWidth = 224;
  static const double sidebarCollapsedWidth = 56;
  static const double topBarHeight = 56;
  static const double drawerWidth = 420;
  static const double drawerMinWidth = 360;
  static const double drawerMaxWidth = 480;
  static const double monthCellMinHeight = 96;
  static const double monthCellPadding = 6;
  static const double titleBarHeight = 48;
  static const double minWindowWidth = 1100;
  static const double minWindowHeight = 700;
  static const double contentMaxWidth = 1440;
  static const double iconSm = 16;
  static const double iconMd = 20;
}

/// 字体与字号层级：11 / 12 / 13 / 14 / 16 / 20 / 24。
abstract final class AppText {
  static const String fontFamily = 'Microsoft YaHei UI';

  static const List<String> fontFamilyFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans SC',
    // Ubuntu/Debian 上 CJK 字体常见族名是 “Noto Sans CJK SC”（fonts-noto-cjk），
    // 与 “Noto Sans SC” 不是同一个族名；补进回退链，Windows 上没有该族会自动跳过。
    'Noto Sans CJK SC',
    'Noto Sans CJK',
    'Source Han Sans SC',
    'Segoe UI',
  ];

  /// 数字开启等宽数字，避免时间列抖动。
  static const List<FontFeature> tabularFigures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static const TextStyle display = TextStyle(
    fontSize: 24,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    letterSpacing: -0.3,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle h1 = TextStyle(
    fontSize: 20,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle h2 = TextStyle(
    fontSize: 16,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.45,
    color: AppColors.textSecondary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle small = TextStyle(
    fontSize: 13,
    height: 1.45,
    color: AppColors.textSecondary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.4,
    color: AppColors.textTertiary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle micro = TextStyle(
    fontSize: 11,
    height: 1.35,
    color: AppColors.textTertiary,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle numeric = TextStyle(
    fontSize: 13,
    height: 1.3,
    color: AppColors.textSecondary,
    fontFeatures: tabularFigures,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextStyle numericLarge = TextStyle(
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFeatures: tabularFigures,
    fontFamilyFallback: fontFamilyFallback,
  );

  static const TextTheme textTheme = TextTheme(
    displaySmall: display,
    headlineMedium: h1,
    // M3 的 AlertDialog / Banner 等组件按 headlineSmall 取标题样式；
    // 缺这一项时标题会退回默认样式（实测在弹窗里不可见），这里补成 h2。
    headlineSmall: h2,
    titleLarge: h2,
    titleMedium: bodyStrong,
    titleSmall: bodyStrong,
    bodyLarge: body,
    bodyMedium: body,
    bodySmall: small,
    labelLarge: bodyStrong,
    labelMedium: caption,
    labelSmall: micro,
  );
}

/// 阴影只用于浮层，1px 边框才是主要分隔手段。
abstract final class AppShadows {
  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(color: Color(0x0F101828), blurRadius: 2, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> popover = <BoxShadow>[
    BoxShadow(
      color: Color(0x29101828),
      blurRadius: 32,
      offset: Offset(0, 12),
      spreadRadius: -8,
    ),
  ];
}

/// 动效时长与曲线，统一 easeOutCubic。
abstract final class AppMotion {
  static const Duration hover = Duration(milliseconds: 120);
  static const Duration drawer = Duration(milliseconds: 200);
  static const Duration month = Duration(milliseconds: 180);
  static const Curve curve = Curves.easeOutCubic;
}
