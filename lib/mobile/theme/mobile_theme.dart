import 'package:material_ui/material_ui.dart';

import '../../core/theme/theme.dart';

/// 移动端主题：在共享主题（颜色/圆角/组件外观）之上，显式把中文字体族写进
/// 文本样式。
///
/// 桌面端依赖 Windows 系统字体回退即可显示中文；Android 上字体由系统解析，
/// 显式指定 `Microsoft YaHei UI → Noto Sans SC → 系统默认` 的族链更可控，
/// 也保证 widget 测试 / 截图使用同一套字体解析规则。
ThemeData buildMobileAppTheme() {
  final base = buildAppTheme();
  TextTheme applyFamily(TextTheme theme) => theme.apply(
    fontFamily: AppText.fontFamily,
    fontFamilyFallback: AppText.fontFamilyFallback,
  );
  return base.copyWith(
    textTheme: applyFamily(base.textTheme),
    primaryTextTheme: applyFamily(base.primaryTextTheme),
  );
}
