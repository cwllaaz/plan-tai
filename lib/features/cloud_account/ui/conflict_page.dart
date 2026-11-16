import 'package:material_ui/material_ui.dart';

import '../../../core/cloud/cloud.dart';
import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import '../util/cloud_time_text.dart';
import '../util/conflict_presenter.dart';
import 'cloud_widgets.dart';

/// 打开冲突处理页（模态窗口，宽 760，不挤压月历布局）。
Future<void> showCloudConflictPage(
  BuildContext context,
  CloudAccountController controller,
) {
  if (!controller.showingConflicts) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (BuildContext context) =>
        _ConflictDialogHost(controller: controller),
  );
}

class _ConflictDialogHost extends StatefulWidget {
  const _ConflictDialogHost({required this.controller});

  final CloudAccountController controller;

  @override
  State<_ConflictDialogHost> createState() => _ConflictDialogHostState();
}

class _ConflictDialogHostState extends State<_ConflictDialogHost> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (!widget.controller.showingConflicts) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpacing.xxl),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.panel),
      child: SizedBox(
        width: 760,
        height: 560,
        child: CloudConflictPage(
          controller: widget.controller,
          onClose: widget.controller.closeConflicts,
        ),
      ),
    );
  }
}

/// 冲突处理页内容。可单独嵌入任何容器（测试与独立页面复用）。
class CloudConflictPage extends StatefulWidget {
  const CloudConflictPage({super.key, required this.controller, this.onClose});

  final CloudAccountController controller;
  final VoidCallback? onClose;

  @override
  State<CloudConflictPage> createState() => _CloudConflictPageState();
}

