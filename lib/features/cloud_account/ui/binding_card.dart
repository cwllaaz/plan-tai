import 'package:material_ui/material_ui.dart';

import '../../../core/cloud/cloud.dart';
import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import '../util/cloud_texts.dart';
import 'cloud_widgets.dart';

/// 首次登录 / 换账号时的数据归属卡片。
///
/// 关键约束（docs/sync/ACCOUNT_BINDING.md）：
/// - 用户做出选择之前不调用 `applyBinding`，本机数据不会被上传、覆盖或迁移；
/// - 场景 4（两边都有数据）禁止自动合并，只给「以云端为准 / 保持本地不绑定」；
/// - 场景 5（本机已绑定其他账号）禁止上传，只给「为当前账号新建空工作区 / 取消登录」；
/// - 需要备份时把「先整库备份」写在操作按钮之前，备份路径由 `BindingResult` 回显。
class CloudBindingCard extends StatelessWidget {
  const CloudBindingCard({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.bindingStage) {
      case CloudBindingStage.checking:
        return const CloudSection(
          title: '正在检查本机数据',
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              ),
              SizedBox(width: AppSpacing.sm),
              Text('正在核对本机与云端的数据量…', style: AppText.small),
            ],
          ),
        );
      case CloudBindingStage.applying:
        return const CloudSection(
          title: '正在关联数据',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text('正在执行你选择的关联方式，请稍候…', style: AppText.small),
                  ),
                ],
              ),
              SizedBox(height: AppSpacing.sm),
              CloudHintText('这一步会先做整库备份，再按记录合并；不要关闭应用。'),
            ],
          ),
        );
      case CloudBindingStage.failed:
        return CloudSection(
          title: '无法检查数据归属',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const CloudBanner(
                tone: CloudBannerTone.warning,
                title: '网络或服务器暂时不可用',
                message: '本机数据没有做任何改动。',
                hint: '恢复网络后重试；也可以先「暂不关联」，本地数据仍可正常使用。',
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  CloudTextAction(
                    label: '重新检查',
                    icon: Icons.refresh_rounded,
                    onPressed: controller.retryBindingInspection,
                  ),
                  const Spacer(),
                  CloudTextAction(
                    label: '暂不关联',
                    onPressed: () => controller.chooseBinding(
                      BindingChoice.keepLocalUnbound,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      case CloudBindingStage.skipped:
        return CloudSection(
          title: '本机数据未关联账号',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const CloudHintText(
                '本机数据完整保留，但不会上传到云端，也不会从云端下载。'
                '需要同步时，可重新选择关联方式。',
              ),
              const SizedBox(height: AppSpacing.sm),
              CloudTextAction(
                key: const ValueKey<String>('cloud-binding-reopen'),
                label: '重新选择关联方式',
                icon: Icons.link_rounded,
                onPressed: controller.retryBindingInspection,
              ),
            ],
          ),
        );
      case CloudBindingStage.restartRequired:
        return CloudSection(
          title: '需要重启应用',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const CloudBanner(
                tone: CloudBannerTone.warning,
                title: '工作区已经切换',
                message: '重启计划台后会打开新的账号工作区，本机原数据已备份保留。',
              ),
              if (controller.bindingResult?.backupPath != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '备份位置：${controller.bindingResult!.backupPath}',
                  style: AppText.caption,
                ),
              ],
            ],
          ),
        );
      case CloudBindingStage.needsChoice:
      case CloudBindingStage.idle:
      case CloudBindingStage.ready:
        break;
    }

    final inspection = controller.inspection;
    if (inspection == null) return const SizedBox.shrink();
    return _BindingPrompt(controller: controller, inspection: inspection);
  }
}

class _BindingPrompt extends StatelessWidget {
  const _BindingPrompt({required this.controller, required this.inspection});

  final CloudAccountController controller;
  final BindingInspection inspection;

  bool get _isOtherAccount =>
      inspection.situation == BindingSituation.boundOtherAccount;

  bool get _isBothHaveData =>
      inspection.situation == BindingSituation.bothHaveData;

  bool get _isFreshInstallWithCloud =>
      inspection.situation == BindingSituation.freshInstallCloudHasData;

  String get _question {
    if (_isFreshInstallWithCloud) {
      return '云端已有 ${inspection.cloudRecords} 条数据，是否创建本机工作区并下载？';
    }
    if (_isOtherAccount) {
      return '本机数据属于另一个云端账号，是否为本机新建当前账号的工作区？';
    }
    return '检测到当前电脑已有本地数据，是否将这些数据关联到当前云端账号？';
  }

