import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'data_exception.dart';
import 'planner_paths.dart';
import 'sql_schema.dart';

/// 本地 SQLite 数据库的打开 / 关闭 / 事务 / 迁移门面。
///
/// 职责边界：
/// - 只负责"连接 + 结构 + 一致性保证"，不认识业务实体（那在
///   `SqlitePlannerRepository` 里）；
/// - 所有写操作都必须走 [transaction]，保证级联写入要么全成、要么全不成；
/// - 打开时做完整性检查，**发现损坏就停下并提示从备份恢复**，绝不静默重建库
///   （那会直接抹掉用户真实数据）。
final class PlannerDatabase {
  PlannerDatabase._(this._handle, this.path);

  /// 支持的结构版本（与 [kSchemaVersion] 同源）。
  static int get schemaVersion => kSchemaVersion;

  Database? _handle;

  /// 数据库文件的绝对路径；内存库为 null。
  final String? path;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<void> _localWrites =
      StreamController<void>.broadcast();
  int _transactionDepth = 0;
  bool _closed = false;

  /// 打开（必要时创建）数据库。
  ///
  /// [path] 为 null 时用 [PlannerPaths.defaultDatabasePath]，
  /// 即 `%APPDATA%\计划台\data\app.db`；[inMemory] 仅供测试。
  /// 打开失败、版本过新、完整性检查失败都抛 [LocalDatabaseException]。
  static PlannerDatabase open({
    String? path,
    bool inMemory = false,
    int busyTimeoutMs = 5000,
  }) {
    final resolvedPath = inMemory ? null : _resolvePath(path);
    if (resolvedPath != null) {
      try {
        PlannerPaths.ensureParentOf(resolvedPath);
      } on FileSystemException catch (error) {
        throw LocalDatabaseException(
          '无法创建本地数据目录（${error.message}）。请检查磁盘与权限。',
          cause: error,
        );
      }
    }

    final Database handle;
    try {
      handle = inMemory ? sqlite3.openInMemory() : sqlite3.open(resolvedPath!);
    } on SqliteException catch (error) {
      throw LocalDatabaseException(
        '无法打开本地数据库文件：${resolvedPath ?? ':memory:'}（${error.message}）',
        cause: error,
      );
    }

    try {
      _configure(handle, inMemory: inMemory, busyTimeoutMs: busyTimeoutMs);
      final fileVersion = readSchemaVersion(handle);
      if (fileVersion > kSchemaVersion) {
        throw LocalDatabaseException(
          '本地数据库结构版本为 v$fileVersion，高于当前应用支持的 v$kSchemaVersion。'
          '请先升级应用再打开；程序不会删除或重建你的数据。',
        );
      }
      if (fileVersion < kSchemaVersion) {
        applyMigrations(handle, from: fileVersion, to: kSchemaVersion);
      }
      _quickCheck(handle, resolvedPath ?? ':memory:');
    } catch (error) {
      handle.close();
      if (error is LocalDatabaseException) rethrow;
      throw LocalDatabaseException('初始化本地数据库失败：$error', cause: error);
    }

    return PlannerDatabase._(handle, resolvedPath);
  }

  /// 底层连接。仅供数据层内部、备份服务与测试使用。
  Database get handle {
    final handle = _handle;
    if (_closed || handle == null) {
      throw StateError('本地数据库连接已关闭，不能再读写');
    }
    return handle;
  }

  /// 当前文件里记录的结构版本（`PRAGMA user_version`）。
  int get storedSchemaVersion => readSchemaVersion(handle);

  bool get isOpen => !_closed && _handle != null;

  /// 数据变化广播。仓储的 `watch*` 流都挂在这里，任何写入方（仓储、
  /// 备份恢复、将来的同步层）写完调 [notifyChanged] 即可刷新界面。
  Stream<void> get changes => _changes.stream;

  /// 通知监听者数据已变化。必须在事务提交之后调用。
  void notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// **本机用户写入**广播（不含云端拉取写入）。
  Stream<void> get localWrites => _localWrites.stream;

  /// 通知监听者有本地用户写入。必须在事务提交之后调用。
  void notifyLocalWrite() {
    if (_closed) return;
    notifyChanged();
    if (!_localWrites.isClosed) _localWrites.add(null);
  }

  /// 在一个写事务里执行 [body]；抛出任何异常都会整体回滚。
  ///
  /// 支持嵌套调用：内层直接执行（SQLite 不支持嵌套事务），
  /// 由最外层统一提交。
  T transaction<T>(T Function() body) {
    final handle = _requireOpen();
    if (_transactionDepth > 0) {
      _transactionDepth++;
      try {
        return body();
      } finally {
        _transactionDepth--;
      }
    }

    handle.execute('BEGIN IMMEDIATE');
    _transactionDepth = 1;
    try {
      final result = body();
      handle.execute('COMMIT');
      return result;
    } catch (_) {
      _rollbackQuietly(handle);
      rethrow;
    } finally {
      _transactionDepth = 0;
    }
  }

