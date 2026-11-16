import 'package:material_ui/material_ui.dart';

import '../core/theme/theme.dart';

/// 弹窗里输入框的统一外观（月历、项目页、设置页共用）。
///
/// 放在独立文件里，避免每个弹窗各写一套 `InputDecoration` 导致高度/圆角不一致。
InputDecoration dialogInputDecoration(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: AppText.caption,
  isDense: true,
  filled: true,
  fillColor: AppColors.surfaceSunken,
  contentPadding: const EdgeInsets.symmetric(
    horizontal: AppSpacing.md,
    vertical: AppSpacing.sm + 2,
  ),
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
);
