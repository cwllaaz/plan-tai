import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../theme/mobile_metrics.dart';

/// 触摸尺寸的图标按钮（48dp 命中区，Material 默认 32dp 偏小）。
class MobileIconButton extends StatelessWidget {
  const MobileIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.iconSize = 22,
    this.active = false,
    this.semanticLabel,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double iconSize;
  final bool active;

  /// 无障碍标签；为 null 时用 [tooltip]。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tint = onPressed == null
        ? AppColors.textDisabled
        : (color ?? AppColors.textSecondary);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: iconSize, color: active ? AppColors.accent : tint),
      style: IconButton.styleFrom(
        minimumSize: const Size.square(MobileMetrics.minTapTarget),
        maximumSize: const Size.square(MobileMetrics.minTapTarget),
        padding: EdgeInsets.zero,
        backgroundColor: active ? AppColors.accentSoft : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    );
  }
}

/// 触摸尺寸的文字按钮。
class MobileTextButton extends StatelessWidget {
  const MobileTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final foreground = danger ? AppColors.danger : AppColors.accent;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: const Size(0, MobileMetrics.minTapTarget),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        textStyle: AppText.bodyStrong.copyWith(fontSize: 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(label),
        ],
      ),
    );
  }
}

/// 主操作按钮（高度 48，圆角 8）。
class MobilePrimaryButton extends StatelessWidget {
  const MobilePrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.danger = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool danger;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton(
      onPressed: loading ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: danger ? AppColors.danger : AppColors.accent,
        minimumSize: const Size(0, MobileMetrics.minTapTarget),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        textStyle: AppText.bodyStrong.copyWith(
          fontSize: 14,
          color: AppColors.textInverse,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null && !loading) ...<Widget>[
            Icon(icon, size: 18),
            const SizedBox(width: AppSpacing.xs + 2),
          ],
          if (loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textInverse,
              ),
            ),
          if (loading) const SizedBox(width: AppSpacing.sm),
          Text(label),
        ],
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 次级按钮（描边，高度 48）。
class MobileSecondaryButton extends StatelessWidget {
  const MobileSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: danger ? AppColors.danger : AppColors.textPrimary,
        side: BorderSide(color: danger ? AppColors.danger : AppColors.border),
        minimumSize: const Size(0, MobileMetrics.minTapTarget),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        textStyle: AppText.bodyStrong.copyWith(fontSize: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 18),
            const SizedBox(width: AppSpacing.xs + 2),
          ],
          Text(label),
        ],
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 白色卡片：1px 边框 + 8 圆角（移动端主要的分组容器）。
class MobileCard extends StatelessWidget {
  const MobileCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.onTap,
    this.onLongPress,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Material(
      color: color ?? AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// 区块标题行：标题 + 可选说明 + 右侧动作。
class MobileSectionHeader extends StatelessWidget {
  const MobileSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(title, style: AppText.h2.copyWith(fontSize: 15)),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 通用列表行（≥56dp 高，整行可点）。
class MobileListTile extends StatelessWidget {
  const MobileListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.dense = false,
    this.titleColor,
    this.strikethrough = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool dense;
  final Color? titleColor;
  final bool strikethrough;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: dense ? 48 : MobileMetrics.listRowMinHeight,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: dense ? AppSpacing.xs : AppSpacing.sm + 2,
          ),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong.copyWith(
                        fontSize: 14,
                        color: titleColor ?? AppColors.textPrimary,
                        decoration: strikethrough
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态：一句说明 + 主操作（不显示错误语气）。
class MobileEmptyState extends StatelessWidget {
  const MobileEmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.event_note_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl,
          vertical: AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.surfaceSunken,
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: Icon(icon, size: 26, color: AppColors.textTertiary),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.bodyStrong.copyWith(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(fontSize: 12.5),
              ),
            ],
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              MobilePrimaryButton(
                label: actionLabel!,
                onPressed: onAction,
                icon: Icons.add_rounded,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 项目颜色圆点。
class ProjectColorDot extends StatelessWidget {
  const ProjectColorDot({super.key, required this.color, this.size = 10});

  final ProjectColor? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: MobilePalette.projectDot(color),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 优先级标记（低/普通/高/紧急）。
class PriorityBadge extends StatelessWidget {
  const PriorityBadge({super.key, required this.priority, this.compact = true});

  final TaskPriority priority;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (priority == TaskPriority.normal && compact) {
      return const SizedBox.shrink();
    }
    final color = switch (priority) {
      TaskPriority.low => AppColors.textTertiary,
      TaskPriority.normal => AppColors.textSecondary,
      TaskPriority.high => AppColors.warning,
      TaskPriority.urgent => AppColors.danger,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.12),
          AppColors.surface,
        ),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        priority.label,
        style: AppText.micro.copyWith(
          fontSize: 10.5,
          height: 1.2,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 标签胶囊（项目 / 安排 / 状态）。
class MobileTag extends StatelessWidget {
  const MobileTag({
    super.key,
    required this.label,
    this.color = AppColors.textSecondary,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.1),
          AppColors.surface,
        ),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.micro.copyWith(
              fontSize: 11,
              height: 1.3,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 完成率条：细进度条 + 百分比（当天任务完成率）。
class CompletionBar extends StatelessWidget {
  const CompletionBar({
    super.key,
    required this.done,
    required this.total,
    this.showLabel = true,
  });

  final int done;
  final int total;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : done / total;
    final percent = (ratio * 100).round();
    final allDone = total > 0 && done == total;
    return Row(
      children: <Widget>[
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: AppColors.surfaceSunken,
              valueColor: AlwaysStoppedAnimation<Color>(
                allDone ? AppColors.success : AppColors.accent,
              ),
            ),
          ),
        ),
        if (showLabel) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          Text(
            total == 0 ? '—' : '$percent%',
            style: AppText.numeric.copyWith(
              fontSize: 12,
              color: allDone ? AppColors.success : AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// 表单/弹层的错误文案（就地展示，不用全局 SnackBar 代替字段错误）。
class MobileFormError extends StatelessWidget {
  const MobileFormError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: AppColors.danger,
          ),
          const SizedBox(width: AppSpacing.xs + 2),
          Expanded(
            child: Text(
              message,
              style: AppText.small.copyWith(
                fontSize: 12.5,
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部面板的标题区：拖拽把手 + 标题 + 关闭。
class MobileSheetHeader extends StatelessWidget {
  const MobileSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: AppSpacing.sm),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.borderStrong,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.xs,
            0,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(title, style: AppText.h2.copyWith(fontSize: 16)),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(fontSize: 12),
                      ),
                  ],
                ),
              ),
              ?trailing,
              if (onClose != null)
                MobileIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  onPressed: onClose,
                )
              else
                const SizedBox(width: AppSpacing.sm),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// 底部面板里的滚动表单容器。
///
/// 键盘避让由 [showMobileSheet] 在外层统一处理（整块面板上移），这里只负责滚动，
/// 避免两层同时加 `viewInsets` 造成重复位移。
class MobileSheetBody extends StatelessWidget {
  const MobileSheetBody({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.lg,
      AppSpacing.lg,
      AppSpacing.lg,
    ),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: padding,
      child: child,
    );
  }
}

/// 触摸尺寸的开关行。
class MobileSwitchRow extends StatelessWidget {
  const MobileSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled && onChanged != null ? () => onChanged!(!value) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: MobileMetrics.listRowMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: AppText.bodyStrong.copyWith(fontSize: 14),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: AppText.caption.copyWith(fontSize: 12),
                      ),
                  ],
                ),
              ),
              Switch(value: value, onChanged: enabled ? onChanged : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏页标题栏（项目详情、云账号、数据与备份等）。
class MobilePageHeader extends StatelessWidget {
  const MobilePageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              key: const ValueKey<String>('mobile-page-back'),
              tooltip: '返回',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(48),
                maximumSize: const Size.square(48),
                padding: EdgeInsets.zero,
              ),
            )
          else
            const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.h2.copyWith(fontSize: 17),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(fontSize: 11.5),
                  ),
              ],
            ),
          ),
          ...actions,
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
    );
  }
}
