/// 业务实体 ↔ 同步协议 payload 的映射。
///
/// payload 是**去掉本地/服务端管理字段**的完整快照（docs/sync/DATA_CONTRACT.md §2）：
/// 不包含 `id`、`revision`、`updatedAt`、`deletedAt`。与备份 JSON 分开，
/// 避免把本地 revision 当成服务端版本发给云端。
library;

import '../../core/cloud/cloud_types.dart';
import '../../core/models/models.dart';
import '../entity_codec.dart';

// ---------------------------------------------------------------------------
// 编码
// ---------------------------------------------------------------------------

Map<String, Object?> projectSyncPayload(Project project) => <String, Object?>{
  'createdAt': encodeInstant(project.createdAt),
  'name': project.name,
  'description': project.description,
  'color': project.color.hex,
  'status': project.status.name,
  'sortOrder': project.sortOrder,
};

Map<String, Object?> spanSyncPayload(PlanSpan span) => <String, Object?>{
  'createdAt': encodeInstant(span.createdAt),
  'projectId': span.projectId,
  'title': span.title,
  'startDate': span.startDate.iso,
  'endDate': span.endDate.iso,
  'status': span.status.name,
  'description': span.description,
  'color': span.color?.hex,
  'sortOrder': span.sortOrder,
};

Map<String, Object?> taskSyncPayload(PlannerTask task) => <String, Object?>{
  'createdAt': encodeInstant(task.createdAt),
  'projectId': task.projectId,
  'spanId': task.spanId,
  'title': task.title,
  'notes': task.notes,
  'scheduledDate': task.scheduledDate?.iso,
  'timeSlot': task.timeSlot == null
      ? null
      : <String, Object?>{
          'startMinute': task.timeSlot!.startMinute,
          'durationMinutes': task.timeSlot!.durationMinutes,
        },
  'priority': task.priority.name,
  'status': task.status.name,
  'completedAt': encodeInstantOrNull(task.completedAt),
  'sortOrder': task.sortOrder,
};

Map<String, Object?> noteSyncPayload(DailyNote note) => <String, Object?>{
  'createdAt': encodeInstant(note.createdAt),
  'date': note.date.iso,
  'body': note.body,
  'focusItems': note.focusItems,
};

Map<String, Object?> syncPayloadOf(CloudEntityType type, PlannerEntity entity) =>
    switch (type) {
      CloudEntityType.project => projectSyncPayload(entity as Project),
      CloudEntityType.span => spanSyncPayload(entity as PlanSpan),
      CloudEntityType.task => taskSyncPayload(entity as PlannerTask),
      CloudEntityType.note => noteSyncPayload(entity as DailyNote),
    };

// ---------------------------------------------------------------------------
// 解码
// ---------------------------------------------------------------------------

Project projectFromSyncPayload({
  required String id,
  required Map<String, Object?> payload,
  required int revision,
  required DateTime updatedAt,
  DateTime? deletedAt,
}) => Project(
  id: id,
  createdAt: _instant(payload['createdAt'], 'project.createdAt'),
  updatedAt: updatedAt,
  revision: revision,
  deletedAt: deletedAt,
  name: _string(payload['name'], 'project.name'),
  description: _optionalString(payload['description']) ?? '',
  color: ProjectColor.fromHex(_string(payload['color'], 'project.color')),
  status: _projectStatus(payload['status']),
  sortOrder: _optionalInt(payload['sortOrder']),
);

PlanSpan spanFromSyncPayload({
  required String id,
  required Map<String, Object?> payload,
  required int revision,
  required DateTime updatedAt,
  DateTime? deletedAt,
}) => PlanSpan(
  id: id,
  createdAt: _instant(payload['createdAt'], 'span.createdAt'),
  updatedAt: updatedAt,
  revision: revision,
  deletedAt: deletedAt,
  projectId: _string(payload['projectId'], 'span.projectId'),
  title: _string(payload['title'], 'span.title'),
  startDate: _date(payload['startDate'], 'span.startDate'),
  endDate: _date(payload['endDate'], 'span.endDate'),
  status: _spanStatus(payload['status']),
  description: _optionalString(payload['description']) ?? '',
  color: _optionalString(payload['color']) == null
      ? null
      : ProjectColor.fromHex(_string(payload['color'], 'span.color')),
  sortOrder: _optionalInt(payload['sortOrder']),
);

