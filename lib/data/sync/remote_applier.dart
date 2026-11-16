/// 把服务端增量变化合并进本地数据库。
///
/// 规则（docs/sync/ARCHITECTURE.md §4.2/§5、DATA_CONTRACT §3.3/§4.2）：
/// - 服务端是版本权威：没有本地待上传修改时直接采用服务端版本；
/// - 本地有未上传修改时**绝不覆盖本地**，落一条可恢复的冲突；
/// - 首次/修复的全量对账（`fullReconcile`）中，本地未上传的差异进入 outbox，
///   采用服务端 revision 后由随后 push 提交；
/// - 墓碑只软删除，不物理删行；未知墓碑直接忽略。
library;

import '../../core/cloud/cloud_types.dart';
import '../../core/models/models.dart';
import '../cloud/planner_api.dart';
import '../planner_database.dart';
import 'local_record_store.dart';
import 'sync_conflict_store.dart';
import 'sync_outbox_store.dart';

enum RemoteApplyOutcome { applied, skipped, conflict, reconciled }

final class RemoteApplier {
  RemoteApplier({
    required this.database,
    required this.outbox,
    required this.conflicts,
    required this.records,
    required this.deviceId,
    DateTime Function()? clock,
    String Function()? idGenerator,
  }) : _clock = clock ?? DateTime.now,
       _newId = idGenerator ?? Ids.newId;