class _CloudConflictPageState extends State<CloudConflictPage> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final controller = widget.controller;
        final conflicts = controller.conflicts;
        final selected = _selectionFor(conflicts);
        return Column(
          key: const ValueKey<String>('cloud-conflict-page'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('同步冲突', style: AppText.h2.copyWith(fontSize: 15)),
                        const SizedBox(height: 1),
                        Text(
                          conflicts.isEmpty
                              ? '没有待处理的冲突'
                              : '${conflicts.length} 项待处理 · 选择前两个版本都会保留',
                          style: AppText.caption,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('cloud-conflict-close'),
                    tooltip: '关闭（稍后处理）',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (controller.conflictsError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  0,
                ),
                child: CloudBanner(
                  tone: CloudBannerTone.danger,
                  title: '读取冲突失败',
                  message: controller.conflictsError,
                ),
              ),
            Expanded(
              child: controller.conflictsLoading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : conflicts.isEmpty
                  ? _EmptyConflicts(onClose: widget.onClose)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        SizedBox(
                          width: 216,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.sm,
                              horizontal: AppSpacing.sm,
                            ),
                            itemCount: conflicts.length,
                            itemBuilder: (BuildContext context, int index) {
                              final conflict = conflicts[index];
                              return _ConflictListItem(
                                conflict: conflict,
                                selected: conflict.id == selected?.id,
                                onTap: () =>
                                    setState(() => _selectedId = conflict.id),
                              );
                            },
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: selected == null
                              ? const SizedBox.shrink()
                              : _ConflictDetail(
                                  controller: controller,
                                  conflict: selected,
                                ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  SyncConflict? _selectionFor(List<SyncConflict> conflicts) {
    if (conflicts.isEmpty) return null;
    for (final conflict in conflicts) {
      if (conflict.id == _selectedId) return conflict;
    }
    return conflicts.first;
  }
}

class _ConflictListItem extends StatelessWidget {
  const _ConflictListItem({
    required this.conflict,
    required this.selected,
    required this.onTap,
  });

  final SyncConflict conflict;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final data = ConflictViewData.from(conflict);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
      child: InkWell(
        key: ValueKey<String>('cloud-conflict-item-${conflict.id}'),
        borderRadius: AppRadius.control,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : Colors.transparent,
            borderRadius: AppRadius.control,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                data.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong.copyWith(
                  fontSize: 12.5,
                  color: selected ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${data.entityLabel} · ${data.kindLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConflictDetail extends StatelessWidget {
  const _ConflictDetail({required this.controller, required this.conflict});

  final CloudAccountController controller;
  final SyncConflict conflict;

  @override
  Widget build(BuildContext context) {
    final data = ConflictViewData.from(conflict);
    final busy = controller.resolvingConflictId == conflict.id;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: Text(data.title, style: AppText.h2)),
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
          const SizedBox(height: AppSpacing.lg),
          Text('主要字段差异', style: AppText.bodyStrong.copyWith(fontSize: 13)),
          const SizedBox(height: AppSpacing.sm),
          if (data.diffs.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.surfaceSunken,
                borderRadius: AppRadius.card,
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
              child: _DiffTable(diffs: data.diffs),
            ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: _VersionCard(
                  title: '本机版本',
                  version: data.localVersionLabel,
                  deleted: data.localDeleted,
                  payload: conflict.localPayload,
                  deviceLabel: '本机',
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _VersionCard(
                  title: '云端版本',
                  version: data.serverVersionLabel,
                  deleted: data.serverDeleted,
                  payload: conflict.serverPayload,
                  deviceLabel: '云端',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const CloudHintText('选择前不会删除任何一个版本；「取消并稍后处理」会保留这条冲突，下次同步还会提示。'),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              TextButton(
                key: const ValueKey<String>('cloud-conflict-later'),
                onPressed: busy ? null : controller.closeConflicts,
                child: const Text('取消并稍后处理'),
              ),
              const Spacer(),
              if (busy) ...<Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              OutlinedButton(
                key: const ValueKey<String>('cloud-conflict-use-server'),
                onPressed: busy
                    ? null
                    : () => controller.resolveConflict(
                        conflict.id,
                        ConflictResolution.keepServer,
                      ),
                child: const Text('使用云端修改'),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                height: 34,
                child: FilledButton(
                  key: const ValueKey<String>('cloud-conflict-keep-local'),
                  onPressed: busy
                      ? null
                      : () => controller.resolveConflict(
                          conflict.id,
                          ConflictResolution.keepLocal,
                        ),
                  child: const Text('保留本机修改'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiffTable extends StatelessWidget {
  const _DiffTable({required this.diffs});

  final List<ConflictFieldDiff> diffs;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          color: AppColors.surfaceSunken,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              _cell('字段', AppText.caption, flex: 2, strong: true),
              _cell('本机', AppText.caption, flex: 4, strong: true),
              _cell('云端', AppText.caption, flex: 4, strong: true),
            ],
          ),
        ),
        for (int index = 0; index < diffs.length; index++)
          Container(
            decoration: BoxDecoration(
              border: index == 0
                  ? null
                  : const Border(top: BorderSide(color: AppColors.border)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _cell(diffs[index].label, AppText.caption, flex: 2),
                _cell(diffs[index].localValue, AppText.small, flex: 4),
                _cell(diffs[index].serverValue, AppText.small, flex: 4),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(
    String text,
    TextStyle style, {
    required int flex,
    bool strong = false,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: AppSpacing.sm),
        child: Text(
          text,
          style: strong ? style.copyWith(fontWeight: FontWeight.w600) : style,
        ),
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.title,
    required this.version,
    required this.deleted,
    required this.payload,
    required this.deviceLabel,
  });

  final String title;
  final String version;
  final bool deleted;
  final Map<String, Object?>? payload;
  final String deviceLabel;

  @override
  Widget build(BuildContext context) {
    final updatedAt = payload?['updatedAt'];
    final parsed = updatedAt is String ? DateTime.tryParse(updatedAt) : null;
    final updatedText = parsed != null
        ? '最后修改 ${formatSyncTimeAbsolute(parsed)}'
        : '最后修改时间未知';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: AppRadius.card,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: AppText.bodyStrong.copyWith(fontSize: 12.5),
                ),
              ),
              CloudStatusPill(
                label: version,
                tone: deleted
                    ? CloudStatusTone.danger
                    : CloudStatusTone.neutral,
                icon: deleted
                    ? Icons.delete_outline_rounded
                    : Icons.history_rounded,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            deleted ? '$deviceLabel版本已被删除' : updatedText,
            style: AppText.caption.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _EmptyConflicts extends StatelessWidget {
  const _EmptyConflicts({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 28,
            color: AppColors.success,
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text('没有待处理的冲突', style: AppText.bodyStrong),
          const SizedBox(height: AppSpacing.xxs),
          const Text('本机与云端已经按记录合并完成。', style: AppText.caption),
          const SizedBox(height: AppSpacing.md),
          TextButton(onPressed: onClose, child: const Text('返回')),
        ],
      ),
    );
  }
}
