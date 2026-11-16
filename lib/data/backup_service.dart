import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/models/models.dart';
import 'data_exception.dart';
import 'entity_codec.dart';
import 'planner_database.dart';
import 'planner_paths.dart';
import 'sql_schema.dart';
import 'sqlite_planner_repository.dart';

/// 备份文件的格式标识（人类可读，防止把别的 JSON 当备份导入）。
const String kBackupFormat = 'jihuatai.backup';

/// 备份信封格式版本（与数据库结构版本独立演进）。
const int kBackupFormatVersion = 1;

/// 一次备份的全部内容（含已软删除记录，保证恢复后不会"复活"已删数据）。
final class BackupContent {
  BackupContent({
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    required List<Project> projects,
    required List<PlanSpan> spans,
    required List<PlannerTask> tasks,
    required List<DailyNote> notes,
  }) : projects = List<Project>.unmodifiable(projects),
       spans = List<PlanSpan>.unmodifiable(spans),
       tasks = List<PlannerTask>.unmodifiable(tasks),
       notes = List<DailyNote>.unmodifiable(notes);

  /// 导出时数据库的结构版本。
  final int schemaVersion;

  /// 导出时的应用版本。
  final String appVersion;

  /// 导出时刻（UTC）。
  final DateTime exportedAt;

  final List<Project> projects;
  final List<PlanSpan> spans;
  final List<PlannerTask> tasks;
  final List<DailyNote> notes;

  int get liveProjectCount => _live(projects);
  int get liveSpanCount => _live(spans);
  int get liveTaskCount => _live(tasks);
  int get liveNoteCount => _live(notes);
  int get liveRecordCount =>
      liveProjectCount + liveSpanCount + liveTaskCount + liveNoteCount;
  int get totalRecordCount =>
      projects.length + spans.length + tasks.length + notes.length;
  int get deletedRecordCount => totalRecordCount - liveRecordCount;

  /// 契约形状：`schemaVersion / appVersion / exportedAt` + 四个数组。
  Map<String, Object?> toJson() => <String, Object?>{
    'format': kBackupFormat,
    'formatVersion': kBackupFormatVersion,
    'schemaVersion': schemaVersion,
    'appVersion': appVersion,
    'exportedAt': encodeInstant(exportedAt),
    'projects': projects.map(projectToJson).toList(growable: false),
    'planSpans': spans.map(planSpanToJson).toList(growable: false),
    'plannerTasks': tasks.map(plannerTaskToJson).toList(growable: false),
    'dailyNotes': notes.map(dailyNoteToJson).toList(growable: false),
  };

  /// 解析并校验备份 JSON；任何结构问题都以 [BackupException] 报出。
  static BackupContent fromJson(Map<String, Object?> json) {
    final rawFormat = json['format'];
    if (rawFormat != null && rawFormat != kBackupFormat) {
      throw BackupException(
        BackupErrorKind.invalidFormat,
        '这不是计划台的备份文件（format = $rawFormat）。',
      );
    }

    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int) {
      throw const BackupException(
        BackupErrorKind.invalidFormat,
        '备份文件缺少 schemaVersion，无法判断格式版本。',
      );
    }
    if (schemaVersion > kSchemaVersion) {
      throw BackupException(
        BackupErrorKind.newerSchema,
        '备份由更新版本的应用导出（结构 v$schemaVersion，当前应用支持到 v$kSchemaVersion）。'
        '请先升级应用，再用新版本恢复这份备份。',
      );
    }
    if (schemaVersion < 1) {
      throw BackupException(
        BackupErrorKind.invalidFormat,
        '备份文件的结构版本无效：v$schemaVersion。',
      );
    }

    final rawFormatVersion = json['formatVersion'];
    final formatVersion = rawFormatVersion is int ? rawFormatVersion : 0;
    if (formatVersion > kBackupFormatVersion) {
      throw BackupException(
        BackupErrorKind.newerSchema,
        '备份信封格式为 v$formatVersion，当前应用只支持到 v$kBackupFormatVersion。'
        '请先升级应用。',
      );
    }

    final rawAppVersion = json['appVersion'];
    final appVersion =
        rawAppVersion is String && rawAppVersion.trim().isNotEmpty
        ? rawAppVersion.trim()
        : '未知';

