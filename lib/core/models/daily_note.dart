import 'local_date.dart';
import 'planner_entity.dart';
import 'planner_exception.dart';
import 'validation.dart';

/// 每日备注：一天一条，属于某个日历日而不是某个任务。
///
/// 除了自由文本正文，还带最多 3 条「当日重点」（置顶在抽屉里）。
/// 日期是唯一键：同一天只能存在一条，仓储用 upsert 保证。
final class DailyNote extends PlannerEntity {
  DailyNote({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    required super.revision,
    super.deletedAt,
    required this.date,
    String body = '',
    List<String> focusItems = const <String>[],
  }) : body = optionalText(body, field: '每日备注', maxLength: 10000),
       focusItems = List<String>.unmodifiable(_normalizeFocusItems(focusItems));

  /// 备注所属的日历日。
  final LocalDate date;

  final String body;

  /// 最多 3 条「当日重点」，已去空白、去空串。
  final List<String> focusItems;

  static const int maxFocusItems = 3;

  bool get isEmpty => body.trim().isEmpty && focusItems.isEmpty;

  DailyNote copyWith({
    String? body,
    List<String>? focusItems,
    Object? deletedAt = unset,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? revision,
  }) => DailyNote(
    id: id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    revision: revision ?? this.revision,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
    date: date,
    body: body ?? this.body,
    focusItems: focusItems ?? this.focusItems,
  );

  static List<String> _normalizeFocusItems(List<String> items) {
    final cleaned = <String>[];
    for (final raw in items) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      if (text.length > 60) {
        throw const PlannerValidationException('单条当日重点不能超过 60 个字符');
      }
      cleaned.add(text);
    }
    if (cleaned.length > maxFocusItems) {
      throw const PlannerValidationException('当日重点最多 3 条');
    }
    return cleaned;
  }

  @override
  bool operator ==(Object other) =>
      other is DailyNote &&
      baseEquals(other) &&
      date == other.date &&
      body == other.body &&
      _sameItems(focusItems, other.focusItems);

  @override
  int get hashCode =>
      Object.hash(baseHashCode(), date, body, Object.hashAll(focusItems));

  static bool _sameItems(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'DailyNote(${date.iso})';
}
