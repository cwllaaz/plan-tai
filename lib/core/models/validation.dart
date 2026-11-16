import 'planner_exception.dart';

/// 校验文本字段：去首尾空白、拒绝空值、限制长度。
String requireText(
  String value, {
  required String field,
  int maxLength = 200,
  bool allowEmpty = false,
}) {
  final trimmed = value.trim();
  if (!allowEmpty && trimmed.isEmpty) {
    throw PlannerValidationException('$field不能为空');
  }
  if (trimmed.length > maxLength) {
    throw PlannerValidationException('$field不能超过 $maxLength 个字符');
  }
  return trimmed;
}

/// 可空的文本字段：null 表示未填写；非 null 时按 [requireText] 规则处理空串为 ''。
String optionalText(
  String? value, {
  required String field,
  int maxLength = 200,
}) {
  if (value == null) return '';
  return requireText(
    value,
    field: field,
    maxLength: maxLength,
    allowEmpty: true,
  );
}

/// 校验整数闭区间。
int requireInRange(
  int value, {
  required String field,
  required int min,
  required int max,
}) {
  if (value < min || value > max) {
    throw PlannerValidationException('$field必须在 $min 到 $max 之间');
  }
  return value;
}

const Object unset = Object();
