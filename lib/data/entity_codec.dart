/// 实体与数据库行 / JSON 之间的全部编解码逻辑。
///
/// 两条铁律：
/// 1. **日历日只以 `YYYY-MM-DD` 字符串过界**，任何地方都不把某一天换成
///    `DateTime` 或 UTC 毫秒，避免"11 月 16 日变成 11 月 15 日"。
/// 2. **时刻只以定长 UTC 字符串过界**（`...T12:00:00.000000Z`），这样
///    SQLite 里的字符串排序就是时间排序，索引与 `BETWEEN` 都可靠。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../core/models/models.dart';

// ---------------------------------------------------------------------------
// 时刻编码（定长 UTC，微秒精度）
// ---------------------------------------------------------------------------

/// 把 UTC 时刻编码为定长字符串：`2026-11-14T12:00:00.000000Z`。
///
/// 定长是有意为之：SQLite 没有原生时间类型，只有定长字符串的字典序才等于
/// 时间序。Dart 默认的 `DateTime.toIso8601String` 会输出 3 位或 6 位小数，
/// 混用会让 `.000Z` 排到 `.000123Z` 之后，所以这里统一补到 6 位。
String encodeInstant(DateTime value) {
  final utc = value.toUtc();
  final micros = utc.millisecond * 1000 + utc.microsecond;
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  final second = utc.second.toString().padLeft(2, '0');
  final fraction = micros.toString().padLeft(6, '0');
  return '$year-$month-${day}T$hour:$minute:$second.$fraction'
      'Z';
}

/// 解析 [encodeInstant] 写出的字符串（也接受任何合法 ISO 8601 时间）。
///
/// 返回值恒为 UTC；非法内容抛 `PlannerValidationException`（说明数据损坏）。
DateTime decodeInstant(Object? raw, {String field = '时间'}) {
  if (raw is! String) {
    throw PlannerValidationException('$field 字段类型错误：期望文本，实际 $raw');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw PlannerValidationException('$field 不是合法时间戳：$raw');
  }
  return parsed.toUtc();
}

/// [decodeInstant] 的可空版本。
DateTime? decodeInstantOrNull(Object? raw, {String field = '时间'}) =>
    raw == null ? null : decodeInstant(raw, field: field);

/// 可空时刻的编码。
String? encodeInstantOrNull(DateTime? value) =>
    value == null ? null : encodeInstant(value);

// ---------------------------------------------------------------------------
// 日期编码
// ---------------------------------------------------------------------------

/// `YYYY-MM-DD` 文本转 [LocalDate]。
LocalDate decodeDate(Object? raw, {String field = '日期'}) {
  if (raw is! String) {
    throw PlannerValidationException('$field 字段类型错误：期望文本，实际 $raw');
  }
  return LocalDate.parse(raw);
}

/// [decodeDate] 的可空版本。
LocalDate? decodeDateOrNull(Object? raw, {String field = '日期'}) =>
    raw == null ? null : decodeDate(raw, field: field);

// ---------------------------------------------------------------------------
// 枚举编码（数据库里存稳定字符串，不存 ordinal）
// ---------------------------------------------------------------------------

ProjectStatus projectStatusFromDb(Object? raw) => switch (raw) {
  'active' => ProjectStatus.active,
  'paused' => ProjectStatus.paused,
  'archived' => ProjectStatus.archived,
  _ => throw PlannerValidationException('项目状态数据损坏：$raw'),
};

PlanSpanStatus planSpanStatusFromDb(Object? raw) => switch (raw) {
  'planned' => PlanSpanStatus.planned,
  'doing' => PlanSpanStatus.doing,
  'done' => PlanSpanStatus.done,
  'dropped' => PlanSpanStatus.dropped,
  _ => throw PlannerValidationException('阶段状态数据损坏：$raw'),
};

TaskStatus taskStatusFromDb(Object? raw) => switch (raw) {
  'todo' => TaskStatus.todo,
  'done' => TaskStatus.done,
  _ => throw PlannerValidationException('任务状态数据损坏：$raw'),
};

