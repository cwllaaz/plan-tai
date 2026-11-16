import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show Database;

import '../app/cloud_workspace.dart';
import '../data/data.dart';
import 'app_paths.dart';

/// 打开仓储的注入点（测试用：可注入打不开的库、慢库等）。
typedef PlannerRepositoryOpener =
    SqlitePlannerRepository Function(String databasePath);

/// 生命周期守护只依赖这几个能力，便于在测试里注入假实现。
abstract interface class PlannerStorageLifecycleTarget {
  /// 连接是否仍然可用。
  bool get isOpen;

  /// WAL checkpoint；返回是否成功（失败不算致命错误）。
  bool checkpoint({bool truncate = true});

  /// 低内存时释放 SQLite 内存缓存。
  bool releaseMemory();

  /// 轻量健康检查（`SELECT 1`）。
  bool verifyAlive();
}

/// Android 平台数据库初始化适配层。
///
/// 桌面端直接在 `main.dart` 里拼路径并 `SqlitePlannerRepository.open`；
/// Android 端多出四件必须显式处理的事，集中在这里：
///
/// 1. **私有目录必须先注入**：`AppPaths.resolveBaseDirectory()` →
///    `PlannerPaths.useBaseDirectory()`，之后数据层所有同步路径 API 才可用；
/// 2. **只打开一次**：Activity/页面重建时组合根可能被再次调用，本类保证同一进程
///    同一路径复用同一个连接（[open] 幂等），避免重复建连、重复迁移与 WAL 争用；
/// 3. **拒绝缓存目录**：基目录落在 `cache/temp/no_backup` 时直接失败，
///    防止真实数据被系统回收（这是数据安全硬约束，不是可选检查）；
/// 4. **可运维**：暴露 [checkpoint] / [releaseMemory] / [verifyAlive]，
///    供生命周期守护与诊断使用。
///
/// 不负责：账号工作区的「切换」（那是同步引擎 + 重启流程的事，本类只按
/// `cloud_workspace.json` 指针选择启动时该打开哪个库，语义与桌面端一致）。
final class AndroidDatabaseHost implements PlannerStorageLifecycleTarget {
  AndroidDatabaseHost._({
    required this.baseDirectory,
    required this.dataDirectory,
    required this.databasePath,
    required this.repository,
    required this.createdDatabase,
    required this.openedAt,
    required this.opener,
  });

  static AndroidDatabaseHost? _current;

  /// 当前进程已打开的宿主；没有则为 null（仅诊断/测试使用）。
  static AndroidDatabaseHost? get current => _current;

  /// 基目录（不含 `data`）。
  final String baseDirectory;

  /// `<base>/data`。
  final String dataDirectory;

  /// 实际打开的数据库文件绝对路径。
  final String databasePath;

  final SqlitePlannerRepository repository;

  /// 本次打开是否新建了数据库文件（首次启动 = true；重开 = false）。
  final bool createdDatabase;

  /// 本次打开时刻（UTC），诊断用。
  final DateTime openedAt;

  final PlannerRepositoryOpener opener;

  bool _closed = false;

  /// 连接是否仍然可用（进程内）。
  @override
  bool get isOpen => !_closed && repository.database.isOpen;

  /// 备份目录（`<base>/data/backups`）。
  String get backupDirectory =>
      p.join(dataDirectory, PlannerPaths.backupsFolder);

