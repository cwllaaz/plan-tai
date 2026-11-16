import 'package:material_ui/material_ui.dart';

import '../../app/cloud_scope.dart';
import '../../core/theme/theme.dart';
import '../../features/mobile_cloud_account/mobile_cloud_account.dart'
    as mobile_cloud;
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';

/// 「我的 / 顶栏 → 账号与同步」入口（集成接线版）。
///
/// 云端可用时：**直接使用 数据层 的移动端账号/同步页**
/// （`lib/features/mobile_cloud_account`：登录、账号卡、同步状态与操作、
/// 自动同步开关、退出、冲突处理，均为触屏排版且已有 320–800dp 测试）。
/// 这里不再复制一套登录/同步界面，只保留「云服务未启用」时的离线说明页。
///
/// 离线时（`CloudScope` 为 null，例如安全存储不可用）：如实说明云同步未启用，
/// 不伪造登录表单、不弹登录墙，本地功能完全可用。
class MobileCloudAccountPage extends StatelessWidget {
  const MobileCloudAccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CloudScope.controllerOf(context);
    if (controller != null) {
      return mobile_cloud.MobileCloudAccountPage(controller: controller);
    }
    return const _OfflineCloudPage();
  }
}

/// 云服务未启用（离线）时的说明页：不伪造登录表单，也不阻塞本地功能。
class _OfflineCloudPage extends StatelessWidget {
  const _OfflineCloudPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            MobilePageHeader(
              title: '账号与同步',
              subtitle: '离线模式',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                key: const ValueKey<String>('mobile-cloud-offline'),
                padding: const EdgeInsets.fromLTRB(
                  MobileMetrics.pagePadding,
                  AppSpacing.lg,
                  MobileMetrics.pagePadding,
                  AppSpacing.xxxl,
                ),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceSunken,
                                borderRadius: BorderRadius.circular(AppRadius.md),
                              ),
                              child: const Icon(
                                Icons.cloud_off_outlined,
                                size: 20,
                                color: AppColors.textTertiary,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '云同步未启用',
                                    style: AppText.h2.copyWith(fontSize: 16),
                                  ),
                                  Text(
                                    '当前为纯离线模式，登录入口在此预留',
                                    style: AppText.caption.copyWith(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          '本地数据完全可用：月历、任务、安排、每日备注、项目都不受影响。'
                          '当前设备的安全令牌存储不可用（或云服务初始化失败），'
                          '为避免明文保存登录令牌，这里不提供登录入口。'
                          '在这台设备上创建/编辑的数据会完整保存在本地，'
                          '修好安全存储后重新打开应用即可登录并同步。',
                          style: AppText.small.copyWith(
                            fontSize: 13,
                            height: 1.6,
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
                        const MobileSectionHeader(title: '离线时可以做什么'),
                        const SizedBox(height: AppSpacing.sm),
                        for (final line in const <String>[
                          '查看与编辑月历、任务、跨天安排',
                          '新建 / 完成 / 删除任务，随时撤销删除',
                          '记录每日备注与当日重点（自动保存）',
                          '管理项目、颜色与阶段安排',
                          '从本地备份恢复数据',
                        ])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Icon(
                                  Icons.check_rounded,
                                  size: 16,
                                  color: AppColors.success,
                                ),
                                const SizedBox(width: AppSpacing.xs + 2),
                                Expanded(
                                  child: Text(
                                    line,
                                    style: AppText.small.copyWith(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