    final DateTime exportedAt;
    try {
      exportedAt = decodeInstant(json['exportedAt'], field: '备份导出时间');
    } on PlannerValidationException catch (error) {
      throw BackupException(
        BackupErrorKind.invalidFormat,
        '备份文件缺少合法的 exportedAt：${error.message}',
        cause: error,
      );
    }

    final content = BackupContent(
      schemaVersion: schemaVersion,
      appVersion: appVersion,
      exportedAt: exportedAt,
      projects: _parseList(json, 'projects', '项目', projectFromJson),
      spans: _parseList(json, 'planSpans', '跨天阶段', planSpanFromJson),
      tasks: _parseList(json, 'plannerTasks', '任务', plannerTaskFromJson),
      notes: _parseList(json, 'dailyNotes', '每日备注', dailyNoteFromJson),
    );
    content.validateReferences();
    return content;
  }

  /// 校验跨表引用与唯一性；不通过说明备份文件已损坏或被人改错。
  void validateReferences() {
    _ensureUniqueIds('项目', projects.map((entity) => entity.id));
    _ensureUniqueIds('跨天阶段', spans.map((entity) => entity.id));
    _ensureUniqueIds('任务', tasks.map((entity) => entity.id));
    _ensureUniqueIds('每日备注', notes.map((entity) => entity.id));

    final projectIds = projects.map((entity) => entity.id).toSet();
    final spanById = <String, PlanSpan>{
      for (final span in spans) span.id: span,
    };

    for (final span in spans) {
      if (!projectIds.contains(span.projectId)) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '阶段「${span.title}」引用了不存在的项目 ${span.projectId}。',
        );
      }
    }

    for (final task in tasks) {
      final projectId = task.projectId;
      if (projectId != null && !projectIds.contains(projectId)) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '任务「${task.title}」引用了不存在的项目 $projectId。',
        );
      }
      final spanId = task.spanId;
      if (spanId == null) continue;
      final span = spanById[spanId];
      if (span == null) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '任务「${task.title}」引用了不存在的阶段 $spanId。',
        );
      }
      if (span.projectId != projectId) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '任务「${task.title}」关联的阶段不属于同一项目。',
        );
      }
    }

    final liveNoteDates = <String>{};
    for (final note in notes) {
      if (note.isDeleted) continue;
      if (!liveNoteDates.add(note.date.iso)) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '备份中存在重复的每日备注：${note.date.iso}。',
        );
      }
    }
  }

  static void _ensureUniqueIds(String label, Iterable<String> ids) {
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '备份中「$label」出现重复 ID：$id。',
        );
      }
    }
  }

  static int _live<T extends PlannerEntity>(List<T> entities) =>
      entities.where((entity) => !entity.isDeleted).length;

  static List<T> _parseList<T>(
    Map<String, Object?> json,
    String key,
    String label,
    T Function(Map<String, Object?>) parse,
  ) {
    final raw = json[key];
    if (raw is! List<Object?>) {
      throw BackupException(BackupErrorKind.invalidFormat, '备份文件缺少「$key」数组。');
    }
    final parsed = <T>[];
    for (var index = 0; index < raw.length; index++) {
      final element = raw[index];
      if (element is! Map<Object?, Object?>) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '备份文件的「$key」第 ${index + 1} 条不是对象。',
        );
      }
      try {
        parsed.add(parse(_toStringKeyedMap(element)));
      } on PlannerValidationException catch (error) {
        throw BackupException(
          BackupErrorKind.invalidFormat,
          '备份中第 ${index + 1} 条$label数据不合法：${error.message}',
          cause: error,
        );
      }
    }
    return parsed;
  }

  static Map<String, Object?> _toStringKeyedMap(Map<Object?, Object?> source) {
    final result = <String, Object?>{};
    for (final entry in source.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const BackupException(
          BackupErrorKind.invalidFormat,
          '备份文件中包含非字符串键。',
        );
      }
      result[key] = entry.value;
    }
    return result;
  }
}

/// 恢复前对备份文件的预览结果（用于"先看内容、再决定是否覆盖"）。
final class BackupPreview {
  const BackupPreview({
    required this.path,
    required this.content,
    required this.bytes,
    required this.formatVersion,
  });