  /// 打开（必要时创建）Android 本地数据库，并返回可直接交给 UI 的宿主。
  ///
  /// [baseDirectory]：仅测试/特殊场景显式指定；null 时用
  /// [AppPaths.resolveBaseDirectory]（正式启动路径）。
  /// [databasePath]：仅测试用；null 时按 `cloud_workspace.json` 指针或默认库。
  /// [reuseExisting]：默认 true —— 同一进程内同路径重复调用返回同一实例。
  /// [opener]：仅测试用，默认 `SqlitePlannerRepository.open`。
  /// [enforcePrivateDirectoryGuard]：仅测试用；null 时按平台决定（Android 强制）。
  static Future<AndroidDatabaseHost> open({
    String? baseDirectory,
    String? databasePath,
    bool reuseExisting = true,
    PlannerRepositoryOpener? opener,
    bool? enforcePrivateDirectoryGuard,
  }) async {
    final rawBase = (baseDirectory ?? await AppPaths.resolveBaseDirectory()).trim();
    if (rawBase.isEmpty) {
      throw const LocalDatabaseException('Android 应用私有目录为空，已停止创建数据库。');
    }
    final base = p.normalize(rawBase);

    // 数据安全硬约束：绝不允许把真实数据放进会被系统回收的目录。
    // 只在 Android 上强制（桌面/CI 的临时测试目录路径里也含 Temp，不能一刀切；
    // 测试可显式把该守卫打开来验证它确实会拒绝）。
    final enforceGuard =
        enforcePrivateDirectoryGuard ?? Platform.isAndroid;
    if (enforceGuard && AppPaths.isEphemeralDirectory(base)) {
      throw LocalDatabaseException(
        '拒绝把数据库放在缓存/临时目录：$base。'
        'Android 上数据必须位于应用私有 files 目录（卸载才会清除）。',
      );
    }

    // 1) 注入基目录：之后 PlannerPaths.default* 全部按 Android 私有目录解析。
    PlannerPaths.useBaseDirectory(base);

    // 2) 数据目录 + 账号工作区指针（与桌面端完全相同的规则）。
    final resolvedDataDirectory = PlannerPaths.defaultDataDirectory();
    final effectiveDatabasePath =
        databasePath ??
        CloudWorkspaceStore(
          resolvedDataDirectory,
        ).activeDatabasePath() ??
        PlannerPaths.defaultDatabasePath();

    // 3) 幂等：同一进程同一路径复用已有连接（页面/Activity 重建不会重复建库）。
    final existing = _current;
    if (reuseExisting &&
        existing != null &&
        existing.isOpen &&
        p.equals(existing.databasePath, effectiveDatabasePath)) {
      return existing;
    }
    if (existing != null && existing.isOpen) {
      // 路径变了：调用方必须先显式 close，避免同时持有两个连接写同一个库。
      throw LocalDatabaseException(
        '已有数据库连接打开（${existing.databasePath}），'
        '不能在未关闭的情况下切换到 $effectiveDatabasePath。'
        '请先调用 AndroidDatabaseHost.close()。',
      );
    }

    final resolvedOpener =
        opener ??
        (String path) => SqlitePlannerRepository.open(databasePath: path);

    final created = !File(effectiveDatabasePath).existsSync();
    final SqlitePlannerRepository repository;
    try {
      repository = resolvedOpener(effectiveDatabasePath);
    } on LocalDatabaseException {
      rethrow;
    } on Object catch (error) {
      throw LocalDatabaseException(
        '打开 Android 本地数据库失败：${error.runtimeType}',
        cause: error,
      );
    }

    // 4) 打开后自检：文件必须真实存在且非空（防止“看似打开、实际没落盘”）。
    final file = File(effectiveDatabasePath);
    if (!file.existsSync() || file.lengthSync() <= 0) {
      await repository.close();
      throw LocalDatabaseException(
        '本地数据库文件未能落盘：$effectiveDatabasePath。'
        '请检查设备剩余空间与私有目录权限。',
      );
    }

    final host = AndroidDatabaseHost._(
      baseDirectory: base,
      dataDirectory: resolvedDataDirectory,
      databasePath: effectiveDatabasePath,
      repository: repository,
      createdDatabase: created,
      openedAt: DateTime.now().toUtc(),
      opener: resolvedOpener,
    );
    _current = host;
    return host;
  }

  /// WAL checkpoint。
  ///
  /// [truncate] 为 true 时把 WAL 合入主库并截断（退到后台/锁屏时用，保证即使进程
  /// 立刻被杀，主库文件也是最新的、外部拷贝/系统备份拿到的是一致的库）；
  /// 有活跃读者时 SQLite 只会尽力而为，不会破坏数据。
  @override
  bool checkpoint({bool truncate = true}) {
    if (!isOpen) return false;
    try {
      repository.database.checkpoint(truncate: truncate);
      return true;
    } on Object catch (error) {
      stderr.writeln('WAL checkpoint 失败（已忽略，不影响数据安全）：$error');
      return false;
    }
  }
  /// 低内存时释放 SQLite 持有的内存（页缓存 / WAL 索引），文件连接保持打开。
  ///
  /// 为什么不在这里 close 连接：连接由 [repository] 持有并被界面流监听，
  /// 关闭会让正在展示的页面直接 `StateError`；真正释放连接由系统回收进程完成，
  /// 下次冷启动重新打开（见 [AndroidDatabaseHost.open]，会做完整性检查）。
  /// 因此这里的「释放」释放的是**内存缓存**，之后任何查询会自动重建缓存。
  @override
  bool releaseMemory() {
    if (!isOpen) return false;
    var ok = checkpoint(truncate: false);
    final Database handle = repository.database.handle;
    try {
      handle.execute('PRAGMA shrink_memory');
      ok = true;
    } on Object catch (error) {
      stderr.writeln('PRAGMA shrink_memory 失败（已忽略）：$error');
    }
    try {
      handle.execute('PRAGMA optimize');
    } on Object catch (error) {
      stderr.writeln('PRAGMA optimize 失败（已忽略）：$error');
    }
    return ok;
  }

  /// 轻量健康检查：连接能执行查询即视为存活。
  @override
  bool verifyAlive() {
    if (!isOpen) return false;
    try {
      repository.database.handle.select('SELECT 1 AS alive');
      return true;
    } on Object catch (error) {
      stderr.writeln('本地数据库连接健康检查失败：$error');
      return false;
    }
  }

  /// 关闭连接（幂等）。关闭后 [open] 会重新建连（测试与「重启工作区」流程用）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (identical(_current, this)) _current = null;
    await repository.close();
  }

  /// 仅测试：清空静态单例，避免用例间串库。
  static Future<void> resetForTesting() async {
    final current = _current;
    _current = null;
    if (current != null) await current.close();
  }

  @override
  String toString() =>
      'AndroidDatabaseHost(路径: $databasePath, 数据目录: $dataDirectory, '
      '新建: $createdDatabase, 已打开: ${DateTime.now().difference(openedAt).inSeconds}s)';
}
