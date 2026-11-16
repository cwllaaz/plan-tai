import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/data.dart';
import 'android_storage.dart';
import 'app_paths.dart';

/// Android 本地备份 / 恢复的传输适配层。
///
/// 与 Windows 的差异只有**文件怎么交给用户**：
/// - Windows：写 `%APPDATA%\计划台\data\backups`，用资源管理器打开；
/// - Android：写应用私有目录（用户看不见），再用系统 SAF 选择器导出/导入。
///
/// 因此这里**不重新实现备份格式**，全部复用 [BackupService]：
/// - 导出：`BackupService.exportJson()` 生成 JSON（与 Windows 完全同一格式、
///   同一 `format/formatVersion/schemaVersion` 信封，两端可直接互相导入）；
/// - 校验：`BackupService.inspect()`（格式、结构版本、跨表引用、重复 ID 全查）；
/// - 恢复：`BackupService.restore(confirmOverwrite: true)`（恢复前自动
///   `VACUUM INTO` 快照当前库，单事务整体替换、回读比对，失败自动回滚）。
///
/// 本层额外承担的两条产品约束：
/// 1. **恢复前必须提示可能覆盖数据**：`restore` 强制调用 [confirmOverwrite] 回调，
///    回调返回 false 就不写库（不存在「忘了确认就直接覆盖」的调用路径）；
/// 2. **临时文件只放缓存目录**：导入的备份先由原生侧拷贝到 `cache/imports/`，
///    校验/恢复完成后立即删除；数据库与正式备份永远不落缓存。
final class AndroidBackupTransfer {
  AndroidBackupTransfer({
    required this.repository,
    AndroidStorageChannel? storage,
    String? appVersion,
    String? backupDirectory,
    this.scratchDirectory,
  }) : _storage = storage ?? AndroidStorageChannel(),
       _service = BackupService(
         repository,
         appVersion: appVersion,
         backupDirectory: backupDirectory,
       );

  final SqlitePlannerRepository repository;
  final AndroidStorageChannel _storage;
  final BackupService _service;

  /// 仅测试注入：返回临时中转目录。
  final Future<String> Function()? scratchDirectory;

  /// 应用私有目录里的备份目录（`<base>/data/backups`）。
  String get backupDirectory => _service.backupDirectory;

  /// 导出当前全部数据为 JSON 备份，并让用户选择保存位置。
  ///
  /// 返回 [BackupExportOutcome.cancelled] 表示用户放弃保存（不是错误）。
  Future<BackupExportOutcome> exportJsonToUser() async {
    final scratch = await _scratch();
    final fileName = 'jihuatai-backup-${_timestamp()}.json';
    final path = p.join(scratch, fileName);
    try {
      // 与 Windows 完全相同的导出逻辑（单读事务内取四张表，格式一致）。
      await _service.exportJson(targetPath: path);
      final bytes = await File(path).readAsBytes();
      final result = await _storage.createDocument(
        fileName: fileName,
        mimeType: AndroidStorageChannel.jsonBackupMimeType,
        bytes: bytes,
      );
      if (result == null) return const BackupExportOutcome.cancelled();
      return BackupExportOutcome(
        fileName: result.displayName ?? fileName,
        bytes: result.bytes,
      );
    } finally {
      _deleteQuietly(path);
    }
  }

  /// 导出 SQLite 一致性快照（`VACUUM INTO`）给用户。
  ///
  /// 这是**排障/取证**用的原始库文件，不是正式导入格式（应用内不提供从
  /// .db 快照恢复的入口）；日常迁移请用 [exportJsonToUser]。
  Future<BackupExportOutcome> exportDatabaseSnapshotToUser() async {
    final scratch = await _scratch();
    String? snapshotPath;
    try {
      snapshotPath = _service.snapshotDatabase(
        directory: scratch,
        prefix: 'jihuatai-snapshot-${_timestamp()}',
      );
      final bytes = await File(snapshotPath).readAsBytes();
      final result = await _storage.createDocument(
        fileName: p.basename(snapshotPath),
        mimeType: AndroidStorageChannel.databaseSnapshotMimeType,
        bytes: bytes,
      );
      if (result == null) return const BackupExportOutcome.cancelled();
      return BackupExportOutcome(
        fileName: result.displayName ?? p.basename(snapshotPath),
        bytes: result.bytes,
      );
    } finally {
      if (snapshotPath != null) _deleteQuietly(snapshotPath);
    }
  }

  /// 让用户从系统文件选择器挑一份备份，读取并校验后返回预览。
  ///
  /// 返回 `preview == null` 表示用户取消。校验失败抛 [BackupException]
  /// （文件不是计划台备份 / 来自更新版本 / 结构损坏 / 引用不一致）。
  /// 校验通过时 [BackupImportOutcome.temporaryPath] 是应用缓存里的副本，
  /// 调用方在完成/放弃恢复时必须 [discardImport]（或交给 [restore] 自动清理）。
  Future<BackupImportOutcome> pickAndInspectBackup() async {
    final picked = await _storage.openDocument(
      mimeTypes: const <String>[
        AndroidStorageChannel.jsonBackupMimeType,
        'text/plain',
        'application/octet-stream',
      ],
    );
    if (picked == null) return const BackupImportOutcome();
    try {
      final preview = await _service.inspect(picked.path);
      return BackupImportOutcome(
        preview: preview,
        temporaryPath: picked.path,
        displayName: picked.displayName,
      );
    } on Object {
      // 校验失败：立刻清掉缓存副本，不留垃圾文件。
      discardImport(picked.path);
      rethrow;
    }
  }

