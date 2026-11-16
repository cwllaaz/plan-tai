import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../core/contracts/contracts.dart';
import '../../core/theme/theme.dart';
import '../../data/data.dart';
import '../../platform/platform.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';

/// 「我的 → 数据与备份」：数据位置、本地备份创建与恢复、导出到系统文件夹、从文件导入恢复。
///
/// 备份文件写在应用私有目录（`<data>/backups`），由现有 [BackupService] 完成；
/// Android 上再通过平台层 [AndroidBackupTransfer]（SAF，零存储权限）让用户把
/// **与 Windows 完全同格式**的 JSON 备份导出到「下载/网盘」，或从文件选择器
/// 导回并恢复。恢复前强制展示摘要与覆盖风险，并自动生成 pre-restore 快照。
class MobileDataPage extends StatefulWidget {
  const MobileDataPage({
    super.key,
    required this.repository,
    this.databasePath,
    this.dataDirectory,
    required this.isDemoData,
  });

  final PlannerRepository repository;
  final String? databasePath;
  final String? dataDirectory;
  final bool isDemoData;

  @override
  State<MobileDataPage> createState() => _MobileDataPageState();
}

class _MobileDataPageState extends State<MobileDataPage> {
  bool _busy = false;
  List<String> _backups = const <String>[];

  BackupService? get _service {
    final repository = widget.repository;
    if (repository is! SqlitePlannerRepository) return null;
    return BackupService(repository);
  }

  /// Android 文件通道（SAF）：导出/导入需要真实 SQLite 仓储与 Android 平台。
  AndroidBackupTransfer? get _transfer {
    if (!Platform.isAndroid) return null;
    final repository = widget.repository;
    if (repository is! SqlitePlannerRepository) return null;
    return createAndroidBackupTransfer(repository: repository);
  }

  @override
  void initState() {
    super.initState();
    _refreshBackups();
  }

  void _refreshBackups() {
    final service = _service;
    if (service == null) return;
    final directory = Directory(service.backupDirectory);
    if (!directory.existsSync()) {
      setState(() => _backups = const <String>[]);
      return;
    }
    final files = directory
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.json'))
        .map((File file) => file.path)
        .toList();
    files.sort((String a, String b) => b.compareTo(a));
    setState(() => _backups = List<String>.unmodifiable(files));
  }

