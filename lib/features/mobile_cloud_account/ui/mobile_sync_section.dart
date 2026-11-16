import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../../cloud_account/cloud_account.dart';
import '../../cloud_account/ui/cloud_widgets.dart';
import 'mobile_cloud_keys.dart';

/// 已登录后的「云同步」卡片：状态、待同步数量、上次成功时间、失败信息、
/// 立即同步、自动同步开关、冲突入口。
///
/// 状态语义直接复用 [describeCloudStatus]（与桌面顶栏/面板同一套优先级），
/// 保证「有冲突」不会被「有 N 项待同步」盖掉、「离线」不会被显示成「已同步」。
class MobileSyncSection extends StatelessWidget {
  const MobileSyncSection({
    super.key,
    required this.controller,
    required this.onOpenConflicts,
  });

  final CloudAccountController controller;
  final VoidCallback onOpenConflicts;

  @override
  Widget build(BuildContext context) {
    final status = controller.syncStatus;
    final descriptor = describeCloudStatus(controller);
    final canSync = controller.canSync;
    final busy = controller.isSyncing;
    final disabledReason = canSync
        ? null
        : (controller.bindingSkipped
              ? '本机数据未关联账号，暂不上传'
              : controller.bindingStage == CloudBindingStage.restartRequired
              ? '需要重启应用完成工作区切换后再同步'
              : '请先确认本地数据如何关联到云端账号');

    return CloudSection(
      title: '云同步',
      trailing: CloudStatusPill(
        key: MobileCloudKeys.syncStatusPill,
        label: descriptor.label,
        tone: descriptor.tone,
        icon: descriptor.icon,
        busy: descriptor.busy,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (status.phase == SyncPhase.syncing) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    status.message ?? '正在与云端同步…',
                    style: AppText.small.copyWith(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ],
          if (status.phase == SyncPhase.offline) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            const CloudBanner(
              tone: CloudBannerTone.warning,
              title: '当前离线',
              message: '改动已保存在本机；恢复网络后会自动重试上传，不需要重新编辑。',
            ),
          ],
          if (status.lastError != null && status.phase == SyncPhase.error) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            CloudBanner(
              key: MobileCloudKeys.errorBanner,
              tone: CloudBannerTone.danger,
              title: '同步失败',
              message: status.lastError,
              hint: '失败不会丢数据：改动仍保存在本机，可以重试。',
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          CloudInfoRow(
            label: '待同步',
            value: '${status.pendingOperations} 项',
            valueKey: MobileCloudKeys.pendingCount,
            valueColor: status.pendingOperations > 0
                ? AppColors.warning
                : AppColors.textSecondary,
          ),
          CloudInfoRow(
            label: '上次成功',
            value: formatSyncTime(status.lastSyncedAt, now: controller.now),
            valueKey: MobileCloudKeys.lastSync,
          ),
          if (status.message != null && status.phase != SyncPhase.syncing) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              status.message!,
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          _AutoSyncRow(controller: controller, enabled: canSync),
          if (controller.conflictCount > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 40,
              child: OutlinedButton.icon(
                key: MobileCloudKeys.openConflicts,
                onPressed: onOpenConflicts,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warning,
                  side: BorderSide(
                    color: AppColors.warning.withValues(alpha: 0.45),
                  ),
                  backgroundColor: AppColors.warningSoft,
                ),
                icon: const Icon(Icons.warning_amber_rounded, size: 17),
                label: Text('处理冲突（${controller.conflictCount}）'),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              key: MobileCloudKeys.syncNow,
              onPressed: canSync && !busy ? controller.syncNow : null,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: AppColors.textInverse,
                      ),
                    )
                  : const Icon(Icons.sync_rounded, size: 18),
              label: Text(busy ? '正在同步…' : '立即同步'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    key: MobileCloudKeys.uploadNow,
                    onPressed: canSync && !busy ? controller.uploadNow : null,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: const Text('仅上传'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    key: MobileCloudKeys.downloadNow,
                    onPressed: canSync && !busy
                        ? () => _downloadWithConfirm(context)
                        : null,
                    icon: const Icon(Icons.cloud_download_outlined, size: 16),
                    label: const Text('仅下载'),
                  ),
                ),
              ),
            ],
          ),
          if (disabledReason != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            CloudHintText(disabledReason, color: AppColors.textTertiary),
          ],
        ],
      ),
    );
  }

  /// 下载前二次确认：本机有未上传改动时必须让用户明确「仅更新」还是「覆盖」。
  Future<void> _downloadWithConfirm(BuildContext context) async {
    final pending = controller.syncStatus.pendingOperations;
    if (pending == 0) {
      await controller.downloadNow();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('从云端更新'),
        content: Text(
          '本机有 $pending 项未上传改动。\n\n'
          '「仅更新」只拉取云端，保留本机改动；两边改到同一条时会产生冲突。\n'
          '「覆盖并更新」会对云端已有的记录丢弃本机未上传改动，并以云端为准；'
          '仅本机存在、云端没有的记录会保留，之后仍可上传。\n'
          '会尽力先创建备份；备份失败也会继续覆盖。',
          style: AppText.small,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: MobileCloudKeys.downloadPreserve,
            onPressed: () => Navigator.of(dialogContext).pop('preserve'),
            child: const Text('仅更新，保留本机改动'),
          ),
          FilledButton(
            key: MobileCloudKeys.downloadForce,
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop('force'),
            child: const Text('覆盖并更新'),
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'force') {
      await controller.downloadNow(overwriteLocal: true);
    } else if (action == 'preserve') {
      await controller.downloadNow();
    }
  }
}

class _AutoSyncRow extends StatelessWidget {
  const _AutoSyncRow({required this.controller, required this.enabled});

  final CloudAccountController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final status = controller.syncStatus;
    final auto = status.autoSyncEnabled;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('自动同步', style: AppText.small.copyWith(fontSize: 13)),
              const SizedBox(height: 1),
              Text(
                auto
                    ? '本机改动自动上传；打开应用/回到前台时自动检查云端更新'
                    : '已关闭：只在点击「立即同步」时联网',
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        Switch(
          key: MobileCloudKeys.autoSync,
          value: auto,
          onChanged: enabled ? controller.setAutoSync : null,
        ),
      ],
    );
  }
}