  /// 四条说明：保留本地 / 合并方式 / 不直接覆盖 / 冲突提示。
  List<String> get _rules {
    if (_isOtherAccount) {
      return const <String>[
        '本机数据属于另一个账号，本次登录不会把任何一条记录上传给当前账号。',
        '可以为当前账号新建一个独立工作区；原账号的本地库完整保留。',
        '旧工作区不会被删除、改名或覆盖，随时可以切回。',
        '切换工作区需要重启应用，重启前不会改动本机数据库。',
      ];
    }
    if (_isBothHaveData) {
      return const <String>[
        '保留本地数据：任何选择都不会删除本机数据；「以云端为准」会先整库备份并归档。',
        '第一版不自动合并整库：本机库与云端库只能二选一作为当前工作区。',
        '已经存在的记录不会被直接覆盖：归档备份可随时恢复。',
        '出现冲突时会提示：同步产生的冲突可以在「冲突处理」里逐条选择。',
      ];
    }
    if (_isFreshInstallWithCloud) {
      return const <String>[
        '本机目前没有数据，新建的工作区是空的。',
        '确认后会下载云端记录，并按记录逐条写入本机。',
        '下载不会删除本机已有内容（本机为空，实际没有可覆盖的数据）。',
        '出现冲突或失败时会提示，不会静默跳过。',
      ];
    }
    return const <String>[
      '保留本地数据：任何选择都不会删除本机数据；需要时先整库备份，可随时恢复。',
      '上传和下载后按记录合并：本机改动上传后与云端记录合并，不会把整库覆盖成一边。',
      '已经存在的记录不会被直接覆盖：同一条记录两边都改过时会先生成冲突。',
      '出现冲突时会提示：可在「冲突处理」里选择保留本机还是云端版本，选择前两个版本都会留着。',
    ];
  }

  BindingChoice get _primaryChoice => bindingPrimaryChoice(inspection);

  BindingChoice? get _secondaryChoice {
    return switch (inspection.situation) {
      BindingSituation.localDataCloudEmpty => BindingChoice.keepLocalUnbound,
      BindingSituation.bothHaveData => BindingChoice.keepLocalUnbound,
      BindingSituation.boundOtherAccount => BindingChoice.cancel,
      BindingSituation.freshInstallCloudHasData ||
      BindingSituation.freshInstallCloudEmpty ||
      BindingSituation.boundSameAccount => null,
    };
  }

  String? get _secondaryLabel {
    return switch (inspection.situation) {
      BindingSituation.localDataCloudEmpty => '暂不关联，只保留本机数据',
      BindingSituation.bothHaveData => '保持本地不绑定',
      BindingSituation.boundOtherAccount => '取消登录',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final busy = controller.isApplyingBinding;
    return CloudSection(
      title: bindingTitle(inspection.situation),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _question,
            style: AppText.bodyStrong.copyWith(fontSize: 13.5, height: 1.5),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            inspection.message,
            style: AppText.small.copyWith(fontSize: 12.5),
          ),
          const SizedBox(height: AppSpacing.sm),
          _countsRow(),
          const SizedBox(height: AppSpacing.md),
          for (final rule in _rules) _BindingRule(text: rule),
          if (_isBothHaveData) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            const CloudBanner(
              tone: CloudBannerTone.warning,
              title: '两边都有数据，第一版不自动合并整库',
              message:
                  '请选择「以云端为准（先备份并归档本机数据）」或「保持本地不绑定」；'
                  '直接上传会混淆两个库，所以这里不提供自动上传。',
            ),
          ],
          if (_isOtherAccount) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            CloudBanner(
              tone: CloudBannerTone.danger,
              title: '不会上传其他账号的数据',
              message: inspection.boundOwnerId == null
                  ? '为保护数据，禁止把本机数据上传到此账号。'
                  : '本机数据属于账号 ${inspection.boundOwnerId}，不会上传给当前账号。',
              hint: '可以为当前账号新建空工作区，或取消本次登录。',
            ),
          ],
          if (inspection.requiresBackup) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            const CloudHintText(
              '执行前会自动把当前数据库整库备份到本机备份目录，完成后在「本机数据 · 最近备份」显示路径。',
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          CloudPrimaryButton(
            key: const ValueKey<String>('cloud-binding-confirm'),
            label: bindingPrimaryLabel(inspection),
            busy: busy,
            busyLabel: '正在关联…',
            icon: Icons.link_rounded,
            onPressed: busy
                ? null
                : () => controller.chooseBinding(_primaryChoice),
          ),
          if (_secondaryChoice != null && _secondaryLabel != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              height: 34,
              child: OutlinedButton(
                key: const ValueKey<String>('cloud-binding-skip'),
                onPressed: busy
                    ? null
                    : () => controller.chooseBinding(_secondaryChoice!),
                child: Text(_secondaryLabel!),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          const CloudHintText('关闭面板不做任何改动；下次登录会再次询问，不会自动上传。'),
        ],
      ),
    );
  }

  Widget _countsRow() {
    final cloud = inspection.cloudRecords;
    final cloudText = cloud == null ? '云端记录数未知（不推断为空）' : '云端 $cloud 条记录';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: AppRadius.control,
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.storage_rounded,
            size: AppSizes.iconSm,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '本机 ${inspection.localLiveRecords} 条记录 · $cloudText',
              style: AppText.small.copyWith(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _BindingRule extends StatelessWidget {
  const _BindingRule({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs + AppSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 1.5),
            child: Icon(
              Icons.check_circle_outline_rounded,
              size: 14,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: AppText.caption.copyWith(
                fontSize: 11.5,
                height: 1.55,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
