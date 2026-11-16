import 'package:material_ui/material_ui.dart';

import '../../../core/cloud/cloud.dart';
import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import 'cloud_widgets.dart';

/// 同步状态 → 图标 / 色调 / 文案的唯一映射。
///
/// 优先级：登录状态 → 数据归属 → 同步阶段 → 冲突 → 待上传 → 已同步。
/// 这样「存在冲突」不会被「有 N 项待同步」盖掉，也不会把「离线」显示成「已同步」。
/// 文案对齐 docs/sync/CLIENT_INTERFACE.md §5；`lastError` 只在 error 态展示。
class CloudStatusDescriptor {
  const CloudStatusDescriptor({
    required this.label,
    required this.tone,
    required this.icon,
    this.busy = false,
    this.detail,
    this.tooltip,
  });

  final String label;
  final CloudStatusTone tone;
  final IconData icon;
  final bool busy;

  /// 第二行说明（例如「正在上传 3/12」）。
  final String? detail;

  final String? tooltip;
}

CloudStatusDescriptor describeCloudStatus(CloudAccountController controller) {
  if (!controller.isSignedIn) {
    return const CloudStatusDescriptor(
      label: '未登录',
      tone: CloudStatusTone.neutral,
      icon: Icons.cloud_off_outlined,
      tooltip: '未连接云端账号，数据只保存在本机',
    );
  }

  switch (controller.bindingStage) {
    case CloudBindingStage.needsChoice:
      return const CloudStatusDescriptor(
        label: '待确认关联',
        tone: CloudStatusTone.warning,
        icon: Icons.link_off_rounded,
        detail: '请确认本机数据如何关联到云端账号',
        tooltip: '本机已有数据，需要你确认是否关联到云端账号',
      );
    case CloudBindingStage.checking:
      return const CloudStatusDescriptor(
        label: '正在检查数据',
        tone: CloudStatusTone.accent,
        icon: Icons.sync_rounded,
        busy: true,
      );
    case CloudBindingStage.applying:
      return const CloudStatusDescriptor(
        label: '正在关联',
        tone: CloudStatusTone.accent,
        icon: Icons.sync_rounded,
        busy: true,
      );
    case CloudBindingStage.failed:
      return const CloudStatusDescriptor(
        label: '需要检查数据',
        tone: CloudStatusTone.warning,
        icon: Icons.help_outline_rounded,
        detail: '检查本机数据归属失败，可以重试',
      );
    case CloudBindingStage.skipped:
      return const CloudStatusDescriptor(
        label: '未关联本地数据',
        tone: CloudStatusTone.neutral,
        icon: Icons.link_off_rounded,
        detail: '本机数据不会上传到云端',
      );
    case CloudBindingStage.restartRequired:
      return const CloudStatusDescriptor(
        label: '需要重启应用',
        tone: CloudStatusTone.warning,
        icon: Icons.restart_alt_rounded,
        detail: '数据关联已完成，重启后切换工作区',
      );
    case CloudBindingStage.idle:
    case CloudBindingStage.ready:
      break;
  }

  final status = controller.syncStatus;
  if (status.phase == SyncPhase.syncing) {
    return CloudStatusDescriptor(
      label: '正在同步',
      tone: CloudStatusTone.accent,
      icon: Icons.sync_rounded,
      busy: true,
      detail: status.message,
      tooltip: '正在与云端同步，请稍候',
    );
  }
  if (status.phase == SyncPhase.error) {
    return CloudStatusDescriptor(
      label: '同步失败',
      tone: CloudStatusTone.danger,
      icon: Icons.error_outline_rounded,
      detail: status.lastError ?? '同步失败，可重试',
      tooltip: status.lastError ?? '同步失败，可重试',
    );
  }
  if (status.phase == SyncPhase.offline) {
    return const CloudStatusDescriptor(
      label: '离线',
      tone: CloudStatusTone.neutral,
      icon: Icons.cloud_off_rounded,
      detail: '网络不可用，稍后重试',
      tooltip: '当前离线，改动会保存在本机，联网后自动上传',
    );
  }
  if (status.conflictCount > 0) {
    return CloudStatusDescriptor(
      label: '存在冲突 ${status.conflictCount}',
      tone: CloudStatusTone.warning,
      icon: Icons.warning_amber_rounded,
      detail: status.message ?? '需要你选择保留哪个版本',
      tooltip: '有 ${status.conflictCount} 条冲突需要处理',
    );
  }
  if (status.phase == SyncPhase.needsAttention) {
    return CloudStatusDescriptor(
      label: '需要处理',
      tone: CloudStatusTone.warning,
      icon: Icons.priority_high_rounded,
      detail: status.message,
    );
  }
  if (status.pendingOperations > 0) {
    return CloudStatusDescriptor(
      label: '待同步 ${status.pendingOperations} 项',
      tone: CloudStatusTone.warning,
      icon: Icons.cloud_upload_outlined,
      detail: '改动已保存在本机，等待上传',
      tooltip: '有 ${status.pendingOperations} 项改动还没有上传到云端',
    );
  }
  if (status.lastSyncedAt == null) {
    return const CloudStatusDescriptor(
      label: '尚未同步',
      tone: CloudStatusTone.neutral,
      icon: Icons.cloud_queue_outlined,
      detail: '点击同步上传本机改动',
    );
  }
  return const CloudStatusDescriptor(
    label: '已同步',
    tone: CloudStatusTone.success,
    icon: Icons.cloud_done_outlined,
    detail: '本机与云端一致',
  );
}

/// 顶部入口按钮：未登录也能看到状态；颜色 + 图标 + 文字三重要素。
///
/// [compact] 用于窄窗口（1100 宽时顶栏空间紧张），只显示图标 + 角标。
/// 两种形态点击行为一致：打开云端面板。
class CloudSyncEntryButton extends StatelessWidget {
  const CloudSyncEntryButton({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final CloudAccountController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final descriptor = describeCloudStatus(controller);
        final colors = cloudToneColors(descriptor.tone);
        return _EntryBody(
          controller: controller,
          descriptor: descriptor,
          colors: colors,
          compact: compact,
        );
      },
    );
  }
}

class _EntryBody extends StatelessWidget {
  const _EntryBody({
    required this.controller,
    required this.descriptor,
    required this.colors,
    required this.compact,
  });

  final CloudAccountController controller;
  final CloudStatusDescriptor descriptor;
  final CloudToneColors colors;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tooltip = descriptor.tooltip ?? descriptor.label;
    if (compact) {
      return Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 32,
          height: 32,
          child: InkWell(
            key: const ValueKey<String>('cloud-entry-button-compact'),
            borderRadius: AppRadius.control,
            onTap: controller.openPanel,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Icon(
                  descriptor.icon,
                  size: AppSizes.iconMd,
                  color: colors.foreground,
                ),
                if (descriptor.tone == CloudStatusTone.warning ||
                    descriptor.tone == CloudStatusTone.danger)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: colors.foreground,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: const ValueKey<String>('cloud-entry-button'),
        borderRadius: AppRadius.control,
        onTap: controller.openPanel,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.control,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(descriptor.icon, size: 15, color: colors.foreground),
              const SizedBox(width: AppSpacing.xs + AppSpacing.xxs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 132),
                child: Text(
                  descriptor.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
