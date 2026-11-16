import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';

/// 云同步面板的共享小部件。
///
/// 视觉规则与计划台 V1 一致：白底 + 1px 边框、6/8/10 圆角、4 的倍数间距、
/// 正文走 [AppText] 层级。这里不引入新的色值。

/// 面板里的分组卡片：标题（可选）+ 内容。
class CloudSection extends StatelessWidget {
  const CloudSection({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hasHeader = title != null || trailing != null;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.panel,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.md + AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hasHeader)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title!,
                          style: AppText.bodyStrong.copyWith(fontSize: 13),
                        ),
                        if (subtitle != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.xxs),
                          Text(subtitle!, style: AppText.caption),
                        ],
                      ],
                    ),
                  )
                else
                  const Spacer(),
                ?trailing,
              ],
            ),
          if (hasHeader) const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// 「标签 + 值」一行。标签宽度固定，值可以换行（服务器地址、备份路径会很长）。
class CloudInfoRow extends StatelessWidget {
  const CloudInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.valueKey,
    this.trailing,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final Key? valueKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: valueKey,
              style: AppText.small.copyWith(
                color: valueColor ?? AppColors.textSecondary,
              ),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: AppSpacing.xs),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 提示条：成功 / 失败 / 离线 / 冲突都用它，颜色只用来强调，不改变布局。
enum CloudBannerTone { info, success, warning, danger }

class CloudBanner extends StatelessWidget {
  const CloudBanner({
    super.key,
    required this.tone,
    required this.title,
    this.message,
    this.hint,
    this.action,
    this.onDismiss,
  });

  final CloudBannerTone tone;
  final String title;
  final String? message;
  final String? hint;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = cloudBannerColors(tone);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: AppRadius.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm + AppSpacing.xxs,
        AppSpacing.sm,
        AppSpacing.sm + AppSpacing.xxs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(colors.icon, size: AppSizes.iconSm, color: colors.foreground),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: AppText.bodyStrong.copyWith(fontSize: 12.5)),
                if (message != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: AppText.small.copyWith(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                if (hint != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(hint!, style: AppText.caption),
                ],
                if (action != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  action!,
                ],
              ],
            ),
          ),
          if (onDismiss != null)
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                tooltip: '关闭提示',
                padding: EdgeInsets.zero,
                iconSize: 14,
                style: IconButton.styleFrom(
                  minimumSize: const Size(24, 24),
                  padding: EdgeInsets.zero,
                ),
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
        ],
      ),
    );
  }
}

/// 提示条配色（只从现有令牌组合，不新增颜色）。
class CloudBannerColors {
  const CloudBannerColors({
    required this.background,
    required this.border,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final IconData icon;
}

CloudBannerColors cloudBannerColors(CloudBannerTone tone) {
  final base = switch (tone) {
    CloudBannerTone.info => (
      background: AppColors.accentSoft,
      foreground: AppColors.accent,
      icon: Icons.info_outline_rounded,
    ),
    CloudBannerTone.success => (
      background: AppColors.successSoft,
      foreground: AppColors.success,
      icon: Icons.check_circle_outline_rounded,
    ),
    CloudBannerTone.warning => (
      background: AppColors.warningSoft,
      foreground: AppColors.warning,
      icon: Icons.warning_amber_rounded,
    ),
    CloudBannerTone.danger => (
      background: AppColors.dangerSoft,
      foreground: AppColors.danger,
      icon: Icons.error_outline_rounded,
    ),
  };
  return CloudBannerColors(
    background: base.background,
    border: base.foreground.withValues(alpha: 0.28),
    foreground: base.foreground,
    icon: base.icon,
  );
}

/// 带标签的输入区域。
class CloudField extends StatelessWidget {
  const CloudField({
    super.key,
    required this.label,
    required this.child,
    this.caption,
    this.trailing,
  });

  final String label;
  final Widget child;
  final String? caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppText.bodyStrong.copyWith(fontSize: 12.5),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: AppSpacing.sm - AppSpacing.xxs),
        child,
        if (caption != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs + AppSpacing.xxs),
          Text(caption!, style: AppText.caption),
        ],
      ],
    );
  }
}

/// 状态胶囊：圆点 + 图标 + 文案。文案用墨色保证可读，颜色只表达状态。
class CloudStatusPill extends StatelessWidget {
  const CloudStatusPill({
    super.key,
    required this.label,
    required this.tone,
    required this.icon,
    this.busy = false,
  });

  final String label;
  final CloudStatusTone tone;
  final IconData icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = cloudToneColors(tone);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (busy)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: colors.foreground,
              ),
            )
          else
            Icon(icon, size: 13, color: colors.foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppText.small.copyWith(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态色（语义 + 柔和底色）。
enum CloudStatusTone { neutral, accent, success, warning, danger }

class CloudToneColors {
  const CloudToneColors({
    required this.background,
    required this.foreground,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color border;
}

CloudToneColors cloudToneColors(CloudStatusTone tone) {
  return switch (tone) {
    CloudStatusTone.neutral => const CloudToneColors(
      background: AppColors.surfaceSunken,
      foreground: AppColors.textTertiary,
      border: AppColors.border,
    ),
    CloudStatusTone.accent => const CloudToneColors(
      background: AppColors.accentSoft,
      foreground: AppColors.accent,
      border: AppColors.accentBorder,
    ),
    CloudStatusTone.success => CloudToneColors(
      background: AppColors.successSoft,
      foreground: AppColors.success,
      border: AppColors.success.withValues(alpha: 0.28),
    ),
    CloudStatusTone.warning => CloudToneColors(
      background: AppColors.warningSoft,
      foreground: AppColors.warning,
      border: AppColors.warning.withValues(alpha: 0.32),
    ),
    CloudStatusTone.danger => CloudToneColors(
      background: AppColors.dangerSoft,
      foreground: AppColors.danger,
      border: AppColors.danger.withValues(alpha: 0.3),
    ),
  };
}

/// 小号文字按钮（面板内的次要操作）。
class CloudTextAction extends StatelessWidget {
  const CloudTextAction({
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
    final color = danger ? AppColors.danger : AppColors.accent;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        minimumSize: const Size(0, 30),
        textStyle: AppText.small.copyWith(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(label),
        ],
      ),
    );
  }
}

/// 面板内的主操作按钮：整宽、36 高，加载中显示小进度条。
class CloudPrimaryButton extends StatelessWidget {
  const CloudPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? busyLabel;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy)
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: AppColors.textInverse,
                ),
              )
            else if (icon != null)
              Icon(icon, size: 15),
            if (busy || icon != null) const SizedBox(width: AppSpacing.sm),
            Text(busy ? (busyLabel ?? label) : label),
          ],
        ),
      ),
    );
  }
}

/// 面板里的说明文字（比 caption 稍深一点，便于长时间阅读）。
class CloudHintText extends StatelessWidget {
  const CloudHintText(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppText.caption.copyWith(
        fontSize: 11.5,
        height: 1.5,
        color: color ?? AppColors.textTertiary,
      ),
    );
  }
}