  /// WAL checkpoint。有活跃读者时只是尽力而为，不影响数据安全。
  void checkpoint({bool truncate = false}) {
    _requireOpen().execute(
      'PRAGMA wal_checkpoint(${truncate ? 'TRUNCATE' : 'PASSIVE'})',
    );
  }

  /// 用 SQLite 官方支持的一致快照方式导出完整数据库文件。
  ///
  /// 内部走 `VACUUM INTO`：即使库处于 WAL 模式、甚至正在被写入，
  /// 导出结果也是同一事务快照，**不会得到"半个数据库"**。
  String snapshotTo(String targetPath) {
    final handle = _requireOpen();
    if (_transactionDepth > 0) {
      throw const LocalDatabaseException('不能在事务进行中导出数据库快照');
    }
    if (File(targetPath).existsSync()) {
      throw LocalDatabaseException('快照目标文件已存在，不会覆盖：$targetPath');
    }
    PlannerPaths.ensureParentOf(targetPath);
    try {
      handle.execute('PRAGMA wal_checkpoint(PASSIVE)');
      handle.execute('VACUUM INTO ?', <Object?>[targetPath]);
      return targetPath;
    } on SqliteException catch (error) {
      // 某些 Windows 环境（杀毒/文件锁/非 ASCII 目标目录）会让
      // `VACUUM INTO <备份目录>` 报 "unable to open database file (14)"，
      // 但同一连接写系统临时目录通常正常。先导出到 ASCII 临时文件，
      // 再复制到最终位置；两步都失败才报错。
      final temporary = p.join(
        Directory.systemTemp.path,
        'jihuatai_snapshot_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      try {
        final partial = File(targetPath);
        if (partial.existsSync()) partial.deleteSync();
        handle.execute('VACUUM INTO ?', <Object?>[temporary]);
        File(temporary).copySync(targetPath);
        return targetPath;
      } on Object catch (fallbackError) {
        // 最后兜底：直接复制主库 + WAL 到临时目录，合并后复制到目标。
        // 这条路径不依赖 VACUUM INTO，用于某些 Windows/VFS 组合下
        // VACUUM INTO 始终报 code 14 的环境。
        if (_snapshotByFileCopy(targetPath)) return targetPath;
        throw LocalDatabaseException(
          '导出数据库快照失败：${error.message}'
          '${fallbackError is SqliteException ? '（备用路径：${fallbackError.message}）' : ''}',
          cause: error,
        );
      } finally {
        final temp = File(temporary);
        if (temp.existsSync()) {
          try {
            temp.deleteSync();
          } on FileSystemException {
            // 临时文件清理失败不影响已完成的快照。
          }
        }
      }
    }
  }

