/// 领域层异常。
///
/// 仓储接口把可预期的失败表达为下列三种异常，界面层据此给用户可读的提示。
/// 不抛裸 [Exception]，也不吞掉异常（见 docs/DATA_CONTRACT.md）。
sealed class PlannerException implements Exception {
  const PlannerException(this.message);

  /// 面向用户的中文说明，界面可直接展示。
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 输入不满足模型约束（空标题、非法日期、结束日早于开始日等）。
final class PlannerValidationException extends PlannerException {
  const PlannerValidationException(super.message);
}

/// 目标实体不存在，或已被软删除。
final class PlannerNotFoundException extends PlannerException {
  const PlannerNotFoundException(super.message);
}

/// 乐观并发冲突：调用方持有的 [revision] 已落后于存储中的版本。
///
/// 处理约定：重新读取最新实体后再修改，**不要**盲目重试覆盖。
final class PlannerConflictException extends PlannerException {
  const PlannerConflictException(
    super.message, {
    required this.expected,
    required this.actual,
  });

  final int expected;
  final int actual;
}
