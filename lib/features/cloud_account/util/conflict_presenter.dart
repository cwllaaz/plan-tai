/// 把冻结契约里的 [SyncConflict]（协议 JSON）翻译成界面能直接渲染的中文差异视图。
///
/// 载荷字段名与 `docs/sync/DATA_CONTRACT.md` 的 wire 名一致（camelCase）。这里只做
/// **展示层**翻译：不判断谁对谁错，也不修改载荷。
library;

import '../../../core/cloud/cloud.dart';

/// 一行字段差异。
class ConflictFieldDiff {
  const ConflictFieldDiff({
    required this.field,
    required this.label,
    required this.localValue,
    required this.serverValue,
  });

  /// 协议字段名（wire 名），用于测试与排错。
  final String field;

  /// 中文标签。
  final String label;

  final String localValue;
  final String serverValue;

  bool get differs => localValue != serverValue;
}

/// 冲突页需要的一次性视图数据。
class ConflictViewData {
  const ConflictViewData({
    required this.conflict,
    required this.entityLabel,
    required this.kindLabel,
    required this.title,
    required this.diffs,
    required this.localDeleted,
    required this.serverDeleted,
    required this.localVersionLabel,
    required this.serverVersionLabel,
  });

  final SyncConflict conflict;

  /// 实体类型中文名：任务 / 项目 / 跨天安排 / 每日备注。
  final String entityLabel;

  /// 冲突类型中文名，例如「两边同时修改」。
  final String kindLabel;

  /// 对应任务（实体）名称。
  final String title;

  /// 主要字段差异（只含业务字段，元数据不算）。
  final List<ConflictFieldDiff> diffs;

  final bool localDeleted;
  final bool serverDeleted;

  /// 「v3」这类版本号。
  final String localVersionLabel;
  final String serverVersionLabel;

  /// 没有字段差异时的说明。
  String get emptyDiffHint =>
      '两个版本的字段内容一致，只是版本号不同（$localVersionLabel / $serverVersionLabel）。';

  static ConflictViewData from(SyncConflict conflict) {
    final local = conflict.localPayload;
    final server = conflict.serverPayload;
    final localDeleted = local == null || _isDeleted(local);
    final serverDeleted = server == null || _isDeleted(server);
    final diffs = <ConflictFieldDiff>[];
    for (final field in _orderedFields(local, server)) {
      final localText = local == null
          ? '（已删除）'
          : _formatValue(field, local[field]);
      final serverText = server == null
          ? '（已删除）'
          : _formatValue(field, server[field]);
      if (localText == serverText) continue;
      diffs.add(
        ConflictFieldDiff(
          field: field,
          label: _labelOf(field),
          localValue: localText,
          serverValue: serverText,
        ),
      );
    }
    return ConflictViewData(
      conflict: conflict,
      entityLabel: entityLabelOf(conflict.entityType),
      kindLabel: _kindLabel(conflict.kind),
      title: _titleOf(conflict),
      diffs: diffs,
      localDeleted: localDeleted,
      serverDeleted: serverDeleted,
      localVersionLabel: _versionLabel(conflict.baseRevision, local),
      serverVersionLabel: _versionLabel(conflict.serverRevision, server),
    );
  }
}

String entityLabelOf(CloudEntityType type) => switch (type) {
  CloudEntityType.project => '项目',
  CloudEntityType.span => '跨天安排',
  CloudEntityType.task => '任务',
  CloudEntityType.note => '每日备注',
};

String _kindLabel(ConflictKind kind) => switch (kind) {
  ConflictKind.updateUpdate => '本机与云端都修改了同一条记录',
  ConflictKind.updateDelete => '本机修改，云端已删除',
  ConflictKind.deleteUpdate => '本机删除，云端已修改',
  ConflictKind.createExists => '同一条记录在两边都新建',
  ConflictKind.noteDateTaken => '同一天的备注在两边都有内容',
  ConflictKind.unknown => '未知差异',
};

bool _isDeleted(Map<String, Object?> payload) => payload['deletedAt'] != null;

String _versionLabel(int revision, Map<String, Object?>? payload) {
  if (payload == null) return '已删除';
  return 'v$revision';
}

