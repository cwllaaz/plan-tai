// ignore_for_file: prefer_initializing_formals

/// 本地优先增量同步引擎（实现冻结的 [SyncService]）。
///
/// 关键行为：
/// - 业务写入先落 SQLite（仓储负责），同步是后台能力，网络失败不阻塞编辑；
/// - push 先于 pull（手动/增量）；首次绑定或修复用 `SyncMode.full` 做快照对账；
/// - 同一时刻只允许一个同步在跑，重复调用复用同一个 Future；
/// - 冲突持久化、可选择，绝不静默覆盖；
/// - 自动同步：启动 2s 后、本地改动 debounce 2s、每 5 分钟、网络恢复；
///   失败指数退避（1s→…→5min 上限），401 停止自动重试。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../core/cloud/cloud_services.dart';
import '../../core/cloud/cloud_types.dart';
import '../../core/models/models.dart';
import '../backup_service.dart';
import '../cloud/cloud_credentials.dart';
import '../cloud/http_json.dart';
import '../cloud/planner_api.dart';
import '../planner_database.dart';
import '../sqlite_planner_repository.dart';
import 'account_binding.dart';
import 'local_record_store.dart';
import 'remote_applier.dart';
import 'sync_conflict_store.dart';
import 'sync_outbox_store.dart';
import 'sync_payloads.dart';
import 'sync_state_store.dart';

enum _SyncDirection { upload, download, both }

final class SqliteCloudSyncService implements SyncService {
  SqliteCloudSyncService({
    required SqlitePlannerRepository repository,
    required CloudAccountService account,
    required CloudCredentialsProvider credentials,
    required PlannerApi api,
    WorkspaceLayout? layout,
    String? deviceId,
    DateTime Function()? clock,
    Stream<bool>? connectivity,
    Duration debounce = const Duration(seconds: 2),
    Duration startupDelay = const Duration(seconds: 2),
    Duration periodicInterval = const Duration(minutes: 5),
    Duration retryBase = const Duration(seconds: 1),
    Duration retryMax = const Duration(minutes: 5),
    bool autoStart = true,
    int batchSize = 100,
    int pullLimit = 200,
  }) : _repository = repository,
       _database = repository.database,
       _account = account,
       _credentials = credentials,
       _api = api,
       _clock = clock ?? DateTime.now,
       _connectivity = connectivity,
       _debounce = debounce,
       _startupDelay = startupDelay,
       _periodicInterval = periodicInterval,
       _retryBase = retryBase,
       _retryMax = retryMax,
       _batchSize = batchSize,
       _pullLimit = pullLimit,
       _autoStart = autoStart,
       _deviceId = deviceId ?? repository.deviceId {
    _layout = layout ?? _deriveLayout(_database.path);
    _bindingStore = AccountBindingStore(_resolveBindingPath(_database.path));
    _outbox = SyncOutboxStore(_database);
    _conflicts = SyncConflictStore(_database);
    _state = SyncStateStore(_database);
    _records = LocalRecordStore(_database);
    _applier = RemoteApplier(
      database: _database,
      outbox: _outbox,
      conflicts: _conflicts,
      records: _records,
      deviceId: _deviceId,
      clock: _clock,
    );
    _status = _computeStatus();
    _accountSubscription = _account.observeAccount().listen(_onAccountChanged);
    if (_autoStart && (_state.autoUpload || _state.autoDownload)) {
      _maybeStartAuto();
    }
  }

  final SqlitePlannerRepository _repository;
  final PlannerDatabase _database;
  final CloudAccountService _account;
  final CloudCredentialsProvider _credentials;
  final PlannerApi _api;
  final DateTime Function() _clock;
  final Stream<bool>? _connectivity;
  final Duration _debounce;
  final Duration _startupDelay;
  final Duration _periodicInterval;
  final Duration _retryBase;
  final Duration _retryMax;
  final int _batchSize;
  final int _pullLimit;
  final bool _autoStart;
  final String _deviceId;

  late final WorkspaceLayout _layout;
  late final AccountBindingStore _bindingStore;
  late final SyncOutboxStore _outbox;
  late final SyncConflictStore _conflicts;
  late final SyncStateStore _state;
  late final LocalRecordStore _records;
  late final RemoteApplier _applier;

  final StreamController<SyncStatus> _statusChanges =
      StreamController<SyncStatus>.broadcast();

  late SyncStatus _status;
  StreamSubscription<CloudAccount?>? _accountSubscription;
  StreamSubscription<void>? _localWriteSubscription;
  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _debounceTimer;
  Timer? _startupTimer;
  Timer? _periodicTimer;
  Timer? _retryTimer;

  Future<SyncResult>? _active;
  bool _autoEnabled = false;
  bool _running = false;
  bool _offline = false;
  bool _dirty = false;
  bool _closed = false;
  int _retryAttempt = 0;
  _SyncDirection _retryDirection = _SyncDirection.both;

  // ---------------------------------------------------------------------------
  // SyncService：状态
  // ---------------------------------------------------------------------------

  @override
  SyncStatus get status => _status;

  @override
  Stream<SyncStatus> observeSyncStatus() =>
      Stream<SyncStatus>.multi((controller) {
        controller.add(_status);
        final subscription = _statusChanges.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  // ---------------------------------------------------------------------------
  // SyncService：手动同步
  // ---------------------------------------------------------------------------

  @override
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental}) {
    if (_closed) {
      return Future<SyncResult>.error(StateError('同步服务已关闭'));
    }
    return _startSync(mode, manual: true, direction: _SyncDirection.both);
  }

  @override
  Future<SyncResult> uploadNow() {
    if (_closed) {
      return Future<SyncResult>.error(StateError('同步服务已关闭'));
    }
    return _startSync(
      SyncMode.incremental,
      manual: true,
      direction: _SyncDirection.upload,
    );
  }

  @override
  Future<SyncResult> downloadNow({
    SyncMode mode = SyncMode.incremental,
    bool overwriteLocal = false,
  }) {
    if (_closed) {
      return Future<SyncResult>.error(StateError('同步服务已关闭'));
    }
    return _startSync(
      mode,
      manual: true,
      direction: _SyncDirection.download,
      overwriteLocal: overwriteLocal,
    );
  }

