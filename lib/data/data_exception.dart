/// 本地数据层自身的错误类型。
///
/// 与领域层 `PlannerException`（输入非法 / 找不到 / 版本冲突）分开：
/// 这里的错误表示**存储介质**出问题——磁盘满、文件被占用、数据库损坏、
/// 备份文件格式不对。界面应把它们当作"需要用户处理的环境问题"，
/// 而不是表单校验失败。
library;

/// 数据库 / 文件系统层面的失败（可带原始异常用于日志）。
///
/// [message] 必须是可直接展示给用户的中文说明。
final class LocalDatabaseException implements Exception {
  const LocalDatabaseException(this.message, {this.cause});

  /// 面向用户的中文说明。
  final String message;

  /// 原始异常（[SqliteException] / [FileSystemException] 等），仅用于日志。
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'LocalDatabaseException: $message'
      : 'LocalDatabaseException: $message (cause: $cause)';
}

/// 备份 / 恢复失败的分类。
enum BackupErrorKind {
  fileNotFound('备份文件不存在'),
  invalidFormat('备份文件格式不正确'),
  newerSchema('备份文件来自更新版本的应用'),
  overwriteRefused('需要确认后才能覆盖现有数据'),
  integrityFailed('备份数据校验未通过'),
  ioFailure('备份文件读写失败');

  const BackupErrorKind(this.label);

  final String label;
}

/// 备份导出 / 校验 / 恢复过程中的失败。
final class BackupException implements Exception {
  const BackupException(this.kind, this.message, {this.cause});

  final BackupErrorKind kind;

  /// 面向用户的中文说明。
  final String message;

  final Object? cause;

  @override
  String toString() => 'BackupException(${kind.name}): $message';
}
