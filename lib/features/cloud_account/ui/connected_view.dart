import 'package:material_ui/material_ui.dart';

import '../../../core/cloud/cloud.dart';
import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import '../util/cloud_time_text.dart';
import 'binding_card.dart';
import 'cloud_widgets.dart';
import 'conflict_page.dart';
import 'sync_status_view.dart';

/// 已登录状态：账号信息 + 云同步状态 + 本机数据 + 断开/重新登录。
class CloudConnectedView extends StatelessWidget {
  const CloudConnectedView({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  Widget build(BuildContext context) {
    final showBindingCard =
        controller.bindingStage != CloudBindingStage.ready &&
        controller.bindingStage != CloudBindingStage.idle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (controller.banner != null) ...<Widget>[
          CloudBanner(
            key: const ValueKey<String>('cloud-action-banner'),
            tone: controller.bannerIsError
                ? CloudBannerTone.danger
                : CloudBannerTone.success,
            title: controller.bannerIsError ? '操作未完成' : '操作完成',
            message: controller.banner,
            onDismiss: controller.dismissBanner,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (showBindingCard) ...<Widget>[
          CloudBindingCard(controller: controller),
          const SizedBox(height: AppSpacing.md),
        ],
        _AccountSection(controller: controller),
        const SizedBox(height: AppSpacing.md),
        _SyncSection(controller: controller),
      ],
    );
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.controller});

  final CloudAccountController controller;

  @override
  Widget build(BuildContext context) {
    final account = controller.account;
    if (account == null) return const SizedBox.shrink();
    final secure = controller.isSecureConnection;
    return CloudSection(
      title: '云端账号',
      subtitle: '已连接服务器',
      trailing: const CloudStatusPill(
        label: '已连接',
        tone: CloudStatusTone.success,
        icon: Icons.cloud_done_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CloudInfoRow(
            label: '服务器',
            value: account.serverUrl.toString(),
            valueKey: const ValueKey<String>('cloud-server-value'),
          ),
          CloudInfoRow(
            label: '当前账号',
            value: account.label,
            valueKey: const ValueKey<String>('cloud-account-value'),
          ),
          CloudInfoRow(
            label: '连接方式',
            value: secure ? 'HTTPS 加密' : '开发环境 · HTTP 明文',
            valueColor: secure ? AppColors.textSecondary : AppColors.warning,
            valueKey: const ValueKey<String>('cloud-protocol-value'),
          ),
          CloudInfoRow(
            label: '记录',
            value: controller.inspection == null
                ? '本机 — · 云端 —'
                : '本机 ${controller.inspection!.localLiveRecords} 条 · 云端 '
                      '${controller.inspection!.cloudRecords == null ? '未知' : '${controller.inspection!.cloudRecords} 条'}',
            valueKey: const ValueKey<String>('cloud-record-counts'),
          ),
          CloudInfoRow(
            label: '关联状态',
            value: _bindingStateText(controller.bindingStage),
            valueKey: const ValueKey<String>('cloud-binding-state'),
          ),
          if (controller.bindingResult?.backupPath != null)
            CloudInfoRow(
              label: '最近备份',
              value: controller.bindingResult!.backupPath!,
              valueKey: const ValueKey<String>('cloud-backup-path'),
            ),
          const SizedBox(height: AppSpacing.xs),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: <Widget>[
              CloudTextAction(
                key: const ValueKey<String>('cloud-relogin'),
                label: '重新登录',
                icon: Icons.lock_reset_rounded,
                onPressed: () => _confirmRelogin(context),
              ),
              const Spacer(),
              CloudTextAction(
                key: const ValueKey<String>('cloud-signout'),
                label: '断开云端绑定',
                icon: Icons.link_off_rounded,
                danger: true,
                onPressed: () => _confirmSignOut(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('断开云端绑定？'),
        content: const SizedBox(
          width: 380,
          child: Text(
            '断开后不再与云端账号同步，但本机数据不会被删除，未上传的改动也不会丢失。'
            '下次登录需要重新验证账号。',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('cloud-signout-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('断开绑定'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.signOut();
    }
  }

  Future<void> _confirmRelogin(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('重新登录？'),
        content: const SizedBox(
          width: 380,
          child: Text('会先断开当前会话，再要求重新输入密码；本机数据与未同步的改动不受影响。'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('cloud-relogin-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重新登录'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.reauthenticate();
    }
  }
}

class _SyncSection extends StatelessWidget {
  const _SyncSection({required this.controller});

  final CloudAccountController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.syncStatus;
    final descriptor = describeCloudStatus(controller);
    final now = controller.now;
    final canSync = controller.canSync;
    final disabledReason = !canSync
        ? (controller.bindingSkipped ? '本机数据未关联账号，暂不上传' : '请先确认本地数据如何关联到云端账号')
        : null;

    return CloudSection(
      title: '云同步',
      trailing: CloudStatusPill(
        key: const ValueKey<String>('cloud-sync-status'),
        label: descriptor.label,
        tone: descriptor.tone,
        icon: descriptor.icon,
        busy: descriptor.busy,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (status.phase == SyncPhase.syncing &&
              status.message != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Text(status.message!, style: AppText.small),
          ],
          if (status.phase == SyncPhase.offline) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            const CloudBanner(
              tone: CloudBannerTone.warning,
              title: '当前离线',
              message: '改动已保存在本机；恢复网络后会自动上传，不需要重新编辑。',
            ),
          ],
          if (status.phase == SyncPhase.error &&
              status.lastError != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            CloudBanner(
              tone: CloudBannerTone.danger,
              title: '同步失败',
              message: status.lastError,
              hint: '失败不会丢数据：改动仍保存在本机，可以重试。',
            ),
          ],
          if (controller.conflictCount > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              width: double.infinity,
              height: 32,
              child: OutlinedButton.icon(
                key: const ValueKey<String>('cloud-open-conflicts'),
                onPressed: () => _openConflicts(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warning,
                  side: BorderSide(
                    color: AppColors.warning.withValues(alpha: 0.45),
                  ),
                  backgroundColor: AppColors.warningSoft,
                ),
                icon: const Icon(Icons.warning_amber_rounded, size: 15),
                label: Text('处理冲突（${controller.conflictCount}）'),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          CloudInfoRow(
            label: '待上传',
            value: '${status.pendingOperations} 项',
            valueKey: const ValueKey<String>('cloud-pending-count'),
          ),
          const CloudInfoRow(
            label: '本地保存',
            value: '已保存到本机',
            valueKey: ValueKey<String>('cloud-local-saved'),
          ),
          CloudInfoRow(
            label: '最近上传',
            value: status.lastUploadedAt == null
                ? '—'
                : formatSyncTime(status.lastUploadedAt, now: now),
            valueKey: const ValueKey<String>('cloud-last-upload'),
          ),
          CloudInfoRow(
            label: '最近下载',
            value: status.lastDownloadedAt == null
                ? '—'
                : formatSyncTime(status.lastDownloadedAt, now: now),
            valueKey: const ValueKey<String>('cloud-last-download'),
          ),
          const SizedBox(height: AppSpacing.sm),
          _AutoSwitchRow(
            label: '自动上传',
            hint: '本机改动在后台自动上传到云端',
            switchKey: const ValueKey<String>('cloud-auto-upload'),
            value: status.autoUploadEnabled,
            enabled: canSync,
            onChanged: controller.setAutoUpload,
          ),
          _AutoSwitchRow(
            label: '自动下载',
            hint: '定时从云端拉取更新到本机',
            switchKey: const ValueKey<String>('cloud-auto-download'),
            value: status.autoDownloadEnabled,
            enabled: canSync,
            onChanged: controller.setAutoDownload,
          ),
          const SizedBox(height: AppSpacing.sm),
          Tooltip(
            message: disabledReason ?? '只上传本机改动到云端',
            child: CloudPrimaryButton(
              key: const ValueKey<String>('cloud-upload-now'),
              label: '上传到云端',
              busy: controller.isSyncing,
              busyLabel: '正在上传…',
              icon: Icons.cloud_upload_outlined,
              onPressed: controller.canSync && !controller.isSyncing
                  ? controller.uploadNow
                  : null,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Tooltip(
            message: disabledReason ?? '只从云端更新到本机',
            child: SizedBox(
              width: double.infinity,
              height: 38,
              child: OutlinedButton.icon(
                key: const ValueKey<String>('cloud-download-now'),
                onPressed: controller.canSync && !controller.isSyncing
                    ? () => _downloadWithConfirm(context)
                    : null,
                icon: const Icon(Icons.cloud_download_outlined, size: 16),
                label: Text(
                  controller.isSyncing ? '正在下载…' : '从云端更新',
                  style: AppText.small.copyWith(fontSize: 13),
                ),
              ),
            ),
          ),
          if (disabledReason != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            CloudHintText(disabledReason, color: AppColors.textTertiary),
          ],
        ],
      ),
    );
  }

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
        content: SizedBox(
          width: 430,
          child: Text(
            '本机有 $pending 项未上传改动。\n\n'
            '“覆盖并更新”会把本机数据完全替换成云端快照：所有未上传改动都会丢弃，'
            '仅存在于本机、云端没有的记录也会被移除。\n\n'
            '会尽力先创建整库备份；备份失败也会继续覆盖。\n\n'
            '“仅更新”只拉取云端，保留本机未上传改动；两边改到同一条时会产生冲突。',
            style: AppText.small,
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('cloud-download-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('cloud-download-preserve'),
            onPressed: () => Navigator.of(dialogContext).pop('preserve'),
            child: const Text('仅更新，保留本机改动'),
          ),
          FilledButton(
            key: const ValueKey<String>('cloud-download-force'),
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

  Future<void> _openConflicts(BuildContext context) async {
    await controller.openConflicts();
    if (!context.mounted) return;
    await showCloudConflictPage(context, controller);
  }
}

class _AutoSwitchRow extends StatelessWidget {
  const _AutoSwitchRow({
    required this.label,
    required this.hint,
    required this.switchKey,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final Key switchKey;
  final bool value;
  final bool enabled;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled ? hint : '请先完成数据关联',
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: AppText.small.copyWith(fontSize: 12.5)),
                Text(
                  hint,
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: switchKey,
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

String _bindingStateText(CloudBindingStage stage) => switch (stage) {
  CloudBindingStage.ready => '已关联（可同步）',
  CloudBindingStage.skipped => '未关联（不上传）',
  CloudBindingStage.restartRequired => '关联完成，待重启',
  CloudBindingStage.needsChoice => '待确认关联方式',
  CloudBindingStage.checking => '正在检查',
  CloudBindingStage.applying => '正在关联',
  CloudBindingStage.failed => '检查失败',
  CloudBindingStage.idle => '未检查',
};
