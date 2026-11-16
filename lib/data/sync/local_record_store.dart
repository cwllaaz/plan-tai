/// 本地业务表的「同步视角」访问层：可以读写软删除行，并维护 `server_revision`。
///
/// 云端写入只经过这里，**不调用仓储的写方法**，因此不会写 change_log/outbox，
/// 从根上避免"拉下来的数据又当成本机新增上传"的循环。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../core/cloud/cloud_types.dart';
import '../../core/models/models.dart';
import '../entity_codec.dart';
import '../planner_database.dart';
import '../sql_schema.dart';
import 'sync_payloads.dart';

/// 一条从未上传过的本地记录（首次连接 / 升级对账时需要认领）。
final class UnsyncedRecord {
  const UnsyncedRecord({
    required this.entityType,
    required this.entityId,
    required this.localRevision,
    required this.payload,
  });

  final CloudEntityType entityType;
  final String entityId;
  final int localRevision;
  final Map<String, Object?> payload;
}

final class LocalRecordStore {
  LocalRecordStore(this.database);

  final PlannerDatabase database;

  Database get _handle => database.handle;

  // -------------------------------------------------------------------------
  // 读
  // -------------------------------------------------------------------------

  /// 读取实体（**包含软删除记录**）；不存在返回 null。
  Object? readEntity(CloudEntityType type, String entityId) {
    final row = _readRow(type, entityId);
    return row == null ? null : _fromRow(type, row);
  }

  int serverRevision(CloudEntityType type, String entityId) {
    final rows = _handle.select(
      'SELECT server_revision FROM ${_table(type)} WHERE id = ?',
      <Object?>[entityId],
    );
    return rows.isEmpty ? 0 : rows.first['server_revision'] as int;
  }

  bool exists(CloudEntityType type, String entityId) =>
      _readRow(type, entityId) != null;

  Map<String, Object?>? readPayload(CloudEntityType type, String entityId) {
    final entity = readEntity(type, entityId);
    if (entity == null) return null;
    return syncPayloadOf(type, entity as PlannerEntity);
  }

  int liveRecordCount() {
    var total = 0;
    for (final type in CloudEntityType.values) {
      final row = _handle
          .select(
            'SELECT COUNT(*) AS c FROM ${_table(type)} WHERE deleted_at IS NULL',
          )
          .first;
      final count = row['c'];
      if (count is int) total += count;
    }
    return total;
  }

  /// 当前仍需上传的本地记录：从未上传、未删除、且队列/冲突里都没有它。
  List<UnsyncedRecord> unsyncedRecords() {
    final result = <UnsyncedRecord>[];
    for (final type in CloudEntityType.values) {
      final rows = _handle.select(
        'SELECT * FROM ${_table(type)} '
        'WHERE server_revision = 0 AND deleted_at IS NULL',
      );
      for (final row in rows) {
        final entity = _fromRow(type, row);
        final entityId = entity.id;
        final queued = _handle
            .select(
              'SELECT 1 FROM sync_outbox WHERE entity_type = ? AND entity_id = ? '
              'LIMIT 1',
              <Object?>[type.wireName, entityId],
            )
            .isNotEmpty;
        if (queued) continue;
        final conflicted = _handle
            .select(
              'SELECT 1 FROM sync_conflicts WHERE entity_type = ? '
              'AND entity_id = ? AND resolved_at IS NULL LIMIT 1',
              <Object?>[type.wireName, entityId],
            )
            .isNotEmpty;
        if (conflicted) continue;
        result.add(
          UnsyncedRecord(
            entityType: type,
            entityId: entityId,
            localRevision: entity.revision,
            payload: syncPayloadOf(type, entity),
          ),
        );
      }
    }
    return result;
  }

