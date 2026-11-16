/// 离线操作队列（outbox）的 SQLite 实现。
///
/// 与 docs/sync/DATA_CONTRACT.md §7.2/§7.3 严格对应：
/// - 唯一索引只约束 `pending` 行；`sending` 期间的新修改会**新增一条 pending**，
///   旧操作确认后只删除旧 opId，绝不把新改动误标为已同步；
/// - 同一实体连续修改可把 pending 行合并（更新 payload / local_revision），
///   opId 首次生成后不再改变；
/// - 从未上传（baseRevision=0）就被删除的记录直接丢弃队列行；
/// - 业务写入与队列写入由仓储放在同一个事务里。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../entity_codec.dart';
import '../planner_database.dart';

enum OutboxOperation {
  create('create'),
  update('update'),
  delete('delete');

  const OutboxOperation(this.wire);

  final String wire;

  static OutboxOperation fromWire(String value) => switch (value) {
    'create' => OutboxOperation.create,
    'update' => OutboxOperation.update,
    'delete' => OutboxOperation.delete,
    _ => throw FormatException('未知 outbox 操作：$value'),
  };
}

final class OutboxEntry {
  const OutboxEntry({
    required this.opId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.baseRevision,
    required this.localRevision,
    required this.payloadJson,
    required this.deviceId,
    required this.state,
    required this.attempts,
    required this.createdAt,
    required this.updatedAt,
    this.nextAttemptAt,
    this.lastError,
  });

  factory OutboxEntry.fromRow(Row row) => OutboxEntry(
    opId: row['op_id'] as String,
    entityType: row['entity_type'] as String,
    entityId: row['entity_id'] as String,
    operation: OutboxOperation.fromWire(row['operation'] as String),
    baseRevision: row['base_revision'] as int,
    localRevision: row['local_revision'] as int,
    payloadJson: row['payload'] as String,
    deviceId: row['device_id'] as String,
    state: row['state'] as String,
    attempts: row['attempts'] as int,
    nextAttemptAt: decodeInstantOrNull(
      row['next_attempt_at'],
      field: '下次重试时间',
    ),
    lastError: row['last_error'] as String?,
    createdAt: decodeInstant(row['created_at'], field: '操作创建时间'),
    updatedAt: decodeInstant(row['updated_at'], field: '操作更新时间'),
  );

  final String opId;
  final String entityType;
  final String entityId;
  final OutboxOperation operation;
  final int baseRevision;
  final int localRevision;
  final String payloadJson;
  final String deviceId;
  final String state;
  final int attempts;
  final DateTime? nextAttemptAt;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> get payload {
    if (payloadJson.trim().isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(payloadJson);
    return decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
  }

  bool get isDelete => operation == OutboxOperation.delete;

  @override
  String toString() =>
      'OutboxEntry($entityType/$entityId ${operation.wire} '
      'base=$baseRevision op=$opId state=$state)';
}

final class SyncOutboxStore {
  SyncOutboxStore(this.database);

  final PlannerDatabase database;

  Database get _handle => database.handle;

  // -------------------------------------------------------------------------
  // 入队（必须在仓储的写事务内调用）
  // -------------------------------------------------------------------------