TaskPriority taskPriorityFromName(Object? raw) => switch (raw) {
  'low' => TaskPriority.low,
  'normal' => TaskPriority.normal,
  'high' => TaskPriority.high,
  'urgent' => TaskPriority.urgent,
  _ => throw PlannerValidationException('任务优先级数据损坏：$raw'),
};

TaskPriority taskPriorityFromLevel(Object? raw) {
  if (raw is! int) {
    throw PlannerValidationException('任务优先级字段类型错误：$raw');
  }
  return TaskPriority.fromLevel(raw);
}

// ---------------------------------------------------------------------------
// 行转实体
// ---------------------------------------------------------------------------

Project projectFromRow(Row row) => Project(
  id: row['id'] as String,
  createdAt: decodeInstant(row['created_at'], field: '项目创建时间'),
  updatedAt: decodeInstant(row['updated_at'], field: '项目更新时间'),
  revision: row['revision'] as int,
  deletedAt: decodeInstantOrNull(row['deleted_at'], field: '项目删除时间'),
  name: row['name'] as String,
  description: row['description'] as String,
  color: ProjectColor.fromHex(row['color'] as String),
  status: projectStatusFromDb(row['status']),
  sortOrder: row['sort_order'] as int,
);

PlanSpan planSpanFromRow(Row row) {
  final colorHex = row['color'];
  return PlanSpan(
    id: row['id'] as String,
    createdAt: decodeInstant(row['created_at'], field: '阶段创建时间'),
    updatedAt: decodeInstant(row['updated_at'], field: '阶段更新时间'),
    revision: row['revision'] as int,
    deletedAt: decodeInstantOrNull(row['deleted_at'], field: '阶段删除时间'),
    projectId: row['project_id'] as String,
    title: row['title'] as String,
    startDate: decodeDate(row['start_date'], field: '阶段开始日'),
    endDate: decodeDate(row['end_date'], field: '阶段结束日'),
    status: planSpanStatusFromDb(row['status']),
    description: row['description'] as String,
    color: colorHex is String ? ProjectColor.fromHex(colorHex) : null,
    sortOrder: row['sort_order'] as int,
  );
}

PlannerTask plannerTaskFromRow(Row row) {
  final startMinute = row['time_start_minute'];
  final duration = row['time_duration_minutes'];
  if ((startMinute == null) != (duration == null)) {
    throw PlannerValidationException(
      '任务时间数据损坏：开始分钟 $startMinute / 持续分钟 $duration',
    );
  }
  return PlannerTask(
    id: row['id'] as String,
    createdAt: decodeInstant(row['created_at'], field: '任务创建时间'),
    updatedAt: decodeInstant(row['updated_at'], field: '任务更新时间'),
    revision: row['revision'] as int,
    deletedAt: decodeInstantOrNull(row['deleted_at'], field: '任务删除时间'),
    projectId: row['project_id'] as String?,
    spanId: row['span_id'] as String?,
    title: row['title'] as String,
    notes: row['notes'] as String,
    scheduledDate: decodeDateOrNull(row['scheduled_date'], field: '任务日期'),
    timeSlot: startMinute is int
        ? TimeSlot(startMinute: startMinute, durationMinutes: duration as int)
        : null,
    priority: taskPriorityFromLevel(row['priority']),
    status: taskStatusFromDb(row['status']),
    completedAt: decodeInstantOrNull(row['completed_at'], field: '任务完成时间'),
    sortOrder: row['sort_order'] as int,
  );
}

DailyNote dailyNoteFromRow(Row row) => DailyNote(
  id: row['id'] as String,
  createdAt: decodeInstant(row['created_at'], field: '备注创建时间'),
  updatedAt: decodeInstant(row['updated_at'], field: '备注更新时间'),
  revision: row['revision'] as int,
  deletedAt: decodeInstantOrNull(row['deleted_at'], field: '备注删除时间'),
  date: decodeDate(row['date'], field: '备注日期'),
  body: row['body'] as String,
  focusItems: decodeFocusItems(row['focus_items']),
);

