import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../../cloud_account/cloud_account.dart';
import '../../cloud_account/ui/cloud_widgets.dart';
import 'mobile_cloud_account_page.dart';
import 'mobile_cloud_keys.dart';

/// 同步状态入口按钮：顶栏/设置页放一个，点击打开账号与同步页。
///
/// [showLabel] = false（默认）时只显示图标 + 状态角标，适合手机顶栏；
/// = true 时附带简短文案（平板/设置页使用）。
class MobileCloudEntryButton extends StatelessWidget {
  const MobileCloudEntryButton({
    super.key,
    required this.controller,
    this.showLabel = false,
  });

  final CloudAccountController controller;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final descriptor = describeCloudStatus(controller);
        final colors = cloudToneColors(descriptor.tone);
        final attention =
            descriptor.tone == CloudStatusTone.warning ||
            descriptor.tone == CloudStatusTone.danger;
        final button = IconButton(
          key: MobileCloudKeys.entryButton,
          tooltip: descriptor.tooltip ?? descriptor.label,
          onPressed: () => openMobileCloudAccount(context, controller),
          icon: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Icon(
                descriptor.icon,
                size: AppSizes.iconMd,
                color: attention ? colors.foreground : AppColors.textSecondary,
              ),
              if (attention)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: colors.foreground,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.surface, width: 1),
                    ),
                  ),
                ),
            ],
          ),
        );
        if (!showLabel) return button;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            button,
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                descriptor.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
