import 'package:material_ui/material_ui.dart';

import '../../app/cloud_scope.dart';
import '../../core/contracts/contracts.dart';
import '../../core/theme/theme.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_cloud_account_page.dart';
import 'mobile_cloud_visual.dart';
import 'mobile_data_page.dart';

/// 「我的」分区：账号与同步入口、数据与备份、关于。
///
/// 手机底部导航与平板侧栏共用本页；桌面顶栏的云/备份/设置入口在移动端收敛到这里。
class MobileMyPage extends StatelessWidget {
  const MobileMyPage({
    super.key,
    required this.repository,
    required this.isDemoData,
    this.databasePath,
    this.dataDirectory,
  });

  final PlannerRepository repository;
  final bool isDemoData;
  final String? databasePath;
  final String? dataDirectory;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey<String>('mobile-my-page'),
      padding: const EdgeInsets.fromLTRB(
        MobileMetrics.pagePadding,
        AppSpacing.md,
        MobileMetrics.pagePadding,
        AppSpacing.xxxl,
      ),
      children: <Widget>[
        const _ProfileHeader(),
        const SizedBox(height: AppSpacing.md),
        _CloudEntryCard(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const MobileCloudAccountPage(),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm + 2),
        MobileCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              MobileListTile(
                key: const ValueKey<String>('mobile-my-data'),
                title: '数据与备份',
                subtitle: isDemoData
                    ? '演示数据 · 不写入磁盘'
                    : (databasePath == null ? '本地数据库' : '本地数据库 · 可创建/恢复备份'),
                leading: const Icon(
                  Icons.storage_outlined,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColors.textDisabled,
                ),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => MobileDataPage(
                      repository: repository,
                      databasePath: databasePath,
                      dataDirectory: dataDirectory,
                      isDemoData: isDemoData,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, indent: AppSpacing.md),
              const MobileListTile(
                title: '关于计划台',
                subtitle: '版本 1.0.0 · 本地优先，数据不出本机',
                leading: Icon(
                  Icons.info_outline_rounded,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        MobileCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const MobileSectionHeader(title: '本地优先'),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '所有数据默认只保存在这台设备上；云同步是可选的附加能力，'
                '断网、未登录都不影响查看与编辑。',
                style: AppText.small.copyWith(
                  fontSize: 13,
                  height: 1.55,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  MobileTag(
                    label: isDemoData ? '演示数据' : '本地数据库',
                    color: isDemoData ? AppColors.warning : AppColors.success,
                  ),
                  const MobileTag(label: '中文界面'),
                  const MobileTag(label: '触摸优先'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Icon(
              Icons.calendar_month_rounded,
              size: 26,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('计划台', style: AppText.h1.copyWith(fontSize: 20)),
                Text(
                  '项目与日程 · Android',
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 账号与同步入口：显示当前状态，点击进入移动端账号页。
class _CloudEntryCard extends StatelessWidget {
  const _CloudEntryCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final controller = CloudScope.controllerOf(context);
    if (controller == null) {
      final visual = mobileCloudVisual(null);
      return _CloudEntryBody(
        icon: visual.icon,
        color: visual.color,
        label: '账号与同步',
        detail: visual.detail,
        onTap: onTap,
        keyValue: 'mobile-my-cloud',
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final visual = mobileCloudVisual(controller);
        return _CloudEntryBody(
          icon: visual.icon,
          color: visual.color,
          label: controller.accountLabel.isEmpty
              ? '账号与同步 · ${visual.label}'
              : '账号与同步 · ${visual.label}（${controller.accountLabel}）',
          detail: visual.detail,
          onTap: onTap,
          keyValue: 'mobile-my-cloud',
        );
      },
    );
  }
}

class _CloudEntryBody extends StatelessWidget {
  const _CloudEntryBody({
    required this.icon,
    required this.color,
    required this.label,
    required this.detail,
    required this.onTap,
    required this.keyValue,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String detail;
  final VoidCallback onTap;
  final String keyValue;

  @override
  Widget build(BuildContext context) {
    return MobileCard(
      key: ValueKey<String>(keyValue),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                color.withValues(alpha: 0.12),
                AppColors.surface,
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyStrong.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: AppColors.textDisabled,
          ),
        ],
      ),
    );
  }
}
