import 'package:material_ui/material_ui.dart';

import '../../core/theme/theme.dart';
import '../../features/cloud_account/cloud_account.dart';

/// 移动端云端状态的统一表达（顶部图标 + 「我的」页文案）。
///
/// 只读取 [CloudAccountController] 的公开状态，不触发任何同步动作；
/// 离线（controller == null）时表达为「离线，云同步未启用」，本地功能不受影响。
final class MobileCloudVisual {
  const MobileCloudVisual({
    required this.icon,
    required this.color,
    required this.label,
    required this.detail,
  });

  final IconData icon;
  final Color color;

  /// 短标签，如「已同步」。
  final String label;

  /// 一句说明，如「离线，改动将在联网后上传」。
  final String detail;

  bool get needsAction => label == '需要处理' || label == '同步出错';
}

/// 根据控制器当前状态推导移动端展示。
MobileCloudVisual mobileCloudVisual(CloudAccountController? controller) {
  if (controller == null) {
    return const MobileCloudVisual(
      icon: Icons.cloud_off_outlined,
      color: AppColors.textTertiary,
      label: '离线',
      detail: '云同步未启用，本地数据照常可用',
    );
  }
  if (!controller.isSignedIn) {
    return const MobileCloudVisual(
      icon: Icons.cloud_off_outlined,
      color: AppColors.textTertiary,
      label: '未登录',
      detail: '登录后可在多台设备间同步计划',
    );
  }
  final phase = controller.syncStatus.phase;
  return switch (phase) {
    SyncPhase.idle => const MobileCloudVisual(
      icon: Icons.cloud_done_outlined,
      color: AppColors.success,
      label: '已同步',
      detail: '本地改动已上传到云端',
    ),
    SyncPhase.syncing => const MobileCloudVisual(
      icon: Icons.sync_rounded,
      color: AppColors.accent,
      label: '同步中…',
      detail: '正在与云端同步，请稍候',
    ),
    SyncPhase.offline => const MobileCloudVisual(
      icon: Icons.cloud_off_outlined,
      color: AppColors.textTertiary,
      label: '离线',
      detail: '离线，改动将在联网后上传',
    ),
    SyncPhase.needsAttention => const MobileCloudVisual(
      icon: Icons.error_outline_rounded,
      color: AppColors.warning,
      label: '需要处理',
      detail: '有冲突或绑定需要确认，点进来看',
    ),
    SyncPhase.error => const MobileCloudVisual(
      icon: Icons.cloud_off_rounded,
      color: AppColors.danger,
      label: '同步出错',
      detail: '上次同步失败，可点进来看原因并重试',
    ),
    SyncPhase.signedOut => const MobileCloudVisual(
      icon: Icons.cloud_off_outlined,
      color: AppColors.textTertiary,
      label: '未登录',
      detail: '登录后可在多台设备间同步计划',
    ),
  };
}