  Future<SyncResult> _startSync(
    SyncMode mode, {
    required bool manual,
    required _SyncDirection direction,
    bool overwriteLocal = false,
  }) {
    if (_closed) {
      return Future<SyncResult>.value(
        _result(SyncOutcome.error, message: '同步服务已关闭'),
      );
    }
    final running = _active;
    if (running != null) return running;
    final future = _runSync(
      mode,
      manual: manual,
      direction: direction,
      overwriteLocal: overwriteLocal,
    );
    _active = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_active, future)) _active = null;
        if (_dirty && !_closed) {
          _dirty = false;
          if (_state.autoUpload) {
            _scheduleSync(_debounce, direction: _SyncDirection.upload);
          }
        }
      }),
    );
    return future;
  }

  Future<SyncResult> _runSync(
    SyncMode mode, {
    required bool manual,
    required _SyncDirection direction,
    bool overwriteLocal = false,
  }) async {
    final account = _account.currentAccount();
    if (account == null) {
      _emit(phase: SyncPhase.signedOut);
      return _result(SyncOutcome.authRequired, message: '请先登录云端账号');
    }
    final binding = _bindingStore.read();
    if (binding == null) {
      _emit(phase: SyncPhase.needsAttention, message: '请先确认数据归属并绑定账号');
      return _result(
        SyncOutcome.bindingRequired,
        message: '本机尚未绑定云端账号，请先在设置中确认数据归属',
      );
    }
    if (!binding.matches(account)) {
      _emit(phase: SyncPhase.needsAttention, message: '本地数据属于其它账号，禁止上传');
      return _result(
        SyncOutcome.bindingRequired,
        message: '本地数据属于其它账号（${binding.email}），不能上传到当前账号',
      );
    }

    final restoredNow = _detectRestore();
    if (mode != SyncMode.full && (restoredNow || _state.needsReconcile)) {
      _emit(phase: SyncPhase.needsAttention, message: '检测到数据库恢复，需要先做全量对账');
      return _result(
        SyncOutcome.error,
        message:
            '检测到数据库恢复：请执行全量对账（SyncMode.full）后再上传，'
            '旧 outbox 已清空，避免把备份数据重复灌回云端。',
      );
    }

    _running = true;
    String? forceBackupPath;
    _emit(
      phase: SyncPhase.syncing,
      message: switch (direction) {
        _SyncDirection.upload => '正在上传…',
        _SyncDirection.download => '正在下载…',
        _SyncDirection.both => '正在同步…',
      },
      clearError: true,
    );
    final stats = _SyncStats();
    try {
      if (manual) _outbox.clearBackoff(_now());
      _outbox.resetStaleSending();
      if (mode == SyncMode.full && direction == _SyncDirection.both) {
        await _runFull(stats);
      } else if (direction == _SyncDirection.download && overwriteLocal) {
        forceBackupPath = await _forceDownload(stats);
      } else {
        if (direction != _SyncDirection.download) {
          await _push(stats);
        }
        if (direction != _SyncDirection.upload) {
          await _pull(
            stats,
            snapshot: mode == SyncMode.full,
            fullReconcile: false,
          );
        }
      }
      final now = _now();
      _state.setLastSyncAt(now);
      if (direction != _SyncDirection.download) {
        _state.setLastUploadAt(now);
      }
      if (direction != _SyncDirection.upload) {
        _state.setLastDownloadAt(now);
      }
      _state.setLastError(null);
      _state.setNeedsReconcile(false);
      _offline = false;
      _retryAttempt = 0;
      _cancelRetry();
      if (_autoStart &&
          (_state.autoUpload || _state.autoDownload) &&
          !_autoEnabled) {
        _maybeStartAuto();
      }
      final openConflicts = _conflicts.countOpen();
      final outcome = openConflicts > 0 || stats.conflicts > 0
          ? SyncOutcome.conflict
          : (stats.pushed == 0 && stats.pulled == 0
                ? SyncOutcome.noChanges
                : SyncOutcome.success);
      _emit(
        phase: openConflicts > 0 ? SyncPhase.needsAttention : SyncPhase.idle,
        lastSyncedAt: now,
        message: switch (outcome) {
          SyncOutcome.conflict => '有 $openConflicts 条冲突需要处理',
          SyncOutcome.noChanges => switch (direction) {
            _SyncDirection.upload => '没有待上传的改动',
            _SyncDirection.download =>
              overwriteLocal
                  ? (forceBackupPath == null
                        ? '已用云端覆盖本机（未创建备份）'
                        : '已用云端覆盖本机（备份：$forceBackupPath）')
                  : '云端没有新数据',
            _SyncDirection.both => '已是最新',
          },
          _ => switch (direction) {
            _SyncDirection.upload => '上传完成',
            _SyncDirection.download =>
              overwriteLocal
                  ? (forceBackupPath == null
                        ? '已用云端覆盖本机（未创建备份）'
                        : '已用云端覆盖本机（备份：$forceBackupPath）')
                  : '已从云端更新',
            _SyncDirection.both => '同步完成',
          },
        },
        clearError: true,
      );
      return _result(
        outcome,
        pushed: stats.pushed,
        pulled: stats.pulled,
        conflicts: stats.conflicts,
        cursor: _state.cursor,
        message: switch (outcome) {
          SyncOutcome.noChanges => switch (direction) {
            _SyncDirection.upload => '没有待上传的改动',
            _SyncDirection.download =>
              overwriteLocal
                  ? (forceBackupPath == null
                        ? '已用云端覆盖本机（未创建备份）'
                        : '已用云端覆盖本机（备份：$forceBackupPath）')
                  : '云端没有新数据',
            _SyncDirection.both => '已是最新',
          },
          _ =>
            direction == _SyncDirection.download && overwriteLocal
                ? (forceBackupPath == null
                      ? '已用云端覆盖本机（未创建备份）'
                      : '已用云端覆盖本机（备份：$forceBackupPath）')
                : null,
        },
      );
    } on CloudException catch (error) {
      _state.setLastError(error.message);
      final outcome = _outcomeOf(error);
      _emit(
        phase: _phaseOf(error),
        message: error.message,
        lastError: error.message,
      );
      if (outcome == SyncOutcome.offline) {
        _offline = true;
        _scheduleRetry(direction);
      } else if (outcome == SyncOutcome.error) {
        _offline = false;
      }
      return _result(
        outcome,
        pushed: stats.pushed,
        pulled: stats.pulled,
        conflicts: stats.conflicts,
        message: error.message,
      );
    } on Object catch (error) {
      final message = '同步失败：$error';
      _state.setLastError(message);
      _emit(phase: SyncPhase.error, message: message, lastError: message);
      return _result(
        SyncOutcome.error,
        pushed: stats.pushed,
        pulled: stats.pulled,
        conflicts: stats.conflicts,
        message: message,
      );
    } finally {
      _running = false;
    }
  }

  // ---------------------------------------------------------------------------
  // push
  // ---------------------------------------------------------------------------

  Future<void> _push(_SyncStats stats) async {
    while (true) {
      if (_closed) return;
      final batch = _outbox.claim(limit: _batchSize, now: _now());
      if (batch.isEmpty) return;
      final ops = <PushOp>[
        for (final entry in batch)
          PushOp(
            opId: entry.opId,
            entityType:
                CloudEntityType.tryParse(entry.entityType) ??
                CloudEntityType.task,
            entityId: entry.entityId,
            opType: entry.operation.wire,
            baseRevision: entry.baseRevision,
            clientRevision: entry.localRevision,
            clientUpdatedAt: entry.updatedAt,
            payload: entry.isDelete ? null : entry.payload,
          ),
      ];

      final PushResponse response;
      try {
        response = await _authorized(
          (token) => _api.push(
            baseUrl: _credentials.baseUrl,
            token: token,
            deviceId: _deviceId,
            ownerId: _account.currentAccount()!.ownerId,
            ops: ops,
          ),
        );
      } on CloudException catch (error) {
        _scheduleBatchFailure(batch, error);
        rethrow;
      }

      final byOpId = <String, OpResult>{
        for (final result in response.results) result.opId: result,
      };
      final now = _now();
      _database.transaction(() {
        for (final entry in batch) {
          final result = byOpId[entry.opId];
          if (result == null) {
            _outbox.markFailed(
              opId: entry.opId,
              error: '服务端未返回该操作的结果',
              nextAttemptAt: now.add(_backoff(entry.attempts + 1)),
            );
            continue;
          }
          if (result.isSuccess) {
            final revision = result.serverRevision;
            if (revision == null) {
              _outbox.markFailed(
                opId: entry.opId,
                error: '服务端确认成功但缺少 serverRevision',
                nextAttemptAt: now.add(_backoff(entry.attempts + 1)),
              );
              continue;
            }
            final type = CloudEntityType.tryParse(entry.entityType);
            if (type != null) {
              _records.setServerRevision(type, entry.entityId, revision);
            }
            _outbox.acknowledge(opId: entry.opId, serverRevision: revision);
            stats.pushed++;
            continue;
          }
          if (result.status == 'conflict') {
            _storePushConflict(entry, result);
            _outbox.markFailed(
              opId: entry.opId,
              error: '与云端版本冲突，等待用户处理',
              nextAttemptAt: now.add(const Duration(days: 365)),
            );
            stats.conflicts++;
            continue;
          }
          final message = result.error?.message ?? '服务端拒绝了该操作';
          _outbox.markRejected(opId: entry.opId, error: message, at: now);
        }
      });
      _database.notifyChanged();
      if (batch.length < _batchSize) return;
    }
  }

  void _storePushConflict(OutboxEntry entry, OpResult result) {
    final type =
        CloudEntityType.tryParse(entry.entityType) ?? CloudEntityType.task;
    final conflict = result.conflict;
    final kind = conflict == null
        ? ConflictKind.unknown
        : ConflictKind.fromWire(conflict.kind);
    _conflicts.upsert(
      SyncConflict(
        id: Ids.newId(),
        entityType: type,
        entityId: entry.entityId,
        baseRevision: entry.baseRevision,
        serverRevision: conflict?.serverRevision ?? result.serverRevision ?? 0,
        kind: kind,
        detectedAt: _now(),
        localPayload: entry.isDelete ? null : entry.payload,
        serverPayload: conflict?.serverPayload,
        serverDeleted: conflict?.serverDeleted ?? false,
      ),
    );
  }

  void _scheduleBatchFailure(List<OutboxEntry> batch, CloudException error) {
    final now = _now();
    for (final entry in batch) {
      _outbox.markFailed(
        opId: entry.opId,
        error: error.message,
        nextAttemptAt: now.add(_backoff(entry.attempts + 1)),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // pull
  // ---------------------------------------------------------------------------

  Future<void> _pull(
    _SyncStats stats, {
    required bool snapshot,
    bool fullReconcile = false,
  }) async {
    var cursor = _state.cursor;
    int? snapshotSeq;
    var pages = 0;
    while (!_closed) {
      final page = await _authorized(
        (token) => _api.pull(
          baseUrl: _credentials.baseUrl,
          token: token,
          deviceId: _deviceId,
          snapshot: snapshot,
          cursor: cursor,
          snapshotSeq: snapshotSeq,
          limit: _pullLimit,
        ),
      );
      if (page.resetRequired) {
        throw const CloudException(
          CloudErrorKind.conflict,
          '服务端要求重新做全量对账（RESET_REQUIRED）',
          cause: ApiErrorInfo('RESET_REQUIRED'),
        );
      }
      snapshotSeq ??= page.snapshotSeq;

      if (page.changes.isEmpty) {
        if (page.nextCursor != null && page.nextCursor != cursor) {
          _database.transaction(() {
            _state.setCursor(page.nextCursor);
          });
        }
        break;
      }

      _database.transaction(() {
        for (final change in page.changes) {
          final outcome = _applier.apply(change, fullReconcile: fullReconcile);
          switch (outcome) {
            case RemoteApplyOutcome.applied:
            case RemoteApplyOutcome.reconciled:
              stats.pulled++;
            case RemoteApplyOutcome.conflict:
              stats.conflicts++;
            case RemoteApplyOutcome.skipped:
              break;
          }
        }
        final next = page.nextCursor;
        if (next != null) _state.setCursor(next);
      });
      _database.notifyChanged();

      cursor = page.nextCursor ?? cursor;
      pages++;
      if (!page.hasMore) break;
      if (page.nextCursor == null) break;
      if (pages > 10000) {
        throw const CloudException(
          CloudErrorKind.protocol,
          '拉取分页异常：超过 10000 页仍未结束',
        );
      }
    }
    if (snapshot && snapshotSeq != null) {
      // 快照阶段结束；用最后一个合法 opaque cursor 继续增量，
      // 重复的变更会被 serverRevision 幂等跳过。
      _state.setCursor(cursor);
    }
  }

  // ---------------------------------------------------------------------------
  // 全量对账（首次绑定 / 升级 / 修复）
  // ---------------------------------------------------------------------------

  /// 用户确认“覆盖本机”后使用：先备份，再抓取完整云端快照，
  /// 在一个事务里清空本机业务表/outbox/冲突并用云端状态重建。
  ///
  /// 语义是“本机完全以云端为准”：仅本机存在、云端没有的记录也会被移除，
  /// 执行后本机数据与云端快照一致。这是破坏性操作；网络抓取失败时不会改动本机。
  Future<String?> _forceDownload(_SyncStats stats) async {
    // 备份是尽力而为：当前 Windows 环境可能既不能 VACUUM INTO，也不能
    // 写 JSON 备份。备份失败不应阻止用户已经二次确认的覆盖更新。
    String? backupPath;
    try {
      final backups = await _backupNow(requireJson: false);
      backupPath = backups.snapshotPath;
    } on Object {
      try {
        final service = BackupService(
          _repository,
          clock: _clock,
          backupDirectory: _layout.backupsDirectory,
        );
        backupPath = await service.exportJson();
      } on Object {
        backupPath = null;
      }
    }
    final changes = <PullChange>[];
    String? cursor;
    int? snapshotSeq;
    var pages = 0;
    while (true) {
      final page = await _authorized(
        (token) => _api.pull(
          baseUrl: _credentials.baseUrl,
          token: token,
          deviceId: _deviceId,
          snapshot: true,
          cursor: cursor,
          snapshotSeq: snapshotSeq,
          limit: 500,
        ),
      );
      if (page.resetRequired) {
        throw const CloudException(
          CloudErrorKind.conflict,
          '服务端要求重新对账，无法执行覆盖更新',
        );
      }
      snapshotSeq ??= page.snapshotSeq;
      changes.addAll(page.changes);
      // 即使本页是最后一页，也要记住它的 nextCursor，覆盖后增量同步才不会
      // 从 0 重新拉一遍全量快照。
      final pageCursor = page.nextCursor;
      if (pageCursor != null) cursor = pageCursor;
      pages++;
      if (!page.hasMore || page.changes.isEmpty) break;
      if (pageCursor == null) {
        throw const CloudException(
          CloudErrorKind.protocol,
          '快照分页缺少游标，已取消覆盖以保护本机数据',
        );
      }
      if (pages > 200) {
        throw const CloudException(
          CloudErrorKind.protocol,
          '快照分页过多，已取消覆盖以保护本机数据',
        );
      }
    }
    // 服务端序号非 0 却返回空快照属于异常；此时绝不能清空本机。
    if (changes.isEmpty && (snapshotSeq ?? 0) > 0) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '云端快照为空但存在服务端版本，已取消覆盖以保护本机数据',
      );
    }

    _database.transaction(() {
      final handle = _database.handle;
      // 本机完全以云端为准：先清空业务数据与全部待上传状态，再用快照重建。
      // 这样“仅本机存在、云端没有”的记录也会被移除，不会留下永远传不上去的
      // outbox（历史实现只清云端已有记录的操作，导致覆盖后仍显示待同步）。
      handle.execute('DELETE FROM planner_tasks');
      handle.execute('DELETE FROM plan_spans');
      handle.execute('DELETE FROM projects');
      handle.execute('DELETE FROM daily_notes');
      _outbox.clearAll();
      handle.execute('DELETE FROM sync_conflicts');
      handle.execute('DELETE FROM change_log');

      const typeOrder = <CloudEntityType>[
        CloudEntityType.project,
        CloudEntityType.span,
        CloudEntityType.task,
        CloudEntityType.note,
      ];
      // 先应用 live 记录，保证任务所属项目已存在；墓碑最后处理。
      for (final type in typeOrder) {
        for (final change in changes) {
          if (change.entityType != type || change.deleted) continue;
          final outcome = _applier.applyForce(change);
          if (outcome == RemoteApplyOutcome.applied ||
              outcome == RemoteApplyOutcome.reconciled) {
            stats.pulled++;
          }
        }
      }
      for (final change in changes) {
        if (!change.deleted) continue;
        final outcome = _applier.applyForce(change);
        if (outcome == RemoteApplyOutcome.applied) stats.pulled++;
      }

      _state.setCursor(cursor);
      _state.setNeedsReconcile(false);
    });
    _database.notifyChanged();
    return backupPath;
  }

  Future<void> _runFull(_SyncStats stats) async {
    await _pull(stats, snapshot: true, fullReconcile: true);
    _reconcileLocalRecords();
    await _push(stats);
    await _pull(stats, snapshot: false);
  }

  /// 本地从未上传的记录（V1 升级数据）逐条认领为 create。
  void _reconcileLocalRecords() {
    final now = _now();
    _database.transaction(() {
      for (final record in _records.unsyncedRecords()) {
        if (_conflicts.findOpenForEntity(record.entityType, record.entityId) !=
            null) {
          continue;
        }
        SyncOutboxStore.record(
          _database.handle,
          entityType: record.entityType.wireName,
          entityId: record.entityId,
          operation: 'create',
          baseRevision: 0,
          localRevision: record.localRevision,
          payload: record.payload,
          deviceId: _deviceId,
          at: now,
          newOpId: Ids.newId(),
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 自动同步
  // ---------------------------------------------------------------------------

  @override
  @override
  Future<void> enableAutoUpload(bool enabled) async {
    if (_closed) throw StateError('同步服务已关闭');
    _state.setAutoUpload(enabled);
    _afterAutoFlagChanged();
    _emit();
  }

  @override
  Future<void> enableAutoDownload(bool enabled) async {
    if (_closed) throw StateError('同步服务已关闭');
    _state.setAutoDownload(enabled);
    _afterAutoFlagChanged();
    _emit();
  }

  @override
  Future<void> enableAutoSync(bool enabled) async {
    if (_closed) throw StateError('同步服务已关闭');
    _state.setAutoUpload(enabled);
    _state.setAutoDownload(enabled);
    _afterAutoFlagChanged();
    _emit();
  }

  void _afterAutoFlagChanged() {
    if (_state.autoUpload || _state.autoDownload) {
      _maybeStartAuto();
    } else {
      _stopAutoTimers();
      _cancelRetry();
    }
  }

  _SyncDirection get _autoDirection {
    if (_state.autoUpload && _state.autoDownload) return _SyncDirection.both;
    if (_state.autoUpload) return _SyncDirection.upload;
    return _SyncDirection.download;
  }

  void _maybeStartAuto() {
    if (_closed) return;
    if (!_state.autoUpload && !_state.autoDownload) return;
    final account = _account.currentAccount();
    final binding = _bindingStore.read();
    if (account == null || binding == null || !binding.matches(account)) return;
    _autoEnabled = true;
    _localWriteSubscription ??= _database.localWrites.listen((_) {
      if (!_autoEnabled || !_state.autoUpload) return;
      if (_running) {
        _dirty = true;
        return;
      }
      if (_outbox.count() == 0) return;
      _scheduleSync(_debounce, direction: _SyncDirection.upload);
    });
    _connectivitySubscription ??= _connectivity?.listen((online) {
      if (!online || !_autoEnabled) return;
      _offline = false;
      _retryAttempt = 0;
      _cancelRetry();
      _scheduleSync(Duration.zero, direction: _autoDirection);
    });
    _periodicTimer ??= Timer.periodic(_periodicInterval, (_) {
      if (!_autoEnabled || _running || _offline) return;
      if (_account.currentAccount() == null) return;
      unawaited(
        _startSync(
          SyncMode.incremental,
          manual: false,
          direction: _autoDirection,
        ),
      );
    });
    _startupTimer ??= Timer(_startupDelay, () {
      _startupTimer = null;
      if (!_autoEnabled || _running) return;
      final direction = _autoDirection;
      if (direction == _SyncDirection.upload && _outbox.count() == 0) return;
      unawaited(
        _startSync(SyncMode.incremental, manual: false, direction: direction),
      );
    });
    _emit();
  }

  void _stopAutoTimers() {
    _autoEnabled = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    unawaited(_localWriteSubscription?.cancel());
    _localWriteSubscription = null;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
    _emit();
  }

  void _scheduleSync(Duration delay, {required _SyncDirection direction}) {
    if (_closed || !_autoEnabled) return;
    if (direction == _SyncDirection.upload && !_state.autoUpload) return;
    if (direction == _SyncDirection.download && !_state.autoDownload) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () {
      _debounceTimer = null;
      if (_closed || _running) {
        if (_running) _dirty = true;
        return;
      }
      unawaited(
        _startSync(SyncMode.incremental, manual: false, direction: direction),
      );
    });
  }

  void _scheduleRetry(_SyncDirection direction) {
    if (!_autoEnabled || _closed) return;
    _cancelRetry();
    _retryDirection = direction;
    _retryAttempt++;
    final delay = _backoff(_retryAttempt);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_closed || _running || !_autoEnabled) return;
      unawaited(
        _startSync(
          SyncMode.incremental,
          manual: false,
          direction: _retryDirection,
        ),
      );
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Duration _backoff(int attempts) {
    final exponent = attempts.clamp(0, 16);
    final baseMillis = _retryBase.inMilliseconds * pow(2, exponent).toInt();
    final capped = min(baseMillis, _retryMax.inMilliseconds);
    // 10% 固定抖动，避免多设备同一秒重连；测试可预测。
    final jitter = (capped * 0.1 * ((attempts % 3) / 3)).round();
    return Duration(milliseconds: capped + jitter);
  }

  // ---------------------------------------------------------------------------
  // 冲突
  // ---------------------------------------------------------------------------

  @override
  Future<List<SyncConflict>> listConflicts() async {
    if (_closed) throw StateError('同步服务已关闭');
    return _conflicts.listOpen();
  }

  @override
  Future<SyncResult> resolveConflict(
    String conflictId,
    ConflictResolution resolution, {
    Map<String, Object?>? mergedPayload,
  }) async {
    if (_closed) throw StateError('同步服务已关闭');
    final conflict = _conflicts.find(conflictId);
    if (conflict == null) {
      throw CloudException(CloudErrorKind.notFound, '冲突不存在或已处理：$conflictId');
    }
    if (resolution == ConflictResolution.manual && mergedPayload == null) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '手动合并必须提供 mergedPayload',
      );
    }
    final account = _account.currentAccount();
    final binding = _bindingStore.read();
    if (account == null || binding == null || !binding.matches(account)) {
      throw const CloudException(
        CloudErrorKind.unauthorized,
        '请先登录并确认数据归属后再处理冲突',
      );
    }
    final now = _now();
    final payload = resolution == ConflictResolution.manual
        ? mergedPayload
        : conflict.localPayload;

    _database.transaction(() {
      if (resolution == ConflictResolution.keepServer) {
        _applyServerVersion(conflict, now);
      } else {
        _applyLocalVersion(conflict, payload, now);
      }
      _conflicts.delete(conflictId);
    });
    _database.notifyChanged();

    final result = await _startSync(
      SyncMode.incremental,
      manual: true,
      direction: _SyncDirection.both,
    );
    if (result.outcome == SyncOutcome.error ||
        result.outcome == SyncOutcome.offline ||
        result.outcome == SyncOutcome.authRequired) {
      // 同步没成功：把冲突放回去，避免用户的选择被静默丢掉。
      _database.transaction(() {
        _conflicts.upsert(conflict);
      });
      _emit();
    }
    return result;
  }

  void _applyServerVersion(SyncConflict conflict, DateTime now) {
    _outbox.removeForEntity(conflict.entityType.wireName, conflict.entityId);
    if (conflict.kind == ConflictKind.noteDateTaken) {
      final date = conflict.serverPayload?['date'];
      if (date is String) {
        final localId = _records.liveNoteIdForDate(date);
        if (localId != null && localId != conflict.entityId) {
          _records.softDelete(
            type: CloudEntityType.note,
            entityId: localId,
            deletedAt: now,
            serverUpdatedAt: now,
            serverRevision: conflict.serverRevision,
          );
        }
      }
    }
    if (conflict.serverDeleted || conflict.serverPayload == null) {
      if (_records.exists(conflict.entityType, conflict.entityId)) {
        _records.softDelete(
          type: conflict.entityType,
          entityId: conflict.entityId,
          deletedAt: now,
          serverUpdatedAt: now,
          serverRevision: conflict.serverRevision,
        );
      }
      return;
    }
    _records.applyRemote(
      type: conflict.entityType,
      entityId: conflict.entityId,
      payload: conflict.serverPayload!,
      serverRevision: conflict.serverRevision,
      serverUpdatedAt: now,
    );
  }

  void _applyLocalVersion(
    SyncConflict conflict,
    Map<String, Object?>? payload,
    DateTime now,
  ) {
    final type = conflict.entityType;
    final entityId = conflict.entityId;
    _outbox.removeForEntity(type.wireName, entityId);

    if (conflict.kind == ConflictKind.noteDateTaken) {
      final date = conflict.serverPayload?['date'];
      final localId = date is String ? _records.liveNoteIdForDate(date) : null;
      if (localId != null && localId != entityId && payload != null) {
        _records.adoptEntityId(
          type: CloudEntityType.note,
          fromId: localId,
          toId: entityId,
          payload: payload,
          serverRevision: conflict.serverRevision,
          updatedAt: now,
        );
        _enqueueLocal(
          type: type,
          entityId: entityId,
          operation: 'update',
          payload: payload,
          baseRevision: conflict.serverRevision,
          localRevision: _localRevision(type, entityId),
          at: now,
        );
        return;
      }
      if (localId == null) {
        if (payload != null) {
          _records.insertCopyWithNewId(
            type: type,
            payload: payload,
            newId: entityId,
            now: now,
          );
          _enqueueLocal(
            type: type,
            entityId: entityId,
            operation: 'create',
            payload: payload,
            baseRevision: 0,
            localRevision: 1,
            at: now,
          );
        }
        return;
      }
    }

    if (conflict.kind == ConflictKind.updateDelete) {
      // 服务端已删：本地内容以新 ID 副本保留（旧 ID 保持墓碑）。
      if (payload == null) return;
      if (_records.exists(type, entityId)) {
        _records.softDelete(
          type: type,
          entityId: entityId,
          deletedAt: now,
          serverUpdatedAt: now,
          serverRevision: conflict.serverRevision,
        );
      }
      final newId = Ids.newId();
      _records.insertCopyWithNewId(
        type: type,
        payload: payload,
        newId: newId,
        now: now,
      );
      _enqueueLocal(
        type: type,
        entityId: newId,
        operation: 'create',
        payload: payload,
        baseRevision: 0,
        localRevision: 1,
        at: now,
      );
      return;
    }

    if (conflict.kind == ConflictKind.deleteUpdate) {
      _records.setServerRevision(type, entityId, conflict.serverRevision);
      _enqueueLocal(
        type: type,
        entityId: entityId,
        operation: 'delete',
        payload: const <String, Object?>{},
        baseRevision: conflict.serverRevision,
        localRevision: _localRevision(type, entityId),
        at: now,
      );
      return;
    }

    if (payload == null) return;
    _validatePayload(type, payload);
    _records.setServerRevision(type, entityId, conflict.serverRevision);
    _enqueueLocal(
      type: type,
      entityId: entityId,
      operation: 'update',
      payload: payload,
      baseRevision: conflict.serverRevision,
      localRevision: _localRevision(type, entityId),
      at: now,
    );
  }

  void _enqueueLocal({
    required CloudEntityType type,
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required int baseRevision,
    required int localRevision,
    required DateTime at,
  }) {
    SyncOutboxStore.record(
      _database.handle,
      entityType: type.wireName,
      entityId: entityId,
      operation: operation,
      baseRevision: baseRevision,
      localRevision: localRevision,
      payload: payload,
      deviceId: _deviceId,
      at: at,
      newOpId: Ids.newId(),
    );
  }

  int _localRevision(CloudEntityType type, String entityId) {
    final entity = _records.readEntity(type, entityId);
    return entity == null ? 1 : (entity as PlannerEntity).revision;
  }

  void _validatePayload(CloudEntityType type, Map<String, Object?> payload) {
    try {
      switch (type) {
        case CloudEntityType.project:
          projectFromSyncPayload(
            id: 'validate',
            payload: payload,
            revision: 1,
            updatedAt: _now(),
          );
        case CloudEntityType.span:
          spanFromSyncPayload(
            id: 'validate',
            payload: payload,
            revision: 1,
            updatedAt: _now(),
          );
        case CloudEntityType.task:
          taskFromSyncPayload(
            id: 'validate',
            payload: payload,
            revision: 1,
            updatedAt: _now(),
          );
        case CloudEntityType.note:
          noteFromSyncPayload(
            id: 'validate',
            payload: payload,
            revision: 1,
            updatedAt: _now(),
          );
      }
    } on PlannerValidationException catch (error) {
      throw CloudException(
        CloudErrorKind.protocol,
        '合并内容不符合数据契约：${error.message}',
        cause: error,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 绑定
  // ---------------------------------------------------------------------------

  @override
  Future<BindingInspection> inspectBinding() async {
    if (_closed) throw StateError('同步服务已关闭');
    final account = _account.currentAccount();
    if (account == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录云端账号');
    }
    final local = _records.liveRecordCount();
    final binding = _bindingStore.read();
    final cloud = await _countCloudRecords();
    final situation = _situationOf(
      account: account,
      binding: binding,
      local: local,
      cloud: cloud,
    );
    final canUpload =
        local > 0 &&
        cloud == 0 &&
        (binding == null || binding.ownerId == account.ownerId);
    final recommended = switch (situation) {
      BindingSituation.freshInstallCloudEmpty => BindingChoice.keepLocalUnbound,
      BindingSituation.freshInstallCloudHasData =>
        BindingChoice.useCloudAndArchiveLocal,
      BindingSituation.localDataCloudEmpty =>
        BindingChoice.uploadLocalToAccount,
      BindingSituation.bothHaveData => BindingChoice.keepLocalUnbound,
      BindingSituation.boundSameAccount => BindingChoice.keepLocalUnbound,
      BindingSituation.boundOtherAccount => BindingChoice.keepLocalUnbound,
    };
    return BindingInspection(
      situation: situation,
      canUpload: canUpload,
      requiresBackup: local > 0,
      recommendedChoice: recommended,
      message: _bindingMessage(situation, local, cloud, binding, account),
      boundOwnerId: binding?.ownerId,
      localLiveRecords: local,
      cloudRecords: cloud,
    );
  }

  @override
  Future<BindingResult> applyBinding(BindingChoice choice) async {
    if (_closed) throw StateError('同步服务已关闭');
    final account = _account.currentAccount();
    if (account == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录云端账号');
    }
    if (choice == BindingChoice.cancel) {
      return const BindingResult(
        changed: false,
        requiresRestart: false,
        message: '已取消绑定',
      );
    }
    final inspection = await inspectBinding();

    switch (choice) {
      case BindingChoice.cancel:
        return const BindingResult(
          changed: false,
          requiresRestart: false,
          message: '已取消绑定',
        );
      case BindingChoice.uploadLocalToAccount:
        if (!inspection.canUpload) {
          throw const CloudException(
            CloudErrorKind.conflict,
            '云端已有数据或本地已绑定其它账号，禁止直接上传本地数据',
          );
        }
        final backups = inspection.requiresBackup ? await _backupNow() : null;
        _writeBinding(
          account,
          WorkspaceKind.local,
          state: BindingState.pending,
          note: '首次上传 ${inspection.localLiveRecords} 条本地记录',
        );
        _state.setCursor(null);
        _state.setNeedsReconcile(false);
        final result = await _startSync(
          SyncMode.full,
          manual: true,
          direction: _SyncDirection.both,
        );
        if (result.isSuccess) {
          _writeBinding(
            account,
            WorkspaceKind.local,
            state: BindingState.bound,
            lastVerifiedAt: _now(),
            note: '上传 ${result.pushed} 条，冲突 ${result.conflicts} 条',
          );
        }
        return BindingResult(
          changed: true,
          requiresRestart: false,
          backupPath: backups?.snapshotPath,
          message: result.isSuccess
              ? '已把本机数据上传到 ${account.label}'
                    '（${inspection.localLiveRecords} 条）'
                    '${backups == null ? '' : '；备份：${backups.snapshotPath}'}'
              : '绑定已保存为待完成，首次同步未完成：${result.message ?? ''}',
        );
      case BindingChoice.useCloudAndArchiveLocal:
        final backups = inspection.requiresBackup ? await _backupNow() : null;
        final archive = inspection.requiresBackup
            ? _archiveCurrentDatabase()
            : null;
        final report = await _createAccountWorkspace(account);
        final extras = <String>[
          if (backups != null) '快照：${backups.snapshotPath}',
          if (backups?.jsonPath != null) 'JSON：${backups!.jsonPath}',
          if (archive != null) '归档库：$archive',
        ].join('；');
        return BindingResult(
          changed: report.changed,
          requiresRestart: true,
          backupPath: backups?.snapshotPath,
          message:
              '已归档本机数据，并为 ${account.label} 新建独立工作区；'
              '重启应用后从云端全量拉取。'
              '${extras.isEmpty ? '' : '($extras)'}',
        );
      case BindingChoice.keepLocalUnbound:
        if (inspection.situation == BindingSituation.boundSameAccount) {
          final result = await _startSync(
            SyncMode.incremental,
            manual: true,
            direction: _SyncDirection.both,
          );
          return BindingResult(
            changed: false,
            requiresRestart: false,
            message: result.isSuccess ? '已是最新' : (result.message ?? '同步未完成'),
          );
        }
        return _createAccountWorkspace(account);
    }
  }

  Future<BindingResult> _createAccountWorkspace(CloudAccount account) async {
    final directory = _layout.accountDirectory(account.ownerId);
    Directory(directory).createSync(recursive: true);
    final dbPath = _layout.accountDatabasePath(account.ownerId);
    final bindingFile = _layout.accountBindingPath(account.ownerId);
    final existedBefore = File(dbPath).existsSync();
    if (!existedBefore) {
      final database = PlannerDatabase.open(path: dbPath);
      // 立即关闭：工作区由下一次启动的 Repository 打开。
      await database.close();
    }
    AccountBindingStore(bindingFile).write(
      WorkspaceBinding(
        ownerId: account.ownerId,
        email: account.email,
        displayName: account.displayName,
        serverUrl: account.serverUrl.toString(),
        boundAt: _now(),
        kind: WorkspaceKind.account,
        state: BindingState.bound,
        lastVerifiedAt: _now(),
      ),
    );
    return BindingResult(
      changed: true,
      requiresRestart: true,
      message: existedBefore
          ? '已切换到 ${account.label} 的独立工作区：$dbPath。重启应用后生效。'
          : '已创建 ${account.label} 的独立工作区：$dbPath，'
                '重启应用后从云端全量拉取（本机原有数据不会被上传）。',
    );
  }

  void _writeBinding(
    CloudAccount account,
    WorkspaceKind kind, {
    BindingState state = BindingState.bound,
    DateTime? lastVerifiedAt,
    String? note,
  }) {
    _bindingStore.write(
      WorkspaceBinding(
        ownerId: account.ownerId,
        email: account.email,
        displayName: account.displayName,
        serverUrl: account.serverUrl.toString(),
        boundAt: _now(),
        kind: kind,
        state: state,
        lastVerifiedAt: lastVerifiedAt,
        note: note,
      ),
    );
  }

  Future<int> _countCloudRecords() async {
    final account = _account.currentAccount();
    if (account == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录云端账号');
    }
    String? cursor;
    int? snapshotSeq;
    // 服务端返回的是变更历史（同一实体可能有多条）；云端“记录数”应按最终
    // 存活实体统计，否则墓碑与历史修订会把数量放大（界面会误报 48 条）。
    final latest = <String, PullChange>{};
    var pages = 0;
    while (true) {
      final page = await _authorized(
        (token) => _api.pull(
          baseUrl: _credentials.baseUrl,
          token: token,
          deviceId: _deviceId,
          snapshot: true,
          cursor: cursor,
          snapshotSeq: snapshotSeq,
          limit: 500,
        ),
      );
      if (page.resetRequired) {
        throw const CloudException(
          CloudErrorKind.conflict,
          '服务端要求重新对账，无法只读统计云端数据',
        );
      }
      snapshotSeq ??= page.snapshotSeq;
      for (final change in page.changes) {
        latest['${change.entityType.wireName}:${change.entityId}'] = change;
      }
      pages++;
      if (!page.hasMore || page.changes.isEmpty) break;
      cursor = page.nextCursor;
      if (cursor == null || pages > 40) break;
    }
    return latest.values.where((change) => !change.deleted).length;
  }

  BindingSituation _situationOf({
    required CloudAccount account,
    required WorkspaceBinding? binding,
    required int local,
    required int cloud,
  }) {
    if (binding != null && binding.ownerId == account.ownerId) {
      return BindingSituation.boundSameAccount;
    }
    if (binding != null && binding.ownerId != account.ownerId) {
      return BindingSituation.boundOtherAccount;
    }
    if (local == 0 && cloud == 0) {
      return BindingSituation.freshInstallCloudEmpty;
    }
    if (local == 0) return BindingSituation.freshInstallCloudHasData;
    if (cloud == 0) return BindingSituation.localDataCloudEmpty;
    return BindingSituation.bothHaveData;
  }

  String _bindingMessage(
    BindingSituation situation,
    int local,
    int? cloud,
    WorkspaceBinding? binding,
    CloudAccount account,
  ) {
    final cloudText = '$cloud';
    return switch (situation) {
      BindingSituation.freshInstallCloudEmpty =>
        '本机没有数据，云端也为空（${account.email}），可以开始使用。',
      BindingSituation.freshInstallCloudHasData =>
        '本机没有数据，云端已有 $cloudText 条记录，将从云端全量拉取。',
      BindingSituation.localDataCloudEmpty =>
        '本机有 $local 条记录，云端为空。确认后可上传到 ${account.email}。',
      BindingSituation.bothHaveData =>
        '本机有 $local 条记录，云端有 $cloudText 条记录。'
            '为防止互相覆盖，不会自动合并；建议为当前账号新建独立工作区。',
      BindingSituation.boundSameAccount => '本机已绑定 ${account.email}，可直接同步。',
      BindingSituation.boundOtherAccount =>
        '本机数据已绑定其它账号（${binding?.email ?? binding?.ownerId ?? '未知'}），'
            '不能上传到 ${account.email}。请新建该账号的独立工作区。',
    };
  }

  Future<_BackupArtifacts> _backupNow({bool requireJson = true}) async {
    Directory(_layout.backupsDirectory).createSync(recursive: true);
    final service = BackupService(
      _repository,
      clock: _clock,
      backupDirectory: _layout.backupsDirectory,
    );
    // 1) SQLite 一致快照（VACUUM INTO + quick_check）。
    //    本机 VACUUM INTO 不可用时退化为文件级复制，保证覆盖前一定留有一份整库备份。
    String snapshot;
    try {
      snapshot = service.snapshotDatabase(
        directory: _layout.backupsDirectory,
        prefix: 'pre-bind',
      );
    } on Object {
      snapshot = _copyDatabaseSnapshot(prefix: 'pre-bind');
    }
    // 2) JSON 备份（可读、可校验、可跨版本恢复）。
    //    覆盖更新允许只有 SQLite 快照，避免因为 JSON 写入失败而放弃备份。
    String? jsonPath;
    try {
      jsonPath = await service.exportJson();
    } on Object {
      if (requireJson) rethrow;
      jsonPath = null;
    }
    return _BackupArtifacts(snapshotPath: snapshot, jsonPath: jsonPath);
  }

  /// 文件级整库备份：checkpoint 后复制 `.db` 与 `-wal`。
  ///
  /// 仅在 `VACUUM INTO` 不可用时使用；调用方负责确认备份目录可用。
  String _copyDatabaseSnapshot({required String prefix}) {
    final source = _database.path;
    if (source == null) {
      throw const CloudException(CloudErrorKind.unknown, '内存数据库无法创建文件备份');
    }
    try {
      _database.checkpoint(truncate: true);
    } on Object {
      // checkpoint 失败时连同 WAL 一起复制，仍是一致的。
    }
    final stamp = _now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final target = p.join(_layout.backupsDirectory, '$prefix-$stamp.db');
    File(source).copySync(target);
    final wal = File('$source-wal');
    if (wal.existsSync()) wal.copySync('$target-wal');
    return target;
  }

  /// `useCloudAndArchiveLocal` 专用：把当前库复制到 `archive/`，
  /// 不删除、不覆盖原库；后续切换到账号工作区由重启完成。
  String? _archiveCurrentDatabase() {
    final source = _database.path;
    if (source == null || !File(source).existsSync()) return null;
    final archiveDir = p.join(_layout.dataDirectory, 'archive');
    Directory(archiveDir).createSync(recursive: true);
    final stamp = _now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final target = p.join(archiveDir, 'local-$stamp.db');
    try {
      _database.checkpoint(truncate: true);
    } on Object {
      // checkpoint 失败不阻塞归档：WAL 文件一并复制即可保持一致性。
    }
    File(source).copySync(target);
    final wal = File('$source-wal');
    if (wal.existsSync()) wal.copySync('$target-wal');
    return target;
  }

  /// 识别 `BackupService.restore` 写入的 `database/full/restore` 标记。
  ///
  /// 恢复后必须停止自动 push、清空不可靠的 outbox/冲突、进入 needs_reconcile，
  /// 由用户显式执行一次 `SyncMode.full` 对账（docs/sync/ACCOUNT_BINDING.md §8.2）。
  bool _detectRestore() {
    final row = _database.handle
        .select(
          'SELECT COALESCE(MAX(seq), 0) AS s FROM change_log '
          "WHERE entity_type = 'database' AND operation = 'restore'",
        )
        .first;
    final maxSeq = row['s'] as int? ?? 0;
    if (maxSeq == 0) return false;
    final handledRows = _database.handle.select(
      'SELECT value FROM settings WHERE key = ?',
      <Object?>[_restoreHandledSeqKey],
    );
    final handled = handledRows.isEmpty
        ? 0
        : int.tryParse(handledRows.first['value'] as String? ?? '') ?? 0;
    if (maxSeq <= handled) return false;
    _database.transaction(() {
      _outbox.clearAll();
      for (final conflict in _conflicts.listOpen()) {
        _conflicts.delete(conflict.id);
      }
      _state.setNeedsReconcile(true);
      _state.setCursor(null);
      _database.handle.execute(
        'INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)',
        <Object?>[_restoreHandledSeqKey, '$maxSeq'],
      );
    });
    return true;
  }

  static const String _restoreHandledSeqKey = 'sync.restore_handled_seq';

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopAutoTimers();
    _cancelRetry();
    _debounceTimer?.cancel();
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    _debounceTimer = null;
    _startupTimer = null;
    _periodicTimer = null;
    await _accountSubscription?.cancel();
    _accountSubscription = null;
    await _statusChanges.close();
  }

  // ---------------------------------------------------------------------------
  // 内部：状态 / 工具
  // ---------------------------------------------------------------------------

  void _onAccountChanged(CloudAccount? account) {
    if (_closed) return;
    if (account != null) {
      if (_autoStart) _maybeStartAuto();
    } else {
      _stopAutoTimers();
      _cancelRetry();
      _offline = false;
    }
    _emit();
  }

  SyncStatus _computeStatus() {
    final account = _account.currentAccount();
    final binding = _bindingStore.read();
    final pending = _outbox.count();
    final conflictCount = _conflicts.countOpen();
    SyncPhase phase;
    String? message;
    if (account == null) {
      phase = SyncPhase.signedOut;
    } else if (binding == null || !binding.matches(account)) {
      phase = SyncPhase.needsAttention;
      message = binding == null ? '请先确认数据归属' : '本地数据属于其它账号';
    } else if (_running) {
      phase = SyncPhase.syncing;
      message = '正在同步…';
    } else if (_state.needsReconcile) {
      phase = SyncPhase.needsAttention;
      message = '需要全量对账（检测到数据库恢复）';
    } else if (_offline) {
      phase = SyncPhase.offline;
      message = _state.lastError;
    } else if (conflictCount > 0) {
      phase = SyncPhase.needsAttention;
      message = '有 $conflictCount 条冲突需要处理';
    } else if (_state.lastError != null) {
      phase = SyncPhase.error;
      message = _state.lastError;
    } else {
      phase = SyncPhase.idle;
    }
    return SyncStatus(
      phase: phase,
      account: account,
      lastSyncedAt: _state.lastSyncAt,
      lastUploadedAt: _state.lastUploadAt,
      lastDownloadedAt: _state.lastDownloadAt,
      pendingOperations: pending,
      conflictCount: conflictCount,
      autoUploadEnabled: _state.autoUpload,
      autoDownloadEnabled: _state.autoDownload,
      lastError: _state.lastError,
      message: message,
    );
  }

  void _emit({
    SyncPhase? phase,
    String? message,
    String? lastError,
    DateTime? lastSyncedAt,
    bool clearError = false,
  }) {
    if (_closed) return;
    if (clearError) _state.setLastError(null);
    final base = _computeStatus();
    var next = base;
    if (phase != null ||
        message != null ||
        lastError != null ||
        lastSyncedAt != null) {
      next = base.copyWith(
        phase: phase,
        message: message,
        lastError: lastError ?? (clearError ? null : base.lastError),
        lastSyncedAt: lastSyncedAt,
      );
    }
    _status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }

  SyncResult _result(
    SyncOutcome outcome, {
    int pushed = 0,
    int pulled = 0,
    int conflicts = 0,
    String? message,
    String? cursor,
  }) => SyncResult(
    outcome: outcome,
    finishedAt: _now(),
    pushed: pushed,
    pulled: pulled,
    conflicts: conflicts,
    cursor: cursor ?? _state.cursor,
    message: message,
  );

  SyncOutcome _outcomeOf(CloudException error) => switch (error.kind) {
    CloudErrorKind.unauthorized => SyncOutcome.authRequired,
    CloudErrorKind.network ||
    CloudErrorKind.timeout ||
    CloudErrorKind.rateLimited => SyncOutcome.offline,
    _ => SyncOutcome.error,
  };

  SyncPhase _phaseOf(CloudException error) => switch (error.kind) {
    CloudErrorKind.unauthorized => SyncPhase.signedOut,
    CloudErrorKind.network ||
    CloudErrorKind.timeout ||
    CloudErrorKind.rateLimited => SyncPhase.offline,
    CloudErrorKind.protocol => SyncPhase.error,
    _ => SyncPhase.error,
  };

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    final token = await _credentials.requireToken();
    try {
      return await action(token);
    } on CloudException catch (error) {
      if (error.kind != CloudErrorKind.unauthorized) rethrow;
      final refreshed = await _credentials.refreshToken();
      return action(refreshed);
    }
  }

  DateTime _now() => _clock().toUtc();

  String _resolveBindingPath(String? databasePath) {
    if (databasePath == null) {
      return p.join(
        Directory.systemTemp.path,
        'jihuatai-memory-binding-${identityHashCode(this)}.json',
      );
    }
    final directory = p.dirname(databasePath);
    final parent = p.dirname(directory);
    if (p.basename(parent) == 'accounts') {
      return p.join(directory, 'binding.json');
    }
    return '$databasePath.binding.json';
  }

  static WorkspaceLayout _deriveLayout(String? databasePath) {
    if (databasePath == null) {
      return WorkspaceLayout(Directory.systemTemp.path);
    }
    final directory = p.dirname(databasePath);
    final parent = p.dirname(directory);
    if (p.basename(parent) == 'accounts') {
      return WorkspaceLayout(p.dirname(parent));
    }
    return WorkspaceLayout(directory);
  }
}

final class _BackupArtifacts {
  const _BackupArtifacts({required this.snapshotPath, required this.jsonPath});

  final String snapshotPath;
  final String? jsonPath;
}

final class _SyncStats {
  int pushed = 0;
  int pulled = 0;
  int conflicts = 0;
}