/// 数据库里 `focus_items` 存 JSON 数组文本。
List<String> decodeFocusItems(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is! String || raw.trim().isEmpty) {
    throw PlannerValidationException('当日重点数据损坏：$raw');
  }
  final decoded = jsonDecode(raw);
  if (decoded is! List<Object?>) {
    throw PlannerValidationException('当日重点数据损坏：$raw');
  }
  final items = <String>[];
  for (final element in decoded) {
    if (element is! String) {
      throw PlannerValidationException('当日重点数据损坏：$raw');
    }
    items.add(element);
  }
  return items;
}

String encodeFocusItems(List<String> items) => jsonEncode(items);

// ---------------------------------------------------------------------------
// 实体转 JSON（备份格式；字段名与 Dart 模型一一对应）
// ---------------------------------------------------------------------------

Map<String, Object?> projectToJson(Project project) => <String, Object?>{
  'id': project.id,
  'createdAt': encodeInstant(project.createdAt),
  'updatedAt': encodeInstant(project.updatedAt),
  'revision': project.revision,
  'deletedAt': encodeInstantOrNull(project.deletedAt),
  'name': project.name,
  'description': project.description,
  'color': project.color.hex,
  'status': project.status.name,
  'sortOrder': project.sortOrder,
};

Map<String, Object?> planSpanToJson(PlanSpan span) => <String, Object?>{
  'id': span.id,
  'createdAt': encodeInstant(span.createdAt),
  'updatedAt': encodeInstant(span.updatedAt),
  'revision': span.revision,
  'deletedAt': encodeInstantOrNull(span.deletedAt),
  'projectId': span.projectId,
  'title': span.title,
  'startDate': span.startDate.iso,
  'endDate': span.endDate.iso,
  'status': span.status.name,
  'description': span.description,
  'color': span.color?.hex,
  'sortOrder': span.sortOrder,
};