  final String path;
  final BackupContent content;
  final int bytes;
  final int formatVersion;

  int get liveRecordCount => content.liveRecordCount;

  /// 可直接展示给用户的一句话摘要。
  String get summary =>
      '备份包含 ${content.liveProjectCount} 个项目、${content.liveSpanCount} 个跨天阶段、'
      '${content.liveTaskCount} 个任务、${content.liveNoteCount} 条每日备注'
      '（另含 ${content.deletedRecordCount} 条已删除记录）；'
      '导出于 ${content.exportedAt.toLocal()}，应用版本 ${content.appVersion}。';
}

/// 恢复结果。
final class RestoreResult {
  const RestoreResult({
    required this.projects,
    required this.spans,
    required this.tasks,
    required this.notes,
    required this.safetyCopyPath,
    required this.verifiedAt,
  });

  final int projects;
  final int spans;
  final int tasks;
  final int notes;

  /// 恢复前自动保存的旧数据快照（SQLite 一致性导出）。
  final String safetyCopyPath;

  /// 恢复完成并校验通过的确认时刻（UTC）。
  final DateTime verifiedAt;

  @override
  String toString() =>
      'RestoreResult(项目 $projects, 阶段 $spans, 任务 $tasks, 备注 $notes, '
      '旧数据快照 $safetyCopyPath)';
}

/// 本地数据备份与恢复。
///
/// 两种产物，各司其职：
/// - **JSON 备份**（[exportJson] / [inspect] / [restore]）：给人看、可校验、
///   带格式与结构版本，是"导出/导入"的正式格式；
/// - **SQLite 快照**（[snapshotDatabase]）：走 `VACUUM INTO`，拿到的是事务级
///   一致副本，用于恢复前保护现场、以及排障时取证。
///
/// 恢复流程固定为：**校验备份 → 自动快照当前数据 → 单事务整体替换 →
/// 回读比对校验 → 通知界面刷新**。任何一步失败都会整体回滚，旧数据不受影响。
final class BackupService {
  BackupService(
    this.repository, {
    String? appVersion,
    DateTime Function()? clock,
    String? backupDirectory,
  }) : _appVersion = appVersion ?? '1.0.0',
       _clock = clock ?? DateTime.now,
       _backupDirectory = backupDirectory?.trim();

  final SqlitePlannerRepository repository;
  final String _appVersion;
  final DateTime Function() _clock;
  final String? _backupDirectory;

  /// 备份文件默认目录：`%APPDATA%\计划台\data\backups`。
  String get backupDirectory =>
      _backupDirectory ?? PlannerPaths.defaultBackupDirectory();

  /// 导出 JSON 备份，返回文件绝对路径。
  ///
  /// [targetPath] 为空时自动命名到 [backupDirectory]。写入先落 `.tmp` 再改名，
  /// 中途失败不会留下半个备份文件。
  Future<String> exportJson({String? targetPath}) async {
    final content = _collect();
    final text = const JsonEncoder.withIndent('  ').convert(content.toJson());
    final path =
        targetPath ??
        p.join(backupDirectory, 'jihuatai-backup-${_timestamp()}.json');
    PlannerPaths.ensureParentOf(path);

    final temporary = File('$path.tmp');
    try {
      await temporary.writeAsString(text, flush: true);
      final target = File(path);
      if (target.existsSync()) await target.delete();
      await temporary.rename(path);
    } on FileSystemException catch (error) {
      throw BackupException(
        BackupErrorKind.ioFailure,
        '写入备份文件失败：${error.message}',
        cause: error,
      );
    }
    return path;
  }

  /// 读取并校验备份文件，不修改数据库。
  Future<BackupPreview> inspect(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw BackupException(BackupErrorKind.fileNotFound, '备份文件不存在：$path');
    }
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (error) {
      throw BackupException(
        BackupErrorKind.ioFailure,
        '读取备份文件失败：${error.message}',
        cause: error,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw BackupException(
        BackupErrorKind.invalidFormat,
        '备份文件不是合法的 JSON：${error.message}',
        cause: error,
      );
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const BackupException(
        BackupErrorKind.invalidFormat,
        '备份文件的顶层结构必须是 JSON 对象。',
      );
    }

    final content = BackupContent.fromJson(
      BackupContent._toStringKeyedMap(decoded),
    );
    return BackupPreview(
      path: path,
      content: content,
      bytes: file.lengthSync(),
      formatVersion: kBackupFormatVersion,
    );
  }