  Future<void> _createBackup() async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    try {
      final path = await service.exportJson();
      if (!mounted) return;
      _refreshBackups();
      showMobileSnack(context, '已创建备份：${p.basename(path)}');
    } on Object catch (error) {
      if (!mounted) return;
      showMobileSnack(
        context,
        error is BackupException ? error.message : '创建备份失败，请稍后重试',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 通过系统「保存到…」把 JSON 备份导出到用户选择的位置（下载/网盘等）。
  Future<void> _exportToUser() async {
    final transfer = _transfer;
    if (transfer == null || _busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await transfer.exportJsonToUser();
      if (!mounted) return;
      if (!outcome.isExported) {
        showMobileSnack(context, '已取消导出');
        return;
      }
      showMobileSnack(context, '已导出：${outcome.fileName}');
    } on Object catch (error) {
      if (!mounted) return;
      showMobileSnack(
        context,
        error is BackupException ? error.message : '导出失败，请稍后重试',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从系统文件选择器导入备份：校验 → 展示摘要与覆盖风险 → 恢复。
  Future<void> _importFromFile() async {
    final transfer = _transfer;
    if (transfer == null || _busy) return;
    setState(() => _busy = true);
    BackupImportOutcome? picked;
    try {
      picked = await transfer.pickAndInspectBackup();
      final preview = picked.preview;
      if (!mounted) return;
      if (preview == null) {
        showMobileSnack(context, '已取消导入');
        return;
      }
      final confirmed = await showMobileConfirm(
        context,
        title: '从文件恢复并覆盖本地数据？',
        message:
            '${picked.displayName ?? '所选备份'}\n\n'
            '${preview.summary}\n\n'
            '恢复会整体覆盖当前本机数据；恢复前会自动生成一份安全快照。'
            '这个操作不能自动撤销。',
        confirmLabel: '覆盖恢复',
        danger: true,
      );
      if (!confirmed || !mounted) {
        if (picked.temporaryPath != null) {
          // 取消恢复时清掉缓存副本（文件仍可从系统选择器重新选）。
          transfer.discardImport(picked.temporaryPath!);
        }
        return;
      }
      final outcome = await transfer.restore(
        preview: preview,
        confirmOverwrite: (BackupPreview _) async => true,
        temporaryPath: picked.temporaryPath,
      );
      if (!mounted) return;
      if (!outcome.isRestored) {
        showMobileSnack(context, '已取消恢复');
        return;
      }
      _refreshBackups();
      showMobileSnack(context, '已从备份恢复，数据已刷新');
    } on Object catch (error) {
      if (!mounted) return;
      showMobileSnack(
        context,
        error is BackupException ? error.message : '恢复失败，请稍后重试',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }


  Future<void> _restore(String path) async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    try {
      final preview = await service.inspect(path);
      if (!mounted) return;
      final confirmed = await showMobileConfirm(
        context,
        title: '用这个备份覆盖本地数据？',
        message:
            '${preview.summary}\n\n'
            '恢复会整体覆盖当前本机数据；恢复前会自动生成一份安全快照。'
            '这个操作不能自动撤销。',
        confirmLabel: '覆盖恢复',
        danger: true,
      );
      if (!confirmed || !mounted) return;
      await service.restore(preview, confirmOverwrite: true);
      if (!mounted) return;
      _refreshBackups();
      showMobileSnack(context, '已从备份恢复，数据已刷新');
    } on Object catch (error) {
      if (!mounted) return;
      showMobileSnack(
        context,
        error is BackupException ? error.message : '恢复失败，请稍后重试',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dataDirectory =
        widget.dataDirectory ??
        (widget.databasePath == null ? null : p.dirname(widget.databasePath!));
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            MobilePageHeader(
              title: '数据与备份',
              subtitle: widget.isDemoData ? '演示数据 · 不写入磁盘' : '本地优先 · 数据不出本机',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  MobileMetrics.pagePadding,
                  AppSpacing.md,
                  MobileMetrics.pagePadding,
                  AppSpacing.xxxl,
                ),
                children: <Widget>[
                  MobileCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const MobileSectionHeader(title: '数据位置'),
                        const SizedBox(height: AppSpacing.sm),
                        _PathRow(
                          label: '数据库',
                          value: widget.databasePath ?? '内存（演示模式）',
                        ),
                        _PathRow(label: '数据目录', value: dataDirectory ?? '未知'),
                        _PathRow(
                          label: '备份目录',
                          value: _service?.backupDirectory ?? '不可用（演示模式）',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  MobileCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const MobileSectionHeader(
                          title: '本地备份',
                          subtitle: 'JSON 备份，包含项目、任务、安排与每日备注',
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (_service == null)
                          Text(
                            '演示模式使用内存数据，不会产生备份文件。'
                            '正式运行时可直接在这里创建与恢复备份。',
                            style: AppText.caption.copyWith(fontSize: 12.5),
                          )
                        else ...<Widget>[
                          MobilePrimaryButton(
                            key: const ValueKey<String>('mobile-backup-create'),
                            label: _busy ? '处理中…' : '创建备份',
                            icon: Icons.save_alt_rounded,
                            expand: true,
                            onPressed: _busy ? null : _createBackup,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          if (_backups.isEmpty)
                            Text(
                              '还没有备份文件。建议在批量改动或恢复数据前先创建一份。',
                              style: AppText.caption.copyWith(fontSize: 12.5),
                            )
                          else
                            for (final path in _backups.take(10))
                              MobileListTile(
                                key: ValueKey<String>('mobile-backup-$path'),
                                dense: true,
                                title: p.basename(path),
                                subtitle: _describe(path),
                                leading: const Icon(
                                  Icons.description_outlined,
                                  size: 18,
                                  color: AppColors.textTertiary,
                                ),
                                trailing: const Icon(
                                  Icons.restore_rounded,
                                  size: 18,
                                  color: AppColors.textTertiary,
                                ),
                                onTap: _busy ? null : () => _restore(path),
                              ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_transfer != null) ...<Widget>[
                    MobileCard(
                      key: const ValueKey<String>('mobile-backup-transfer'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const MobileSectionHeader(
                            title: '导出与导入',
                            subtitle: '与 Windows 版同一 JSON 格式，可跨设备迁移',
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          MobilePrimaryButton(
                            key: const ValueKey<String>('mobile-backup-export'),
                            label: _busy ? '处理中…' : '导出备份到文件',
                            icon: Icons.ios_share_rounded,
                            expand: true,
                            onPressed: _busy ? null : _exportToUser,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          MobileSecondaryButton(
                            key: const ValueKey<String>('mobile-backup-import'),
                            label: _busy ? '处理中…' : '从文件导入并恢复',
                            icon: Icons.file_open_rounded,
                            expand: true,
                            onPressed: _busy ? null : _importFromFile,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  MobileCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const MobileSectionHeader(title: '关于备份文件'),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '· 备份保存在应用私有目录，卸载应用会一并删除，请定期导出。\n'
                          '· 导出的 JSON 与 Windows 版逐字段相同，可在两端互相导入恢复；'
                          '文件通过系统「保存到…/打开文件」选择位置，不申请存储权限。\n'
                          '· 本地备份恢复与文件导入恢复都会先自动生成一份 pre-restore 快照。',
                          style: AppText.caption.copyWith(
                            fontSize: 12,
                            height: 1.6,
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

  String _describe(String path) {
    final file = File(path);
    if (!file.existsSync()) return '文件不存在';
    final size = file.lengthSync();
    final modified = file.statSync().modified;
    final sizeText = size >= 1024 * 1024
        ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(size / 1024).ceil()} KB';
    return '$sizeText · ${_formatTime(modified)}';
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: AppText.micro.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: AppText.small.copyWith(
              fontSize: 12,
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