Map<String, Object?> plannerTaskToJson(PlannerTask task) => <String, Object?>{
  'id': task.id,
  'createdAt': encodeInstant(task.createdAt),
  'updatedAt': encodeInstant(task.updatedAt),
  'revision': task.revision,
  'deletedAt': encodeInstantOrNull(task.deletedAt),
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

Map<String, Object?> dailyNoteToJson(DailyNote note) => <String, Object?>{
  'id': note.id,
  'createdAt': encodeInstant(note.createdAt),
  'updatedAt': encodeInstant(note.updatedAt),
  'revision': note.revision,
  'deletedAt': encodeInstantOrNull(note.deletedAt),
  'date': note.date.iso,
  'body': note.body,
  'focusItems': note.focusItems,
};

// ---------------------------------------------------------------------------
// JSON 转实体
// ---------------------------------------------------------------------------

Project projectFromJson(Map<String, Object?> json) => Project(
  id: _requireString(json, 'id', '项目'),
  createdAt: _requireInstant(json, 'createdAt', '项目'),
  updatedAt: _requireInstant(json, 'updatedAt', '项目'),
  revision: _requireRevision(json, '项目'),
  deletedAt: _optionalInstant(json, 'deletedAt', '项目'),
  name: _requireString(json, 'name', '项目'),
  description: _optionalString(json, 'description') ?? '',
  color: ProjectColor.fromHex(_requireString(json, 'color', '项目')),
  status: projectStatusFromDb(_requireString(json, 'status', '项目')),
  sortOrder: _optionalInt(json, 'sortOrder'),
);

PlanSpan planSpanFromJson(Map<String, Object?> json) {
  final colorHex = _optionalString(json, 'color');
  return PlanSpan(
    id: _requireString(json, 'id', '阶段'),
    createdAt: _requireInstant(json, 'createdAt', '阶段'),
    updatedAt: _requireInstant(json, 'updatedAt', '阶段'),
    revision: _requireRevision(json, '阶段'),
    deletedAt: _optionalInstant(json, 'deletedAt', '阶段'),
    projectId: _requireString(json, 'projectId', '阶段'),
    title: _requireString(json, 'title', '阶段'),
    startDate: decodeDate(
      _requireString(json, 'startDate', '阶段'),
      field: '阶段开始日',
    ),
    endDate: decodeDate(_requireString(json, 'endDate', '阶段'), field: '阶段结束日'),
    status: planSpanStatusFromDb(_requireString(json, 'status', '阶段')),
    description: _optionalString(json, 'description') ?? '',
    color: colorHex == null ? null : ProjectColor.fromHex(colorHex),
    sortOrder: _optionalInt(json, 'sortOrder'),
  );
}

PlannerTask plannerTaskFromJson(Map<String, Object?> json) {
  final rawSlot = json['timeSlot'];
  TimeSlot? timeSlot;
  if (rawSlot != null) {
    if (rawSlot is! Map<Object?, Object?>) {
      throw const PlannerValidationException('任务.timeSlot 必须是对象');
    }
    timeSlot = TimeSlot(
      startMinute: _requireIntValue(
        rawSlot['startMinute'],
        '任务.timeSlot.startMinute',
      ),
      durationMinutes: _requireIntValue(
        rawSlot['durationMinutes'],
        '任务.timeSlot.durationMinutes',
      ),
    );
  }
  final scheduled = _optionalString(json, 'scheduledDate');
  return PlannerTask(
    id: _requireString(json, 'id', '任务'),
    createdAt: _requireInstant(json, 'createdAt', '任务'),
    updatedAt: _requireInstant(json, 'updatedAt', '任务'),
    revision: _requireRevision(json, '任务'),
    deletedAt: _optionalInstant(json, 'deletedAt', '任务'),
    projectId: _optionalString(json, 'projectId'),
    spanId: _optionalString(json, 'spanId'),
    title: _requireString(json, 'title', '任务'),
    notes: _optionalString(json, 'notes') ?? '',
    scheduledDate: scheduled == null ? null : LocalDate.parse(scheduled),
    timeSlot: timeSlot,
    priority: taskPriorityFromName(_requireString(json, 'priority', '任务')),
    status: taskStatusFromDb(_requireString(json, 'status', '任务')),
    completedAt: _optionalInstant(json, 'completedAt', '任务'),
    sortOrder: _optionalInt(json, 'sortOrder'),
  );
}

DailyNote dailyNoteFromJson(Map<String, Object?> json) => DailyNote(
  id: _requireString(json, 'id', '备注'),
  createdAt: _requireInstant(json, 'createdAt', '备注'),
  updatedAt: _requireInstant(json, 'updatedAt', '备注'),
  revision: _requireRevision(json, '备注'),
  deletedAt: _optionalInstant(json, 'deletedAt', '备注'),
  date: decodeDate(_requireString(json, 'date', '备注'), field: '备注日期'),
  body: _optionalString(json, 'body') ?? '',
  focusItems: _readStringList(json['focusItems'], '备注.focusItems'),
);

// ---------------------------------------------------------------------------
// JSON 取值辅助
// ---------------------------------------------------------------------------

String _requireString(Map<String, Object?> json, String key, String label) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw PlannerValidationException('$label.$key 缺失或类型错误');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw PlannerValidationException('字段 $key 类型错误：期望文本');
  }
  return value;
}

int _requireRevision(Map<String, Object?> json, String label) {
  final revision = _requireIntValue(json['revision'], '$label.revision');
  if (revision < 1) {
    throw PlannerValidationException('$label.revision 必须不小于 1，实际 $revision');
  }
  return revision;
}

int _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return 0;
  return _requireIntValue(value, key);
}

int _requireIntValue(Object? value, String field) {
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  throw PlannerValidationException('$field 必须是整数，实际 $value');
}

DateTime _requireInstant(Map<String, Object?> json, String key, String label) =>
    decodeInstant(json[key], field: '$label.$key');