  /// 用一份**已校验**的备份覆盖本地数据。
  ///
  /// [confirmOverwrite] 必须展示备份摘要与覆盖风险并由用户确认；返回 false
  /// 时不做任何写入。恢复成功后返回 [BackupRestoreOutcome.restored]。
  Future<BackupRestoreOutcome> restore({
    required BackupPreview preview,
    required Future<bool> Function(BackupPreview preview) confirmOverwrite,
    String? temporaryPath,
  }) async {
    try {
      final confirmed = await confirmOverwrite(preview);
      if (!confirmed) return const BackupRestoreOutcome.cancelled();
      final result = await _service.restore(preview, confirmOverwrite: true);
      return BackupRestoreOutcome(result: result);
    } finally {
      if (temporaryPath != null) discardImport(temporaryPath);
    }
  }

  /// 列出应用私有目录里已有的备份文件（最新在前），供备份页展示。
  Future<List<LocalBackupFile>> listLocalBackups() async {
    final directory = Directory(backupDirectory);
    if (!directory.existsSync()) return const <LocalBackupFile>[];
    final files = <LocalBackupFile>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.json')) continue;
      try {
        final stat = entity.statSync();
        files.add(
          LocalBackupFile(
            path: entity.path,
            name: p.basename(entity.path),
            bytes: stat.size,
            modifiedAt: stat.modified,
          ),
        );
      } on FileSystemException {
        // 单个文件读不到不影响列表其余项。
      }
    }
    files.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return files;
  }

  /// 读取并校验应用私有目录里的某份备份（不弹系统选择器）。
  Future<BackupPreview> inspectLocalBackup(String path) => _service.inspect(path);

  /// 恢复应用私有目录里的备份；同样强制走 [confirmOverwrite]。
  Future<BackupRestoreOutcome> restoreLocalBackup({
    required BackupPreview preview,
    required Future<bool> Function(BackupPreview preview) confirmOverwrite,
  }) => restore(preview: preview, confirmOverwrite: confirmOverwrite);

  /// 删除导入时复制到缓存的临时文件（用户取消/校验失败时调用）。
  void discardImport(String path) => _deleteQuietly(path);

  /// 清理缓存目录里过期的中转文件（启动或进入备份页时调用，可重复调用）。
  Future<void> cleanupScratch({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final directory = Directory(await _scratch());
    if (!directory.existsSync()) return;
    final deadline = DateTime.now().subtract(maxAge);
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      try {
        if (entity.statSync().modified.isBefore(deadline)) {
          entity.deleteSync();
        }
      } on FileSystemException {
        // 清理失败不影响功能。
      }
    }
  }

  Future<String> _scratch() async {
    final injected = scratchDirectory;
    final path = injected != null
        ? await injected()
        : await AppPaths.resolveScratchDirectory();
    final directory = Directory(path);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return path;
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 删除临时文件失败不影响主流程。
    }
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final date =
        '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}';
    final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '$date-$time';
  }
}

/// 一次导出（含用户取消）的结果。
final class BackupExportOutcome {
  const BackupExportOutcome({required this.fileName, required this.bytes});

  const BackupExportOutcome.cancelled() : fileName = null, bytes = 0;

  /// 用户实际保存的文件名；null 表示用户取消。
  final String? fileName;

  final int bytes;

  bool get isExported => fileName != null;
}

/// 一次导入（含用户取消）的结果。
final class BackupImportOutcome {
  const BackupImportOutcome({
    this.preview,
    this.temporaryPath,
    this.displayName,
  });

  /// 校验通过的备份预览；null 表示用户取消。
  final BackupPreview? preview;

  /// 应用缓存里的临时副本路径（恢复/放弃后需删除）。
  final String? temporaryPath;

  /// 原始文件名（展示用）。
  final String? displayName;

  bool get hasPreview => preview != null;
}

/// 一次恢复（含用户取消）的结果。
final class BackupRestoreOutcome {
  const BackupRestoreOutcome({required this.result});

  const BackupRestoreOutcome.cancelled() : result = null;

  /// 恢复结果；null 表示用户取消。
  final RestoreResult? result;

  bool get isRestored => result != null;
}

/// 应用私有目录里的一份备份文件。
final class LocalBackupFile {
  const LocalBackupFile({
    required this.path,
    required this.name,
    required this.bytes,
    required this.modifiedAt,
  });

  final String path;
  final String name;
  final int bytes;
  final DateTime modifiedAt;

  String get sizeLabel => '${(bytes / 1024).toStringAsFixed(1)} KB';
}

/// 便捷工厂：给移动端 UI 直接用的默认实例。
AndroidBackupTransfer createAndroidBackupTransfer({
  required SqlitePlannerRepository repository,
  String? appVersion,
}) => AndroidBackupTransfer(repository: repository, appVersion: appVersion);
