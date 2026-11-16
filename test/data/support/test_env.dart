import 'dart:io';

import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

/// 可手动推进的时钟，让"创建时刻 / 完成时刻"在测试里完全确定。
final class FakeClock {
  FakeClock([DateTime? start])
    : _current = start ?? DateTime.utc(2026, 11, 14, 9, 30, 15, 123, 456);

  DateTime _current;

  /// 传给仓储的 `clock` 回调。
  DateTime now() => _current;

  void advance(Duration duration) => _current = _current.add(duration);

  DateTime get value => _current;
}

/// 一个隔离的测试环境：临时目录里的真实 SQLite 文件 + 正式仓储。
///
/// **绝不使用用户真实数据库**：每个实例都是 `系统临时目录/jihuatai_data_test_xxx/app.db`，
/// 测试结束删除。
final class TestEnv {
  TestEnv._(this.directory, this.database, this.repository, this.clock);

  final Directory directory;
  final PlannerDatabase database;
  final SqlitePlannerRepository repository;
  final DateTime Function()? clock;

  String get databasePath => database.path!;

  String pathInDirectory(String name) => p.join(directory.path, name);

  /// 新建临时目录并打开数据库。
  static TestEnv create({
    DateTime Function()? clock,
    String Function()? idGenerator,
    int busyTimeoutMs = 5000,
  }) {
    final directory = Directory.systemTemp.createTempSync(
      'jihuatai_data_test_',
    );
    return openIn(
      directory,
      clock: clock,
      idGenerator: idGenerator,
      busyTimeoutMs: busyTimeoutMs,
    );
  }

  /// 在已存在的目录里打开数据库（用于模拟"关闭软件再启动"）。
  static TestEnv openIn(
    Directory directory, {
    DateTime Function()? clock,
    String Function()? idGenerator,
    int busyTimeoutMs = 5000,
  }) {
    final database = PlannerDatabase.open(
      path: p.join(directory.path, 'app.db'),
      busyTimeoutMs: busyTimeoutMs,
    );
    return TestEnv._(
      directory,
      database,
      SqlitePlannerRepository(database, clock: clock, idGenerator: idGenerator),
      clock,
    );
  }

  /// 关闭仓储（同时关闭数据库连接）。
  Future<void> close() => repository.close();

  /// 关闭并删除临时目录。
  Future<void> dispose() async {
    await repository.close();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}

/// 便捷构造日历日。
LocalDate d(String iso) => LocalDate.parse(iso);