PlannerTask taskFromSyncPayload({
  required String id,
  required Map<String, Object?> payload,
  required int revision,
  required DateTime updatedAt,
  DateTime? deletedAt,
}) {
  final rawSlot = payload['timeSlot'];
  TimeSlot? timeSlot;
  if (rawSlot != null) {
    if (rawSlot is! Map<Object?, Object?>) {
      throw const PlannerValidationException('task.timeSlot 必须是对象');
    }
    timeSlot = TimeSlot(
      startMinute: _int(rawSlot['startMinute'], 'task.timeSlot.startMinute'),
      durationMinutes: _int(
        rawSlot['durationMinutes'],
        'task.timeSlot.durationMinutes',
      ),
    );
  }
  final scheduledRaw = payload['scheduledDate'];
  return PlannerTask(
    id: id,
    createdAt: _instant(payload['createdAt'], 'task.createdAt'),
    updatedAt: updatedAt,
    revision: revision,
    deletedAt: deletedAt,
    projectId: _optionalString(payload['projectId']),
    spanId: _optionalString(payload['spanId']),
    title: _string(payload['title'], 'task.title'),
    notes: _optionalString(payload['notes']) ?? '',
    scheduledDate: scheduledRaw == null
        ? null
        : _date(scheduledRaw, 'task.scheduledDate'),
    timeSlot: timeSlot,
    priority: taskPriorityFromName(payload['priority']),
    status: taskStatusFromDb(payload['status']),
    completedAt: payload['completedAt'] == null
        ? null
        : _instant(payload['completedAt'], 'task.completedAt'),
    sortOrder: _optionalInt(payload['sortOrder']),
  );
}

DailyNote noteFromSyncPayload({
  required String id,
  required Map<String, Object?> payload,
  required int revision,
  required DateTime updatedAt,
  DateTime? deletedAt,
}) => DailyNote(
  id: id,
  createdAt: _instant(payload['createdAt'], 'note.createdAt'),
  updatedAt: updatedAt,
  revision: revision,
  deletedAt: deletedAt,
  date: _date(payload['date'], 'note.date'),
  body: _optionalString(payload['body']) ?? '',
  focusItems: _focusItems(payload['focusItems']),
);

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

DateTime _instant(Object? raw, String field) {
  if (raw is! String) {
    throw PlannerValidationException('$field 必须是 UTC 时间字符串');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw PlannerValidationException('$field 不是合法时间：$raw');
  }
  return parsed.toUtc();
}

LocalDate _date(Object? raw, String field) {
  if (raw is! String) {
    throw PlannerValidationException('$field 必须是 YYYY-MM-DD');
  }
  return LocalDate.parse(raw);
}

String _string(Object? raw, String field) {
  if (raw is! String || raw.trim().isEmpty) {
    throw PlannerValidationException('$field 缺失或为空');
  }
  return raw;
}

String? _optionalString(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) {
    throw const PlannerValidationException('字段类型错误：期望文本');
  }
  return raw;
}

int _int(Object? raw, String field) {
  if (raw is int) return raw;
  if (raw is double && raw == raw.roundToDouble()) return raw.toInt();
  throw PlannerValidationException('$field 必须是整数，实际 $raw');
}

int _optionalInt(Object? raw) => raw == null ? 0 : _int(raw, '整数字段');

ProjectStatus _projectStatus(Object? raw) {
  for (final status in ProjectStatus.values) {
    if (status.name == raw) return status;
  }
  throw PlannerValidationException('未知项目状态：$raw');
}

PlanSpanStatus _spanStatus(Object? raw) {
  for (final status in PlanSpanStatus.values) {
    if (status.name == raw) return status;
  }
  throw PlannerValidationException('未知阶段状态：$raw');
}

List<String> _focusItems(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is! List<Object?>) {
    throw const PlannerValidationException('note.focusItems 必须是字符串数组');
  }
  final items = <String>[];
  for (final item in raw) {
    if (item is! String) {
      throw const PlannerValidationException('note.focusItems 必须是字符串数组');
    }
    items.add(item);
  }
  return items;
}
