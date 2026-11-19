import 'package:material_ui/material_ui.dart';

import '../../core/theme/theme.dart';
import '../theme/mobile_metrics.dart';

/// 打开移动端底部面板（统一键盘避让、最大宽度、圆角与高度比例）。
///
/// - 平板/横屏时面板宽度不超过 [MobileMetrics.sheetMaxWidth] 并居中；
/// - `heightFactor` 默认 0.92，面板内容自己决定「标题 + 滚动区 + 固定操作栏」；
/// - 有键盘时使用键盘上方的全部空间，并统一处理系统底部安全区。
Future<T?> showMobileSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double heightFactor = MobileMetrics.daySheetHeightFactor,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    backgroundColor: AppColors.surface,
    constraints: const BoxConstraints(maxWidth: MobileMetrics.sheetMaxWidth),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (BuildContext sheetContext) {
      final isCurrent = ModalRoute.isCurrentOf(sheetContext) ?? true;
      // 上层表单的键盘不应改变底下日面板的高度和列表位置。
      final insets = isCurrent
          ? MediaQuery.viewInsetsOf(sheetContext).bottom
          : 0.0;
      return Padding(
        padding: EdgeInsets.only(bottom: insets),
        child: FractionallySizedBox(
          heightFactor: insets == 0 ? heightFactor : 1,
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            maintainBottomViewPadding: !isCurrent,
            child: Builder(builder: builder),
          ),
        ),
      );
    },
  );
}

/// 移动端二次确认。危险操作按钮用 [danger] 着色。
Future<bool> showMobileConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, MobileMetrics.minTapTarget),
            foregroundColor: AppColors.textSecondary,
          ),
          child: Text(cancelLabel),
        ),
        FilledButton(
          key: const ValueKey<String>('mobile-confirm-ok'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: danger ? AppColors.danger : AppColors.accent,
            minimumSize: const Size(0, MobileMetrics.minTapTarget),
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 轻量结果提示（跨页面操作结果用 SnackBar）。
void showMobileSnack(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  bool error = false,
  Duration duration = const Duration(seconds: 3),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      backgroundColor: error ? AppColors.danger : AppColors.textPrimary,
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(
              label: actionLabel,
              textColor: AppColors.accentBorder,
              onPressed: onAction,
            ),
    ),
  );
}

/// 底部面板的固定操作栏（保存 / 取消），始终贴在面板底部。
class MobileSheetFooter extends StatelessWidget {
  const MobileSheetFooter({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm + 2,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: children,
        ),
      ),
    );
  }
}