DateTime? _optionalInstant(
  Map<String, Object?> json,
  String key,
  String label,
) {
  final value = json[key];
  return value == null ? null : decodeInstant(value, field: '$label.$key');
}

List<String> _readStringList(Object? value, String field) {
  if (value == null) return const <String>[];
  if (value is! List<Object?>) {
    throw PlannerValidationException('$field 必须是字符串数组');
  }
  final items = <String>[];
  for (final element in value) {
    if (element is! String) {
      throw PlannerValidationException('$field 必须是字符串数组');
    }
    items.add(element);
  }
  return items;
}

// ---------------------------------------------------------------------------
// 实体转写入参数（顺序与 sql_schema.dart 的 INSERT / UPDATE 语句严格一致）
// ---------------------------------------------------------------------------

List<Object?> projectInsertParams(Project project) => <Object?>[
  project.id,
  encodeInstant(project.createdAt),
  encodeInstant(project.updatedAt),
  encodeInstantOrNull(project.deletedAt),
  project.revision,
  project.name,
  project.description,
  project.color.hex,
  project.status.name,
  project.sortOrder,
];

List<Object?> projectUpdateParams(Project project) => <Object?>[
  encodeInstant(project.updatedAt),
  encodeInstantOrNull(project.deletedAt),
  project.name,
  project.description,
  project.color.hex,
  project.status.name,
  project.sortOrder,
  project.revision,
  project.id,
];

List<Object?> spanInsertParams(PlanSpan span) => <Object?>[
  span.id,
  encodeInstant(span.createdAt),
  encodeInstant(span.updatedAt),
  encodeInstantOrNull(span.deletedAt),
  span.revision,
  span.projectId,
  span.title,
  span.startDate.iso,
  span.endDate.iso,
  span.status.name,
  span.description,
  span.color?.hex,
  span.sortOrder,
];

List<Object?> spanUpdateParams(PlanSpan span) => <Object?>[
  encodeInstant(span.updatedAt),
  encodeInstantOrNull(span.deletedAt),
  span.projectId,
  span.title,
  span.startDate.iso,
  span.endDate.iso,
  span.status.name,
  span.description,
  span.color?.hex,
  span.sortOrder,
  span.revision,
  span.id,
];

List<Object?> taskInsertParams(PlannerTask task) => <Object?>[
  task.id,
  encodeInstant(task.createdAt),
  encodeInstant(task.updatedAt),
  encodeInstantOrNull(task.deletedAt),
  task.revision,
  task.projectId,
  task.spanId,
  task.title,
  task.notes,
  task.scheduledDate?.iso,
  task.timeSlot?.startMinute,
  task.timeSlot?.durationMinutes,
  task.priority.level,
  task.status.name,
  encodeInstantOrNull(task.completedAt),
  task.sortOrder,
];

List<Object?> taskUpdateParams(PlannerTask task) => <Object?>[
  encodeInstant(task.updatedAt),
  encodeInstantOrNull(task.deletedAt),
  task.projectId,
  task.spanId,
  task.title,
  task.notes,
  task.scheduledDate?.iso,
  task.timeSlot?.startMinute,
  task.timeSlot?.durationMinutes,
  task.priority.level,
  task.status.name,
  encodeInstantOrNull(task.completedAt),
  task.sortOrder,
  task.revision,
  task.id,
];

List<Object?> noteInsertParams(DailyNote note) => <Object?>[
  note.id,
  encodeInstant(note.createdAt),
  encodeInstant(note.updatedAt),
  encodeInstantOrNull(note.deletedAt),
  note.revision,
  note.date.iso,
  note.body,
  encodeFocusItems(note.focusItems),
];

List<Object?> noteUpdateParams(DailyNote note) => <Object?>[
  encodeInstant(note.updatedAt),
  encodeInstantOrNull(note.deletedAt),
  note.body,
  encodeFocusItems(note.focusItems),
  note.revision,
  note.id,
];
