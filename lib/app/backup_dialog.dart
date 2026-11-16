import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../core/contracts/contracts.dart';
import '../core/theme/theme.dart';
import '../data/data.dart';
import '../platform/open_directory.dart';

/// 打开「本地备份 / 恢复」对话框。
///
/// 正式运行（SQLite 仓储）时提供真实可用的备份导出与恢复；演示模式没有本地库，
/// 明确告知而不是给一个点了没反应的按钮。
Future<void> showBackupDialog(
  BuildContext context, {
  required PlannerRepository repository,
}) {
  if (repository is! SqlitePlannerRepository) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地备份与恢复'),
        content: const Text(
          '当前处于演示数据模式，没有本地数据库，无法备份或恢复。\n'
          '以正式模式启动后即可使用本地备份。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => _BackupDialog(repository: repository),
  );
}

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({required this.repository});

  final SqlitePlannerRepository repository;

  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  late final BackupService _service = BackupService(widget.repository);
  List<File> _files = const <File>[];
  bool _busy = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  String get _backupDirectory => _service.backupDirectory;

  void _refresh() {
    final directory = Directory(_backupDirectory);
    final files = <File>[];
    if (directory.existsSync()) {
      for (final entity in directory.listSync()) {
        if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
          files.add(entity);
        }
      }
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
    }
    setState(() => _files = files);
  }

  void _setMessage(String message, {bool error = false}) {
    setState(() {
      _message = message;
      _isError = error;
    });
  }

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    try {
      final path = await _service.exportJson();
      if (!mounted) return;
      _setMessage('已备份到 $path');
      _refresh();
    } on BackupException catch (error) {
      if (!mounted) return;
      _setMessage(error.message, error: true);
    } on LocalDatabaseException catch (error) {
      if (!mounted) return;
      _setMessage(error.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(File file) async {
    setState(() => _busy = true);
    try {
      final preview = await _service.inspect(file.path);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从备份恢复？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(preview.summary, style: AppText.body),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                '恢复会整体替换当前本地数据。执行前会自动保存一份当前数据的快照，'
                '恢复失败会自动回滚。',
                style: AppText.caption,
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey<String>('backup-restore-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('覆盖并恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final result = await _service.restore(preview, confirmOverwrite: true);
      if (!mounted) return;
      _setMessage(
        '已恢复 ${result.projects} 个项目、${result.spans} 个阶段、'
        '${result.tasks} 个任务、${result.notes} 条备注。'
        '恢复前快照：${result.safetyCopyPath}',
      );
    } on BackupException catch (error) {
      if (!mounted) return;
      _setMessage(error.message, error: true);
    } on LocalDatabaseException catch (error) {
      if (!mounted) return;
      _setMessage(error.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openFolder() async {
    try {
      PlannerPaths.ensureDirectory(_backupDirectory);
      await openDirectory(_backupDirectory);
    } on Object {
      if (!mounted) return;
      _setMessage('无法打开文件夹，请手动访问：$_backupDirectory', error: true);
    }
  }

  String _fileLabel(File file) {
    final stat = file.statSync();
    final size = (stat.size / 1024).toStringAsFixed(1);
    return '${p.basename(file.path)}  ·  $size KB';
  }

  @override
  Widget build(BuildContext context) {
    final dataPath =
        widget.repository.database.path ?? PlannerPaths.defaultDatabasePath();
    return AlertDialog(
      title: const Text('本地备份与恢复'),
      content: SizedBox(
        width: 600,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _InfoLine(label: '数据库', value: dataPath),
            _InfoLine(label: '备份目录', value: _backupDirectory),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  key: const ValueKey<String>('backup-now'),
                  onPressed: _busy ? null : _backupNow,
                  icon: const Icon(
                    Icons.save_alt_rounded,
                    size: AppSizes.iconSm,
                  ),
                  label: const Text('立即备份'),
                ),
                const SizedBox(width: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: AppSizes.iconSm),
                  label: const Text('刷新'),
                ),
                const SizedBox(width: AppSpacing.sm),
                TextButton.icon(
                  onPressed: _openFolder,
                  icon: const Icon(
                    Icons.folder_open_rounded,
                    size: AppSizes.iconSm,
                  ),
                  label: const Text('打开备份文件夹'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            Expanded(
              child: _files.isEmpty
                  ? const Center(
                      child: Text(
                        '还没有备份。点击「立即备份」生成第一个本地备份。',
                        style: AppText.caption,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _files.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final file = _files[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.description_outlined,
                            size: AppSizes.iconMd,
                            color: AppColors.textTertiary,
                          ),
                          title: Text(
                            _fileLabel(file),
                            style: AppText.small,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            key: ValueKey<String>(
                              'backup-restore-${p.basename(file.path)}',
                            ),
                            onPressed: _busy ? null : () => _restore(file),
                            child: const Text('恢复'),
                          ),
                        );
                      },
                    ),
            ),
            if (_message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Container(
                key: const ValueKey<String>('backup-status'),
                padding: const EdgeInsets.all(AppSpacing.sm + 2),
                decoration: BoxDecoration(
                  color: _isError ? AppColors.dangerSoft : AppColors.successSoft,
                  borderRadius: AppRadius.control,
                ),
                child: Text(
                  _message!,
                  style: AppText.caption.copyWith(
                    color: _isError ? AppColors.danger : AppColors.success,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label, style: AppText.caption),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
