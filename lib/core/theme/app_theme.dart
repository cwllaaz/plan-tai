import 'package:material_ui/material_ui.dart';

import '../models/project_color.dart';
import 'tokens.dart';

/// 全局主题装配。
///
/// 只做三件事：注入语义色、统一字体层级、把 Material 组件调成"克制"的默认外观
/// （无涟漪、1px 边框、6–10px 圆角）。组件里不要再写死色值，一律用
/// `Theme.of(context)` 或 [AppColors]。
ThemeData buildAppTheme() {
  final colorScheme = const ColorScheme.light(
    primary: AppColors.accent,
    onPrimary: AppColors.textInverse,
    primaryContainer: AppColors.accentSoft,
    onPrimaryContainer: AppColors.accent,
    secondary: AppColors.accent,
    onSecondary: AppColors.textInverse,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    error: AppColors.danger,
    onError: AppColors.textInverse,
    outline: AppColors.border,
    outlineVariant: AppColors.borderStrong,
  ).copyWith(surfaceTint: Colors.transparent);

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.canvas,
    canvasColor: AppColors.surface,
    fontFamily: AppText.fontFamily,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: AppColors.surfaceHover,
  );

  const buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.sm)),
  );

  return base.copyWith(
    textTheme: AppText.textTheme,
    primaryColor: AppColors.accent,
    dividerColor: AppColors.border,
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(
      color: AppColors.textSecondary,
      size: AppSizes.iconMd,
    ),
    primaryIconTheme: const IconThemeData(
      color: AppColors.textSecondary,
      size: AppSizes.iconMd,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.xs)),
      ),
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.borderStrong,
          width: 1.2,
        ),
      ),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.accent
            : Colors.transparent,
      ),
      checkColor: const WidgetStatePropertyAll<Color>(AppColors.textInverse),
      overlayColor: const WidgetStatePropertyAll<Color>(AppColors.accentSoft),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll<Color>(AppColors.accent),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? AppColors.accentSoft
              : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        textStyle: const WidgetStatePropertyAll<TextStyle>(AppText.bodyStrong),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 32)),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(buttonShape),
        animationDuration: AppMotion.hover,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? AppColors.accentHover
              : AppColors.accent,
        ),
        foregroundColor: const WidgetStatePropertyAll<Color>(
          AppColors.textInverse,
        ),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        elevation: const WidgetStatePropertyAll<double>(0),
        textStyle: const WidgetStatePropertyAll<TextStyle>(
          TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            fontFamilyFallback: AppText.fontFamilyFallback,
          ),
        ),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 34)),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(buttonShape),
        animationDuration: AppMotion.hover,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll<Color>(
          AppColors.textPrimary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? AppColors.surfaceHover
              : Colors.transparent,
        ),
        side: const WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: AppColors.border, width: 1),
        ),
        textStyle: const WidgetStatePropertyAll<TextStyle>(AppText.body),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 34)),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(buttonShape),
        animationDuration: AppMotion.hover,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll<Color>(
          AppColors.textSecondary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? AppColors.surfaceSunken
              : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        iconSize: const WidgetStatePropertyAll<double>(AppSizes.iconMd),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(32, 32)),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.all(AppSpacing.xs),
        ),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(buttonShape),
        animationDuration: AppMotion.hover,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceSunken,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + AppSpacing.xxs,
      ),
      hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
      border: OutlineInputBorder(
        borderRadius: AppRadius.control,
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.control,
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadius.control,
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppRadius.control,
        borderSide: const BorderSide(color: AppColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppRadius.control,
        borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.panel),
      titleTextStyle: AppText.h2,
      contentTextStyle: AppText.body.copyWith(fontSize: 13),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      showDuration: const Duration(seconds: 6),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs + AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: AppColors.textPrimary,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      textStyle: const TextStyle(
        fontSize: 12,
        height: 1.4,
        color: AppColors.textInverse,
        fontFamilyFallback: AppText.fontFamilyFallback,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll<double>(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? const Color(0x8B8B94A3)
            : const Color(0x4D8B94A3),
      ),
      crossAxisMargin: 2,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.textPrimary,
      contentTextStyle: const TextStyle(
        fontSize: 13,
        color: AppColors.textInverse,
        fontFamilyFallback: AppText.fontFamilyFallback,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      elevation: 0,
    ),
  );
}

/// 项目色 → Flutter 颜色的唯一转换点。
extension ProjectColorToUi on ProjectColor {
  Color get uiColor => Color(0xFF000000 | rgb);
}
