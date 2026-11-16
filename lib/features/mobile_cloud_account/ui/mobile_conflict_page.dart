import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../../cloud_account/cloud_account.dart';
import '../../cloud_account/ui/cloud_widgets.dart';
import 'mobile_cloud_keys.dart';

/// 打开冲突处理页：先只读加载冲突列表，再压入全屏页。
Future<void> openMobileCloudConflicts(
  BuildContext context,
  CloudAccountController controller,
) async {
  await controller.openConflicts();
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          MobileCloudConflictPage(controller: controller),
    ),
  );
}

/// 冲突处理页（手机全屏）。
///
/// 每条冲突展示：实体类型 / 冲突类型 / 检测时间 / 字段差异（本机 vs 云端）/
/// 两个版本号，并提供「保留本机修改」「使用云端修改」两个明确操作。
/// 选择前两个版本都保留；关闭页面不删除任何内容，下次同步还会提示。
class MobileCloudConflictPage extends StatefulWidget {
  const MobileCloudConflictPage({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  State<MobileCloudConflictPage> createState() =>
      _MobileCloudConflictPageState();
}

class _MobileCloudConflictPageState extends State<MobileCloudConflictPage> {
  @override
  void dispose() {
    widget.controller.closeConflicts();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final controller = widget.controller;
        final conflicts = controller.conflicts;
        return Scaffold(
          key: MobileCloudKeys.conflictPage,
          backgroundColor: AppColors.canvas,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.textPrimary,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('同步冲突', style: AppText.h2.copyWith(fontSize: 16)),
                Text(
                  conflicts.isEmpty ? '没有待处理的冲突' : '${conflicts.length} 项待处理',
                  style: AppText.caption,
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                key: MobileCloudKeys.conflictClose,
                tooltip: '关闭（保留冲突，稍后处理）',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(height: 1, color: AppColors.border),
            ),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _body(controller),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(CloudAccountController controller) {
    if (controller.conflictsLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: <Widget>[
        if (controller.conflictsError != null) ...<Widget>[
          CloudBanner(
            tone: CloudBannerTone.danger,
            title: '读取冲突失败',
            message: controller.conflictsError,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (controller.conflicts.isEmpty)
          const _EmptyConflicts()
        else
          for (final conflict in controller.conflicts) ...<Widget>[
            _ConflictCard(controller: controller, conflict: conflict),
            const SizedBox(height: AppSpacing.md),
          ],
      ],
    );
  }
}

class _EmptyConflicts extends StatelessWidget {
  const _EmptyConflicts();

  @override
  Widget build(BuildContext context) {
    return const CloudSection(
      title: '没有需要处理的冲突',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('本机与云端没有互相覆盖的修改。', style: AppText.small),
          SizedBox(height: AppSpacing.sm),
          CloudHintText('如果之后出现冲突，会在这里逐条列出，选择前两个版本都会保留。'),
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.controller, required this.conflict});

  final CloudAccountController controller;
  final SyncConflict conflict;

  @override
  Widget build(BuildContext context) {
    final data = ConflictViewData.from(conflict);
    final busy = controller.resolvingConflictId == conflict.id;
    return Container(
      key: MobileCloudKeys.conflictItem(conflict.id),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.panel,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  data.title,
                  style: AppText.bodyStrong.copyWith(fontSize: 14),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              CloudStatusPill(
                label: data.entityLabel,
                tone: CloudStatusTone.neutral,
                icon: Icons.label_outline_rounded,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            '${data.kindLabel} · 检测于 '
            '${formatSyncTime(conflict.detectedAt, now: controller.now)}',
            style: AppText.caption,
          ),
          const SizedBox(height: AppSpacing.md),
          if (data.diffs.isEmpty)
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surfaceSunken,
                borderRadius: AppRadius.control,
              ),
              child: Text(
                data.emptyDiffHint,
                style: AppText.small.copyWith(fontSize: 12.5),
              ),
            )
          else
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: AppRadius.card,
              ),
              child: Column(
                children: <Widget>[
                  for (int index = 0; index < data.diffs.length; index++)
                    Container(
                      decoration: BoxDecoration(
                        border: index == 0
                            ? null
                            : const Border(
                                top: BorderSide(color: AppColors.border),
                              ),
                      ),
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            data.diffs[index].label,
                            style: AppText.caption.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          _versionLine(
                            '本机',
                            data.diffs[index].localValue,
                            MobileCloudKeys.conflictLocalValue(conflict.id),
                          ),
                          const SizedBox(height: 2),
                          _versionLine(
                            '云端',
                            data.diffs[index].serverValue,
                            MobileCloudKeys.conflictServerValue(conflict.id),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Text('本机 ${data.localVersionLabel}', style: AppText.caption),
              const SizedBox(width: AppSpacing.md),
              Text('云端 ${data.serverVersionLabel}', style: AppText.caption),
              const Spacer(),
              if (data.localDeleted || data.serverDeleted)
                Text(
                  data.localDeleted && data.serverDeleted
                      ? '两边都已删除'
                      : data.localDeleted
                      ? '本机已删除'
                      : '云端已删除',
                  style: AppText.caption.copyWith(color: AppColors.warning),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const CloudHintText(
            '选择前不会删除任何一个版本；「关闭」会保留这条冲突，下次同步还会提示。',
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.sm),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                ),
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: OutlinedButton(
                    key: MobileCloudKeys.conflictUseServer(conflict.id),
                    onPressed: busy
                        ? null
                        : () => controller.resolveConflict(
                            conflict.id,
                            ConflictResolution.keepServer,
                          ),
                    child: const Text('使用云端修改'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: FilledButton(
                    key: MobileCloudKeys.conflictKeepLocal(conflict.id),
                    onPressed: busy
                        ? null
                        : () => controller.resolveConflict(
                            conflict.id,
                            ConflictResolution.keepLocal,
                          ),
                    child: const Text('保留本机修改'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _versionLine(String label, String value, Key key) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 34,
          child: Text(
            label,
            style: AppText.caption.copyWith(color: AppColors.textTertiary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            key: key,
            style: AppText.small.copyWith(fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}