  /// 同一天存活备注的 ID（note 唯一性冲突检测）。
  String? liveNoteIdForDate(String dateIso) {
    final rows = _handle.select(
      'SELECT id FROM daily_notes WHERE date = ? AND deleted_at IS NULL',
      <Object?>[dateIso],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  String? noteDateOf(String noteId) {
    final rows = _handle.select(
      'SELECT date FROM daily_notes WHERE id = ?',
      <Object?>[noteId],
    );
    return rows.isEmpty ? null : rows.first['date'] as String;
  }

  // -------------------------------------------------------------------------
  // 写（仅云端 → 本地）
  // -------------------------------------------------------------------------

  /// 用云端 payload 覆盖/插入本地记录，返回写入后的本地 revision。
  int applyRemote({
    required CloudEntityType type,
    required String entityId,
    required Map<String, Object?> payload,
    required int serverRevision,
    required DateTime serverUpdatedAt,
    DateTime? deletedAt,
  }) {
    final existing = readEntity(type, entityId);
    final revision = existing == null
        ? _max(serverRevision, 1)
        : _max((existing as PlannerEntity).revision + 1, serverRevision);
    final entity = _decode(
      type,
      entityId,
      payload,
      revision: revision,
      updatedAt: serverUpdatedAt,
      deletedAt: deletedAt,
    );
    if (existing == null) {
      _insert(type, entity);
    } else {
      _update(type, entity);
    }
    setServerRevision(type, entityId, serverRevision);
    return revision;
  }

  void softDelete({
    required CloudEntityType type,
    required String entityId,
    required DateTime deletedAt,
    required DateTime serverUpdatedAt,
    required int serverRevision,
  }) {
    final existing = readEntity(type, entityId);
    if (existing == null) return;
    final revision = _max((existing as PlannerEntity).revision + 1, serverRevision);
    _handle.execute(
      'UPDATE ${_table(type)} SET deleted_at = ?, updated_at = ?, '
      'revision = ?, server_revision = ? WHERE id = ?',
      <Object?>[
        encodeInstant(deletedAt),
        encodeInstant(serverUpdatedAt),
        revision,
        serverRevision,
        entityId,
      ],
    );
  }

  void setServerRevision(CloudEntityType type, String entityId, int revision) {
    _handle.execute(
      'UPDATE ${_table(type)} SET server_revision = ? WHERE id = ?',
      <Object?>[revision, entityId],
    );
  }

  /// 把本地备注改写成服务端那条记录的 ID（NOTE_DATE_TAKEN 的"保留本地"方案）。
  void adoptEntityId({
    required CloudEntityType type,
    required String fromId,
    required String toId,
    required Map<String, Object?> payload,
    required int serverRevision,
    required DateTime updatedAt,
  }) {
    if (type != CloudEntityType.note) {
      throw StateError('adoptEntityId 目前只用于 note');
    }
    final note = noteFromSyncPayload(
      id: toId,
      payload: payload,
      revision: 1,
      updatedAt: updatedAt,
    );
    _handle.execute(
      'UPDATE daily_notes SET id = ?, body = ?, focus_items = ?, '
      'updated_at = ?, revision = revision + 1, server_revision = ? '
      'WHERE id = ?',
      <Object?>[
        toId,
        note.body,
        encodeFocusItems(note.focusItems),
        encodeInstant(updatedAt),
        serverRevision,
        fromId,
      ],
    );
  }

  /// 用本地 payload 新建一条**新 ID** 的记录（UPDATE_DELETE 的"保留本地为新副本"）。
  String insertCopyWithNewId({
    required CloudEntityType type,
    required Map<String, Object?> payload,
    required String newId,
    required DateTime now,
  }) {
    final entity = _decode(
      type,
      newId,
      payload,
      revision: 1,
      updatedAt: now,
      deletedAt: null,
    );
    if (type == CloudEntityType.note) {
      final note = entity as DailyNote;
      if (liveNoteIdForDate(note.date.iso) != null) {
        throw const PlannerValidationException('同一天已有另一条备注，无法新建副本');
      }
    }
    _insert(type, entity);
    setServerRevision(type, newId, 0);
    return newId;
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  Row? _readRow(CloudEntityType type, String entityId) {
    final columns = switch (type) {
      CloudEntityType.project => projectColumns,
      CloudEntityType.span => spanColumns,
      CloudEntityType.task => taskColumns,
      CloudEntityType.note => noteColumns,
    };
    final rows = _handle.select(
      'SELECT $columns FROM ${_table(type)} WHERE id = ?',
      <Object?>[entityId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  PlannerEntity _fromRow(CloudEntityType type, Row row) => switch (type) {
    CloudEntityType.project => projectFromRow(row),
    CloudEntityType.span => planSpanFromRow(row),
    CloudEntityType.task => plannerTaskFromRow(row),
    CloudEntityType.note => dailyNoteFromRow(row),
  };

  PlannerEntity _decode(
    CloudEntityType type,
    String id,
    Map<String, Object?> payload, {
    required int revision,
    required DateTime updatedAt,
    DateTime? deletedAt,
  }) => switch (type) {
    CloudEntityType.project => projectFromSyncPayload(
      id: id,
      payload: payload,
      revision: revision,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    ),
    CloudEntityType.span => spanFromSyncPayload(
      id: id,
      payload: payload,
      revision: revision,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    ),
    CloudEntityType.task => taskFromSyncPayload(
      id: id,
      payload: payload,
      revision: revision,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    ),
    CloudEntityType.note => noteFromSyncPayload(
      id: id,
      payload: payload,
      revision: revision,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    ),
  };

  void _insert(CloudEntityType type, PlannerEntity entity) {
    final handle = _handle;
    switch (type) {
      case CloudEntityType.project:
        handle.execute(insertProjectSql, projectInsertParams(entity as Project));
      case CloudEntityType.span:
        handle.execute(insertSpanSql, spanInsertParams(entity as PlanSpan));
      case CloudEntityType.task:
        handle.execute(insertTaskSql, taskInsertParams(entity as PlannerTask));
      case CloudEntityType.note:
        handle.execute(insertNoteSql, noteInsertParams(entity as DailyNote));
    }
  }

  void _update(CloudEntityType type, PlannerEntity entity) {
    final handle = _handle;
    switch (type) {
      case CloudEntityType.project:
        handle.execute(updateProjectSql, projectUpdateParams(entity as Project));
      case CloudEntityType.span:
        handle.execute(updateSpanSql, spanUpdateParams(entity as PlanSpan));
      case CloudEntityType.task:
        handle.execute(updateTaskSql, taskUpdateParams(entity as PlannerTask));
      case CloudEntityType.note:
        handle.execute(updateNoteSql, noteUpdateParams(entity as DailyNote));
    }
  }

  static String _table(CloudEntityType type) => switch (type) {
    CloudEntityType.project => 'projects',
    CloudEntityType.span => 'plan_spans',
    CloudEntityType.task => 'planner_tasks',
    CloudEntityType.note => 'daily_notes',
  };

  static int _max(int a, int b) => a > b ? a : b;
}

/// 比较两份协议 payload 的业务语义是否相同（键顺序无关）。
bool payloadsEquivalent(
  Map<String, Object?> a,
  Map<String, Object?> b,
) => _canonical(a) == _canonical(b);

String _canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map<Object?, Object?>) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    final result = <String, Object?>{};
    for (final key in keys) {
      result[key] = _sorted(value[key]);
    }
    return result;
  }
  if (value is List<Object?>) {
    return value.map(_sorted).toList(growable: false);
  }
  return value;
}