  /// 用备份整体覆盖本地数据。
  ///
  /// [confirmOverwrite] 为 false 且本地已有数据时拒绝执行（不静默覆盖）。
  Future<RestoreResult> restore(
    BackupPreview preview, {
    bool confirmOverwrite = false,
  }) async {
    final database = repository.database;
    final live = _liveRecordCount(database);
    if (live > 0 && !confirmOverwrite) {
      throw BackupException(
        BackupErrorKind.overwriteRefused,
        '当前本地已有 $live 条数据，恢复会整体覆盖它们。'
        '请先备份或确认后再执行恢复。',
      );
    }

    final content = preview.content;
    // 恢复前保护现有数据：即便后面失败，旧数据也有一份完整快照。
    final safetyCopy = snapshotDatabase(prefix: 'pre-restore');

    try {
      database.transaction(() {
        final handle = database.handle;
        handle.execute('DELETE FROM planner_tasks');
        handle.execute('DELETE FROM plan_spans');
        handle.execute('DELETE FROM daily_notes');
        handle.execute('DELETE FROM projects');

        for (final project in content.projects) {
          handle.execute(insertProjectSql, projectInsertParams(project));
        }
        for (final span in content.spans) {
          handle.execute(insertSpanSql, spanInsertParams(span));
        }
        for (final task in content.tasks) {
          handle.execute(insertTaskSql, taskInsertParams(task));
        }
        for (final note in content.notes) {
          handle.execute(insertNoteSql, noteInsertParams(note));
        }

        handle.execute(
          'INSERT INTO change_log(entity_type, entity_id, operation, revision, changed_at) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>[
            'database',
            'full',
            'restore',
            content.totalRecordCount,
            encodeInstant(_clock().toUtc()),
          ],
        );

        _verifyRestored(handle, content);
      });
    } on BackupException catch (error) {
      throw BackupException(
        error.kind,
        '${error.message}（现有数据已回滚保留；旧数据快照：$safetyCopy）',
        cause: error,
      );
    } on SqliteException catch (error) {
      throw BackupException(
        BackupErrorKind.ioFailure,
        '恢复备份失败，现有数据已回滚保留（旧数据快照：$safetyCopy）：${error.message}',
        cause: error,
      );
    } on LocalDatabaseException catch (error) {
      throw BackupException(
        BackupErrorKind.integrityFailed,
        '恢复后校验失败，现有数据已回滚保留（旧数据快照：$safetyCopy）：${error.message}',
        cause: error,
      );
    }

