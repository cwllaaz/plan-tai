import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import 'connected_view.dart';
import 'sign_in_view.dart';

/// 云端账号面板（右侧抽屉内容）。
///
/// 宽度默认 [AppSizes.drawerWidth]（420），与每日面板一致；只占右侧，不重排月历。
/// 未登录展示登录表单；已登录展示账号 / 同步状态 / 本机数据。
/// 冲突处理是独立模态页（[showCloudConflictPage]），面板本身不切换布局。
class CloudAccountPanel extends StatelessWidget {
  const CloudAccountPanel({
    super.key,
    required this.controller,
    this.width = AppSizes.drawerWidth,
  });

  final CloudAccountController controller;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        return Container(
          key: const ValueKey<String>('cloud-account-panel'),
          width: width,
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(left: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelHeader(controller: controller),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.xl,
                  ),
                  child: controller.isSignedIn
                      ? CloudConnectedView(controller: controller)
                      : CloudSignInView(controller: controller),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.controller});

  final CloudAccountController controller;

  @override
  Widget build(BuildContext context) {
    final signedIn = controller.isSignedIn;
    return Container(
      height: AppSizes.topBarHeight,
      padding: const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.sm),
      child: Row(
        children: <Widget>[
          Icon(
            signedIn ? Icons.cloud_done_outlined : Icons.cloud_outlined,
            size: 18,
            color: signedIn ? AppColors.accent : AppColors.textTertiary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  signedIn ? '云端同步' : '连接云端账号',
                  style: AppText.h2.copyWith(fontSize: 15),
                ),
                Text(
                  signedIn
                      ? (controller.accountLabel.isEmpty
                            ? '账号与同步设置'
                            : controller.accountLabel)
                      : '登录后可在多台设备间同步计划',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('cloud-panel-close'),
            tooltip: '关闭（Esc）',
            onPressed: controller.closePanel,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
