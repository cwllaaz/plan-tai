import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../../cloud_account/cloud_account.dart';
import '../../cloud_account/ui/cloud_widgets.dart';
import 'mobile_cloud_keys.dart';

/// 已登录后的「云端账号」卡片：当前账号、服务器、连接方式、记录数、关联状态。
///
/// 账号、服务器、数据量全部来自 [CloudAccountController]（不在这里读网络/库）；
/// 「退出登录」入口也在这里，文案明确说明**不会删除本机数据**。
class MobileAccountCard extends StatelessWidget {
  const MobileAccountCard({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  Widget build(BuildContext context) {
    final account = controller.account;
    if (account == null) return const SizedBox.shrink();
    final secure = controller.isSecureConnection;
    final inspection = controller.inspection;
    final counts = inspection == null
        ? '本机 — · 云端 —'
        : '本机 ${inspection.localLiveRecords} 条 · 云端 '
              '${inspection.cloudRecords == null ? '未知' : '${inspection.cloudRecords} 条'}';

    return CloudSection(
      title: '云端账号',
      subtitle: '已连接服务器',
      trailing: const CloudStatusPill(
        label: '已连接',
        tone: CloudStatusTone.success,
        icon: Icons.cloud_done_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CloudInfoRow(
            label: '服务器',
            value: account.serverUrl.toString(),
            valueKey: MobileCloudKeys.serverValue,
          ),
          CloudInfoRow(
            label: '当前账号',
            value: account.label,
            valueKey: MobileCloudKeys.accountValue,
          ),
          CloudInfoRow(
            label: '连接方式',
            value: secure ? 'HTTPS 加密' : '开发环境 · HTTP 明文',
            valueColor: secure ? AppColors.textSecondary : AppColors.warning,
            valueKey: MobileCloudKeys.protocolValue,
          ),
          CloudInfoRow(
            label: '记录',
            value: counts,
            valueKey: MobileCloudKeys.recordCounts,
          ),
          CloudInfoRow(
            label: '关联状态',
            value: bindingStageText(controller.bindingStage),
            valueKey: MobileCloudKeys.bindingState,
          ),
          if (controller.bindingResult?.backupPath != null)
            CloudInfoRow(
              label: '最近备份',
              value: controller.bindingResult!.backupPath!,
            ),
          if (controller.notice != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            CloudBanner(
              key: MobileCloudKeys.noticeBanner,
              tone: CloudBannerTone.warning,
              title: '提示',
              message: controller.notice,
              onDismiss: controller.dismissNotice,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: <Widget>[
              CloudTextAction(
                key: MobileCloudKeys.relogin,
                label: '重新登录',
                icon: Icons.lock_reset_rounded,
                onPressed: () => _confirmRelogin(context),
              ),
              const Spacer(),
              CloudTextAction(
                key: MobileCloudKeys.signOut,
                label: '退出账号',
                icon: Icons.logout_rounded,
                danger: true,
                onPressed: () => _confirmSignOut(context),
              ),
            ],
          ),
          const CloudHintText(
            '退出（断开云端绑定）只会清除本机登录令牌，不再自动同步；'
            '本机数据与账号工作区完整保留，重新登录后可继续使用。',
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('退出账号并断开云端绑定？'),
        content: const Text(
          '退出后不再与云端同步，但本机数据、未上传的改动与账号工作区都不会被删除。'
          '下次登录需要重新输入密码。',
          style: AppText.small,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: MobileCloudKeys.signOutConfirm,
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出账号'),
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
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('重新登录？'),
        content: const Text(
          '会先断开当前会话，再要求重新输入密码；本机数据与未同步的改动不受影响。',
          style: AppText.small,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
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

/// 数据归属阶段 → 用户可读文案（与桌面一致）。
String bindingStageText(CloudBindingStage stage) => switch (stage) {
  CloudBindingStage.ready => '已关联（可同步）',
  CloudBindingStage.skipped => '未关联（不上传）',
  CloudBindingStage.restartRequired => '关联完成，待重启',
  CloudBindingStage.needsChoice => '待确认关联方式',
  CloudBindingStage.checking => '正在检查',
  CloudBindingStage.applying => '正在关联',
  CloudBindingStage.failed => '检查失败',
  CloudBindingStage.idle => '未检查',
};