    database.notifyChanged();
    return RestoreResult(
      projects: content.projects.length,
      spans: content.spans.length,
      tasks: content.tasks.length,
      notes: content.notes.length,
      safetyCopyPath: safetyCopy,
      verifiedAt: _clock().toUtc(),
    );
  }

  /// 用 `VACUUM INTO` 导出一致性数据库快照（可以随时取，不必先关库）。
  String snapshotDatabase({String? directory, String prefix = 'snapshot'}) {
    final dir = directory ?? backupDirectory;
    PlannerPaths.ensureDirectory(dir);
    final target = p.join(dir, '$prefix-${_timestamp()}-${_randomSuffix()}.db');
    repository.database.snapshotTo(target);
    _verifySnapshotFile(target);
    return target;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  BackupContent _collect() {
    final database = repository.database;
    final handle = database.handle;
    // 在一个读事务里取全部表，保证四张表来自同一快照。
    return database.transaction(
      () => BackupContent(
        schemaVersion: PlannerDatabase.schemaVersion,
        appVersion: _appVersion,
        exportedAt: _clock().toUtc(),
        projects: handle
            .select('SELECT $projectColumns FROM projects $projectOrderClause')
            .map(projectFromRow)
            .toList(growable: false),
        spans: handle
            .select('SELECT $spanColumns FROM plan_spans $spanOrderClause')
            .map(planSpanFromRow)
            .toList(growable: false),
        tasks: handle
            .select('SELECT $taskColumns FROM planner_tasks $taskOrderClause')
            .map(plannerTaskFromRow)
            .toList(growable: false),
        notes: handle
            .select('SELECT $noteColumns FROM daily_notes $noteOrderClause')
            .map(dailyNoteFromRow)
            .toList(growable: false),
      ),
    );
  }

  void _verifySnapshotFile(String path) {
    Database? handle;
    try {
      handle = sqlite3.open(path, mode: OpenMode.readOnly);
      final version = PlannerDatabase.readSchemaVersion(handle);
      if (version > PlannerDatabase.schemaVersion) {
        throw BackupException(
          BackupErrorKind.newerSchema,
          '导出的数据库快照版本为 v$version，高于当前应用支持的 v${PlannerDatabase.schemaVersion}。',
        );
      }
      String? failure;
      for (final row in handle.select('PRAGMA quick_check')) {
        final value = row['quick_check'];
        if (value is String && value != 'ok') failure = value;
      }
      if (failure != null) {
        throw BackupException(
          BackupErrorKind.integrityFailed,
          '导出的数据库快照未通过完整性检查：$failure',
        );
      }
    } on SqliteException catch (error) {
      throw BackupException(
        BackupErrorKind.ioFailure,
        '导出的数据库快照无法打开：${error.message}',
        cause: error,
      );
    } finally {
      handle?.close();
    }
  }

  void _verifyRestored(Database handle, BackupContent expected) {
    final failure = _quickCheckFailure(handle);
    if (failure != null) {
      throw BackupException(
        BackupErrorKind.integrityFailed,
        '恢复后完整性检查未通过：$failure',
      );
    }

    final projects = handle
        .select('SELECT $projectColumns FROM projects')
        .map(projectFromRow)
        .toList(growable: false);
    final spans = handle
        .select('SELECT $spanColumns FROM plan_spans')
        .map(planSpanFromRow)
        .toList(growable: false);
    final tasks = handle
        .select('SELECT $taskColumns FROM planner_tasks')
        .map(plannerTaskFromRow)
        .toList(growable: false);
    final notes = handle
        .select('SELECT $noteColumns FROM daily_notes')
        .map(dailyNoteFromRow)
        .toList(growable: false);

    if (!_sameEntities(projects, expected.projects)) {
      throw const BackupException(
        BackupErrorKind.integrityFailed,
        '恢复后项目数据与备份不一致。',
      );
    }
    if (!_sameEntities(spans, expected.spans)) {
      throw const BackupException(
        BackupErrorKind.integrityFailed,
        '恢复后跨天阶段数据与备份不一致。',
      );
    }
    if (!_sameEntities(tasks, expected.tasks)) {
      throw const BackupException(
        BackupErrorKind.integrityFailed,
        '恢复后任务数据与备份不一致。',
      );
    }
    if (!_sameEntities(notes, expected.notes)) {
      throw const BackupException(
        BackupErrorKind.integrityFailed,
        '恢复后每日备注数据与备份不一致。',
      );
    }
  }

  static bool _sameEntities<T extends PlannerEntity>(
    List<T> actual,
    List<T> expected,
  ) {
    if (actual.length != expected.length) return false;
    final byId = <String, T>{for (final entity in actual) entity.id: entity};
    for (final entity in expected) {
      final stored = byId[entity.id];
      if (stored != entity) return false;
    }
    return true;
  }

  static String? _quickCheckFailure(Database handle) {
    for (final row in handle.select('PRAGMA quick_check')) {
      final value = row['quick_check'];
      if (value is String && value != 'ok') return value;
    }
    return null;
  }

  static int _liveRecordCount(PlannerDatabase database) {
    var total = 0;
    for (final table in const <String>[
      'projects',
      'plan_spans',
      'planner_tasks',
      'daily_notes',
    ]) {
      final row = database.handle
          .select('SELECT COUNT(*) AS c FROM $table WHERE deleted_at IS NULL')
          .first;
      final value = row['c'];
      if (value is int) total += value;
    }
    return total;
  }

  String _timestamp() {
    final now = _clock().toLocal();
    final date =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return '$date-$time';
  }

  static String _randomSuffix() =>
      Random().nextInt(1 << 30).toRadixString(16).padLeft(8, '0');
}