  final PlannerDatabase database;
  final SyncOutboxStore outbox;
  final SyncConflictStore conflicts;
  final LocalRecordStore records;
  final String deviceId;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// 必须在同步引擎的事务里调用。
  RemoteApplyOutcome apply(PullChange change, {required bool fullReconcile}) {
    final type = change.entityType;
    final entityId = change.entityId;
    final now = _clock().toUtc();
    final localServerRevision = records.serverRevision(type, entityId);
    if (localServerRevision >= change.serverRevision) {
      return RemoteApplyOutcome.skipped;
    }

    final pending = outbox.forEntity(type.wireName, entityId);
    if (pending.isNotEmpty) {
      final allDelete = pending.every((entry) => entry.isDelete);
      if (change.deleted && allDelete) {
        records.softDelete(
          type: type,
          entityId: entityId,
          deletedAt: change.deletedAt ?? now,
          serverUpdatedAt: change.serverUpdatedAt ?? now,
          serverRevision: change.serverRevision,
        );
        for (final entry in pending) {
          outbox.remove(entry.opId);
        }
        return RemoteApplyOutcome.applied;
      }
      final first = pending.first;
      final kind = change.deleted
          ? ConflictKind.updateDelete
          : first.isDelete
          ? ConflictKind.deleteUpdate
          : ConflictKind.updateUpdate;
      _saveConflict(
        type: type,
        entityId: entityId,
        kind: kind,
        baseRevision: first.baseRevision,
        serverRevision: change.serverRevision,
        serverDeleted: change.deleted,
        localPayload: first.isDelete ? null : first.payload,
        serverPayload: change.payload,
      );
      return RemoteApplyOutcome.conflict;
    }

    final existing = records.readEntity(type, entityId);

    if (change.deleted) {
      if (existing == null) return RemoteApplyOutcome.skipped;
      records.softDelete(
        type: type,
        entityId: entityId,
        deletedAt: change.deletedAt ?? now,
        serverUpdatedAt: change.serverUpdatedAt ?? now,
        serverRevision: change.serverRevision,
      );
      return RemoteApplyOutcome.applied;
    }

    final serverPayload = change.payload;
    if (serverPayload == null) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '服务端返回了未删除但没有 payload 的变更',
      );
    }

    if (existing == null) {
      if (type == CloudEntityType.note) {
        final date = serverPayload['date'];
        if (date is! String) {
          throw const CloudException(CloudErrorKind.protocol, '备注载荷缺少 date');
        }
        final localNoteId = records.liveNoteIdForDate(date);
        if (localNoteId != null) {
          _saveConflict(
            type: type,
            entityId: entityId,
            kind: ConflictKind.noteDateTaken,
            baseRevision: 0,
            serverRevision: change.serverRevision,
            serverDeleted: false,
            localPayload: records.readPayload(type, localNoteId),
            serverPayload: serverPayload,
          );
          return RemoteApplyOutcome.conflict;
        }
      }
      records.applyRemote(
        type: type,
        entityId: entityId,
        payload: serverPayload,
        serverRevision: change.serverRevision,
        serverUpdatedAt: change.serverUpdatedAt ?? now,
      );
      return RemoteApplyOutcome.applied;
    }

    final localPayload = records.readPayload(type, entityId);
    if (localServerRevision == 0 &&
        localPayload != null &&
        !payloadsEquivalent(localPayload, serverPayload)) {
      if (fullReconcile) {
        // 升级对账：本地是用户真实数据，采用服务端版本作为 base 后排队上传。
        SyncOutboxStore.record(
          database.handle,
          entityType: type.wireName,
          entityId: entityId,
          operation: 'update',
          baseRevision: change.serverRevision,
          localRevision: (existing as PlannerEntity).revision,
          payload: localPayload,
          deviceId: deviceId,
          at: now,
          newOpId: _newId(),
        );
        records.setServerRevision(type, entityId, change.serverRevision);
        return RemoteApplyOutcome.reconciled;
      }
      _saveConflict(
        type: type,
        entityId: entityId,
        kind: ConflictKind.updateUpdate,
        baseRevision: 0,
        serverRevision: change.serverRevision,
        serverDeleted: false,
        localPayload: localPayload,
        serverPayload: serverPayload,
      );
      return RemoteApplyOutcome.conflict;
    }

    records.applyRemote(
      type: type,
      entityId: entityId,
      payload: serverPayload,
      serverRevision: change.serverRevision,
      serverUpdatedAt: change.serverUpdatedAt ?? now,
    );
    return RemoteApplyOutcome.applied;
  }

  /// 用户确认“覆盖并更新”后使用：忽略本机 serverRevision / outbox，
  /// 直接采用云端版本。调用前引擎已清空本机业务表、outbox 与冲突，
  /// 因此这里不再需要考虑本机独有记录。
  RemoteApplyOutcome applyForce(PullChange change) {
    final type = change.entityType;
    final entityId = change.entityId;
    final now = _clock().toUtc();

    if (change.deleted) {
      if (!records.exists(type, entityId)) {
        return RemoteApplyOutcome.skipped;
      }
      records.softDelete(
        type: type,
        entityId: entityId,
        deletedAt: change.deletedAt ?? now,
        serverUpdatedAt: change.serverUpdatedAt ?? now,
        serverRevision: change.serverRevision,
      );
      return RemoteApplyOutcome.applied;
    }

    final payload = change.payload;
    if (payload == null) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '服务端返回了未删除但没有 payload 的变更',
      );
    }

    // 备注按日期唯一：云端版本要落地时，先让出同一天的本地备注。
    if (type == CloudEntityType.note) {
      final date = payload['date'];
      if (date is String) {
        final localNoteId = records.liveNoteIdForDate(date);
        if (localNoteId != null && localNoteId != entityId) {
          records.softDelete(
            type: type,
            entityId: localNoteId,
            deletedAt: now,
            serverUpdatedAt: now,
            serverRevision: 0,
          );
        }
      }
    }

    records.applyRemote(
      type: type,
      entityId: entityId,
      payload: payload,
      serverRevision: change.serverRevision,
      serverUpdatedAt: change.serverUpdatedAt ?? now,
    );
    return RemoteApplyOutcome.applied;
  }

  void _saveConflict({
    required CloudEntityType type,
    required String entityId,
    required ConflictKind kind,
    required int baseRevision,
    required int serverRevision,
    required bool serverDeleted,
    required Map<String, Object?>? localPayload,
    required Map<String, Object?>? serverPayload,
  }) {
    conflicts.upsert(
      SyncConflict(
        id: _newId(),
        entityType: type,
        entityId: entityId,
        baseRevision: baseRevision,
        serverRevision: serverRevision,
        kind: kind,
        detectedAt: _clock().toUtc(),
        localPayload: localPayload,
        serverPayload: serverPayload,
        serverDeleted: serverDeleted,
      ),
    );
  }
}
