/// `sync_conflicts` 表的读写（字段见 docs/sync/DATA_CONTRACT.md §7.2）。
///
/// 冲突必须持久化：软件重启后仍要能展示"本地意图 vs 服务端内容"，
/// 在用户选择之前绝不自动标记已解决。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../core/cloud/cloud_types.dart';
import '../entity_codec.dart';
import '../planner_database.dart';

final class SyncConflictStore {
  SyncConflictStore(this.database);

  final PlannerDatabase database;

  Database get _handle => database.handle;

  List<SyncConflict> listOpen() {
    final rows = _handle.select(
      'SELECT * FROM sync_conflicts WHERE resolved_at IS NULL '
      'ORDER BY detected_at, id',
    );
    return List<SyncConflict>.unmodifiable(rows.map(_fromRow));
  }

  SyncConflict? find(String id) {
    final rows = _handle.select(
      'SELECT * FROM sync_conflicts WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  SyncConflict? findOpenForEntity(CloudEntityType type, String entityId) {
    final rows = _handle.select(
      'SELECT * FROM sync_conflicts WHERE entity_type = ? AND entity_id = ? '
      'AND resolved_at IS NULL',
      <Object?>[type.wireName, entityId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  int countOpen() {
    final row = _handle
        .select(
          'SELECT COUNT(*) AS c FROM sync_conflicts WHERE resolved_at IS NULL',
        )
        .first;
    final value = row['c'];
    return value is int ? value : 0;
  }

  /// 写入或刷新同一实体的未解决冲突。
  void upsert(SyncConflict conflict) {
    _handle.execute(
      'DELETE FROM sync_conflicts WHERE entity_type = ? AND entity_id = ? '
      'AND resolved_at IS NULL',
      <Object?>[conflict.entityType.wireName, conflict.entityId],
    );
    _handle.execute(
      'INSERT OR REPLACE INTO sync_conflicts(id, entity_type, entity_id, kind, '
      'base_revision, server_revision, server_deleted, local_payload, '
      'server_payload, detected_at, resolved_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        conflict.id,
        conflict.entityType.wireName,
        conflict.entityId,
        conflict.kind.wireName,
        conflict.baseRevision,
        conflict.serverRevision,
        conflict.serverDeleted ? 1 : 0,
        conflict.localPayload == null
            ? null
            : jsonEncode(conflict.localPayload),
        conflict.serverPayload == null
            ? null
            : jsonEncode(conflict.serverPayload),
        encodeInstant(conflict.detectedAt),
        null,
      ],
    );
  }

  void delete(String id) {
    _handle.execute('DELETE FROM sync_conflicts WHERE id = ?', <Object?>[id]);
  }

  void deleteForEntity(CloudEntityType type, String entityId) {
    _handle.execute(
      'DELETE FROM sync_conflicts WHERE entity_type = ? AND entity_id = ?',
      <Object?>[type.wireName, entityId],
    );
  }

  SyncConflict _fromRow(Row row) {
    final localRaw = row['local_payload'] as String?;
    final serverRaw = row['server_payload'] as String?;
    return SyncConflict(
      id: row['id'] as String,
      entityType: CloudEntityType.tryParse(row['entity_type'] as String) ??
          CloudEntityType.task,
      entityId: row['entity_id'] as String,
      kind: ConflictKind.fromWire(row['kind'] as String),
      baseRevision: row['base_revision'] as int,
      serverRevision: row['server_revision'] as int,
      serverDeleted: (row['server_deleted'] as int) != 0,
      localPayload: localRaw == null
          ? null
          : Map<String, Object?>.from(
              jsonDecode(localRaw) as Map<Object?, Object?>,
            ),
      serverPayload: serverRaw == null
          ? null
          : Map<String, Object?>.from(
              jsonDecode(serverRaw) as Map<Object?, Object?>,
            ),
      detectedAt: decodeInstant(row['detected_at'], field: '冲突发现时间'),
    );
  }
}