  static void record(
    Database handle, {
    required String entityType,
    required String entityId,
    required String operation,
    required int baseRevision,
    required int localRevision,
    required Map<String, Object?> payload,
    required String deviceId,
    required DateTime at,
    required String newOpId,
  }) {
    final stamp = encodeInstant(at);
    final rows = handle.select(
      'SELECT op_id, operation, base_revision, attempts, state '
      'FROM sync_outbox WHERE entity_type = ? AND entity_id = ? '
      "AND state IN ('pending', 'sending', 'failed') "
      "ORDER BY CASE state WHEN 'pending' THEN 0 WHEN 'failed' THEN 1 ELSE 2 END, "
      'created_at',
      <Object?>[entityType, entityId],
    );
    Row? pending;
    Row? sending;
    Row? failed;
    for (final row in rows) {
      switch (row['state'] as String) {
        case 'pending':
          pending ??= row;
        case 'sending':
          sending ??= row;
        case 'failed':
          failed ??= row;
      }
    }

    final delete = operation == 'delete';
    final mergeable = pending ?? failed;

    // 从未上传就被删除：云端从未见过它，无需上传墓碑。
    if (delete &&
        sending == null &&
        mergeable != null &&
        (mergeable['base_revision'] as int) == 0 &&
        (mergeable['attempts'] as int) == 0 &&
        mergeable['operation'] != 'delete') {
      handle.execute(
        'DELETE FROM sync_outbox WHERE op_id = ?',
        <Object?>[mergeable['op_id']],
      );
      return;
    }

    if (mergeable != null) {
      final existingBase = mergeable['base_revision'] as int;
      final existingOperation = mergeable['operation'] as String;
      final nextOperation = delete
          ? 'delete'
          : existingOperation == 'create' && existingBase == 0
          ? 'create'
          : operation;
      handle.execute(
        'UPDATE sync_outbox SET operation = ?, base_revision = ?, '
        'local_revision = ?, payload = ?, state = ?, attempts = 0, '
        'next_attempt_at = NULL, last_error = NULL, updated_at = ? '
        'WHERE op_id = ?',
        <Object?>[
          nextOperation,
          existingBase < baseRevision ? existingBase : baseRevision,
          localRevision,
          delete ? '{}' : jsonEncode(payload),
          'pending',
          stamp,
          mergeable['op_id'],
        ],
      );
      return;
    }

    if (delete && sending == null && baseRevision == 0) {
      return;
    }

    handle.execute(
      'INSERT INTO sync_outbox(op_id, entity_type, entity_id, operation, '
      'base_revision, local_revision, payload, device_id, state, attempts, '
      'created_at, updated_at) '
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)",
      <Object?>[
        newOpId,
        entityType,
        entityId,
        operation,
        baseRevision,
        localRevision,
        delete ? '{}' : jsonEncode(payload),
        deviceId,
        stamp,
        stamp,
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------------

  List<OutboxEntry> due({int limit = 100, DateTime? now}) {
    final at = encodeInstant((now ?? DateTime.now()).toUtc());
    final rows = _handle.select(
      'SELECT o.* FROM sync_outbox o '
      "WHERE (o.state = 'pending' "
      "       OR (o.state = 'failed' AND (o.next_attempt_at IS NULL "
      '           OR o.next_attempt_at <= ?))) '
      'AND NOT EXISTS (SELECT 1 FROM sync_conflicts c '
      '                WHERE c.resolved_at IS NULL '
      '                AND c.entity_type = o.entity_type '
      '                AND c.entity_id = o.entity_id) '
      'ORDER BY CASE o.entity_type '
      "WHEN 'project' THEN 0 WHEN 'span' THEN 1 "
      "WHEN 'task' THEN 2 ELSE 3 END, o.created_at, o.op_id "
      'LIMIT ?',
      <Object?>[at, limit],
    );
    return List<OutboxEntry>.unmodifiable(rows.map(OutboxEntry.fromRow));
  }

  List<OutboxEntry> claim({int limit = 100, DateTime? now}) {
    return database.transaction(() {
      final entries = due(limit: limit, now: now);
      for (final entry in entries) {
        _handle.execute(
          "UPDATE sync_outbox SET state = 'sending' WHERE op_id = ?",
          <Object?>[entry.opId],
        );
      }
      return entries;
    });
  }

  OutboxEntry? findByOpId(String opId) {
    final rows = _handle.select(
      'SELECT * FROM sync_outbox WHERE op_id = ?',
      <Object?>[opId],
    );
    return rows.isEmpty ? null : OutboxEntry.fromRow(rows.first);
  }

  List<OutboxEntry> forEntity(String entityType, String entityId) {
    final rows = _handle.select(
      'SELECT * FROM sync_outbox WHERE entity_type = ? AND entity_id = ? '
      'ORDER BY created_at',
      <Object?>[entityType, entityId],
    );
    return List<OutboxEntry>.unmodifiable(rows.map(OutboxEntry.fromRow));
  }

  List<OutboxEntry> all() {
    final rows = _handle.select(
      'SELECT * FROM sync_outbox ORDER BY created_at, op_id',
    );
    return List<OutboxEntry>.unmodifiable(rows.map(OutboxEntry.fromRow));
  }

  int count() {
    final row = _handle.select('SELECT COUNT(*) AS c FROM sync_outbox').first;
    final value = row['c'];
    return value is int ? value : 0;
  }

  /// 上次进程异常退出残留的 `sending` → `failed`（下次同步立即重试）。
  ///
  /// 不能简单退回 pending：崩溃前若又新增了 pending，会撞唯一索引。
  int resetStaleSending() {
    final row = _handle
        .select("SELECT COUNT(*) AS c FROM sync_outbox WHERE state = 'sending'")
        .first;
    final count = row['c'] as int;
    if (count == 0) return 0;
    _handle.execute(
      "UPDATE sync_outbox SET state = 'failed', next_attempt_at = NULL "
      "WHERE state = 'sending'",
    );
    return count;
  }

  // -------------------------------------------------------------------------
  // 状态流转
  // -------------------------------------------------------------------------

  void acknowledge({required String opId, required int serverRevision}) {
    final row = findByOpId(opId);
    if (row == null) return;
    _handle.execute('DELETE FROM sync_outbox WHERE op_id = ?', <Object?>[opId]);

    // 发送期间本地又改过：待上传行的 base 推进到服务端新版本，
    // 且 create 升级为 update，避免下一次 push 仍按 create 发送。
    _handle.execute(
      'UPDATE sync_outbox SET base_revision = ?, '
      "operation = CASE WHEN operation = 'create' THEN 'update' "
      'ELSE operation END '
      'WHERE entity_type = ? AND entity_id = ? '
      "AND state = 'pending' AND base_revision < ?",
      <Object?>[serverRevision, row.entityType, row.entityId, serverRevision],
    );
  }

  void markFailed({
    required String opId,
    required String error,
    required DateTime nextAttemptAt,
  }) {
    _handle.execute(
      "UPDATE sync_outbox SET state = 'failed', attempts = attempts + 1, "
      'last_error = ?, next_attempt_at = ? WHERE op_id = ?',
      <Object?>[_trim(error), encodeInstant(nextAttemptAt), opId],
    );
  }

  /// 永久性拒绝：保留记录供用户查看，但不再自动重试。
  void markRejected({
    required String opId,
    required String error,
    required DateTime at,
  }) {
    _handle.execute(
      "UPDATE sync_outbox SET state = 'failed', attempts = attempts + 1, "
      'last_error = ?, next_attempt_at = ? WHERE op_id = ?',
      <Object?>[
        _trim(error),
        encodeInstant(at.add(const Duration(days: 365))),
        opId,
      ],
    );
  }

  void remove(String opId) {
    _handle.execute('DELETE FROM sync_outbox WHERE op_id = ?', <Object?>[opId]);
  }

  void removeForEntity(String entityType, String entityId) {
    _handle.execute(
      'DELETE FROM sync_outbox WHERE entity_type = ? AND entity_id = ?',
      <Object?>[entityType, entityId],
    );
  }

  void clearBackoff(DateTime now) {
    _handle.execute(
      'UPDATE sync_outbox SET next_attempt_at = ? '
      "WHERE state = 'failed' AND (next_attempt_at IS NULL OR next_attempt_at > ?)",
      <Object?>[encodeInstant(now), encodeInstant(now)],
    );
  }

  /// 恢复备份后清空队列与未解决冲突（备份里的实体没有可靠 opId）。
  void clearAll() {
    _handle.execute('DELETE FROM sync_outbox');
  }

  static String _trim(String error) =>
      error.length > 1000 ? error.substring(0, 1000) : error;
}