String _titleOf(SyncConflict conflict) {
  final payload = conflict.localPayload ?? conflict.serverPayload;
  final candidate = payload?['title'] ?? payload?['name'] ?? payload?['body'];
  if (candidate is String && candidate.trim().isNotEmpty) {
    final text = candidate.trim();
    if (conflict.entityType == CloudEntityType.note) {
      final date = payload?['date'];
      if (date is String && date.isNotEmpty) return '$date 备注：$text';
    }
    return text;
  }
  if (conflict.entityType == CloudEntityType.note) {
    final date = payload?['date'];
    if (date is String && date.isNotEmpty) return '$date 备注';
  }
  return '未命名${entityLabelOf(conflict.entityType)}';
}

const Map<String, String> _labels = <String, String>{
  'title': '标题',
  'name': '名称',
  'notes': '备注',
  'body': '内容',
  'description': '说明',
  'scheduledDate': '日期',
  'startDate': '开始日期',
  'endDate': '结束日期',
  'timeSlot': '时间',
  'projectId': '所属项目',
  'spanId': '所属安排',
  'priority': '优先级',
  'status': '状态',
  'completedAt': '完成时间',
  'color': '颜色',
  'focusItems': '当日重点',
  'sortOrder': '排序',
  'date': '日期',
  'deletedAt': '删除状态',
};

String _labelOf(String field) => _labels[field] ?? field;

/// 固定顺序：先用户能看懂的文本，再时间，再关联。
const List<String> _fieldOrder = <String>[
  'title',
  'name',
  'body',
  'scheduledDate',
  'date',
  'timeSlot',
  'startDate',
  'endDate',
  'status',
  'priority',
  'notes',
  'description',
  'projectId',
  'spanId',
  'color',
  'focusItems',
  'sortOrder',
  'completedAt',
  'deletedAt',
];

/// 同步元数据：每条记录都会变，放进「主要字段差异」只是噪音。
const Set<String> _metadataFields = <String>{
  'revision',
  'updatedAt',
  'createdAt',
};

List<String> _orderedFields(
  Map<String, Object?>? local,
  Map<String, Object?>? server,
) {
  final keys = <String>{...?local?.keys, ...?server?.keys}
    ..removeAll(_metadataFields);
  final ordered = <String>[
    for (final field in _fieldOrder)
      if (keys.contains(field)) field,
  ];
  final rest = keys.where((key) => !_fieldOrder.contains(key)).toList()..sort();
  return <String>[...ordered, ...rest];
}

String _formatValue(String field, Object? value) {
  if (value == null) return '（空）';
  if (field == 'timeSlot' && value is Map) {
    final start = value['startMinute'];
    final duration = value['durationMinutes'];
    if (start is int && duration is int) {
      return '${_clock(start)}–${_clock(start + duration)}';
    }
  }
  if (value is bool) return value ? '是' : '否';
  if (value is List) {
    final parts = value
        .map((item) => item is String ? item.trim() : '$item')
        .where((item) => item.isNotEmpty)
        .toList();
    return parts.isEmpty ? '（空）' : parts.join('、');
  }
  if (field == 'status' && value is String) {
    return _statusLabel(value);
  }
  if (field == 'priority') {
    if (value is int) return _priorityLabel(value);
    if (value is String) return _priorityLabelText(value);
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('，');
  }
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return '（空）';
    if (field == 'projectId' || field == 'spanId') {
      return text.length <= 8 ? text : '${text.substring(0, 8)}…';
    }
    if (field == 'deletedAt') return '已删除';
    final isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
    if (isoDate != null) {
      final year = int.parse(isoDate.group(1)!);
      final month = int.parse(isoDate.group(2)!);
      final day = int.parse(isoDate.group(3)!);
      return '$year年$month月$day日';
    }
    return text;
  }
  return '$value';
}

String _statusLabel(String value) => switch (value) {
  'todo' => '未完成',
  'done' => '已完成',
  'planned' => '计划中',
  'doing' => '进行中',
  'dropped' => '已放弃',
  'active' => '进行中',
  'paused' => '已暂停',
  'archived' => '已归档',
  _ => value,
};

String _priorityLabel(int level) => switch (level) {
  0 => '低',
  1 => '普通',
  2 => '高',
  3 => '紧急',
  _ => '$level',
};

String _priorityLabelText(String value) => switch (value) {
  'low' => '低',
  'normal' => '普通',
  'high' => '高',
  'urgent' => '紧急',
  _ => value,
};

String _clock(int minuteOfDay) {
  final hour = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final minute = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}