  /// 不依赖 `VACUUM INTO` / 新建 SQLite 连接的最后兜底。
  ///
  /// 优先 checkpoint 后复制单文件；若 checkpoint 被读事务占用，则把主库
  /// 与 `-wal`/`-shm` 一起复制成多文件快照。后者仍是可用的一致快照，
  /// 只是恢复时需要保留同目录的 sidecar 文件。
  bool _snapshotByFileCopy(String targetPath) {
    final sourcePath = path;
    if (sourcePath == null) return false;
    final source = File(sourcePath);
    if (!source.existsSync()) return false;

    // 1) 单文件：checkpoint 成功后再复制主库。
    try {
      final handle = _requireOpen();
      final checkpoint = handle.select('PRAGMA wal_checkpoint(TRUNCATE)');
      final busy = checkpoint.isEmpty ? 0 : checkpoint.first['busy'];
      if (busy is! int || busy == 0) {
        final target = File(targetPath);
        if (target.existsSync()) target.deleteSync();
        source.copySync(targetPath);
        return true;
      }
    } on Object {
      // 继续尝试 sidecar 复制。
    }

    // 2) 多文件：复制 app.db + -wal + -shm；只读打开时 SQLite 会合并 WAL。
    try {
      final target = File(targetPath);
      if (target.existsSync()) target.deleteSync();
      source.copySync(targetPath);
      for (final suffix in <String>['-wal', '-shm']) {
        final sidecar = File('$sourcePath$suffix');
        if (sidecar.existsSync()) {
          sidecar.copySync('$targetPath$suffix');
        }
      }
      return true;
    } on Object {
      for (final suffix in <String>['', '-wal', '-shm']) {
        final file = File('$targetPath$suffix');
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } on FileSystemException {
            // 忽略清理失败。
          }
        }
      }
      return false;
    }
  }

  /// 完整完整性检查，正常返回 `ok`。
  String integrityCheck() {
    final rows = _requireOpen().select('PRAGMA integrity_check');
    final buffer = StringBuffer();
    for (final row in rows) {
      final value = row['integrity_check'];
      if (value is String) {
        if (buffer.isNotEmpty) buffer.write('; ');
        buffer.write(value);
      }
    }
    return buffer.isEmpty ? 'ok' : buffer.toString();
  }

  /// 关闭连接：先 checkpoint 再 dispose，可重复调用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      try {
        handle.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } on SqliteException {
        // ignore: empty_catches
        // 退出路径尽力而为：有活跃读者时 checkpoint 会失败，
        // 残留的 WAL 会在下次打开时自动恢复，不影响数据安全。
      }
      handle.close();
    }
    await _changes.close();
    await _localWrites.close();
  }

  // -------------------------------------------------------------------------
  // 静态辅助
  // -------------------------------------------------------------------------

  /// 读取 `PRAGMA user_version`。
  static int readSchemaVersion(Database handle) {
    final row = handle.select('PRAGMA user_version').first;
    final value = row['user_version'];
    if (value is int) return value;
    throw LocalDatabaseException('无法读取数据库结构版本：$value');
  }

  /// 按版本号顺序执行迁移，每条迁移在自己的事务里提交。
  ///
  /// [steps] 可注入，便于测试迁移机制本身。
  static void applyMigrations(
    Database handle, {
    required int from,
    required int to,
    List<SchemaMigration> steps = defaultSchemaMigrations,
  }) {
    if (to < from) {
      throw LocalDatabaseException('数据库结构版本不能回退：v$from → v$to');
    }
    var version = from;
    while (version < to) {
      final target = version + 1;
      SchemaMigration? step;
      for (final candidate in steps) {
        if (candidate.version == target) {
          step = candidate;
          break;
        }
      }
      if (step == null) {
        throw LocalDatabaseException('缺少数据库 v$target 的迁移脚本，已停止升级（现有数据未改动）');
      }
      final migration = step;
      handle.execute('BEGIN IMMEDIATE');
      try {
        migration.apply(handle);
        handle.execute('PRAGMA user_version = $target');
        if (_tableExists(handle, 'settings')) {
          handle.execute(
            'INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)',
            <Object?>['schema_version', '$target'],
          );
        }
        handle.execute('COMMIT');
        version = target;
      } catch (error) {
        _rollbackQuietly(handle);
        throw LocalDatabaseException(
          '数据库从 v$version 升级到 v$target 失败，已回滚（${migration.description}）：$error',
          cause: error,
        );
      }
    }
  }

  static String _resolvePath(String? path) {
    final trimmed = path?.trim() ?? '';
    return p.normalize(
      trimmed.isEmpty ? PlannerPaths.defaultDatabasePath() : trimmed,
    );
  }

  static void _configure(
    Database handle, {
    required bool inMemory,
    required int busyTimeoutMs,
  }) {
    // 外键约束必须显式打开（SQLite 默认关闭）；ON DELETE RESTRICT 保证
    // 级联删除只能由仓储在同一事务里显式完成，不会被数据库偷偷删掉。
    handle.execute('PRAGMA foreign_keys = ON');
    handle.execute('PRAGMA busy_timeout = $busyTimeoutMs');
    handle.execute('PRAGMA synchronous = FULL');
    handle.execute('PRAGMA temp_store = MEMORY');
    if (!inMemory) {
      // WAL：读写不互相阻塞，异常退出后可用 WAL 恢复。
      handle.execute('PRAGMA journal_mode = WAL');
    }
  }

  static void _quickCheck(Database handle, String label) {
    final rows = handle.select('PRAGMA quick_check');
    String? failure;
    for (final row in rows) {
      final value = row['quick_check'];
      if (value is String && value != 'ok') failure = value;
    }
    if (failure != null) {
      throw LocalDatabaseException(
        '本地数据库完整性检查未通过（$label）：$failure。'
        '为避免损坏扩散，程序已停止打开该库；请从备份恢复最近一次数据，'
        '或先把文件复制出来再做排查。',
      );
    }
  }

  static bool _tableExists(Database handle, String table) => handle.select(
    "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  static void _rollbackQuietly(Database handle) {
    try {
      handle.execute('ROLLBACK');
    } on SqliteException {
      // ignore: empty_catches
      // 回滚本身失败通常意味着连接已经坏了；此时保留原始异常更有诊断价值。
    }
  }

  Database _requireOpen() => handle;
}
