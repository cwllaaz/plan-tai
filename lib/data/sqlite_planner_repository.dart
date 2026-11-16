import 'dart:async';

import 'package:sqlite3/sqlite3.dart';

import '../core/cloud/cloud_types.dart';
import '../core/contracts/planner_repository.dart';
import '../core/models/models.dart';
import 'data_exception.dart';
import 'entity_codec.dart';
import 'planner_database.dart';
import 'sql_schema.dart';
import 'sync/device_identity.dart';
import 'sync/sync_outbox_store.dart';
import 'sync/sync_payloads.dart';

/// 基于 SQLite 的正式本地仓储（Windows 桌面端唯一数据源）。
///
/// 语义与 `InMemoryPlannerRepository` 完全一致（软删除、乐观并发、级联、
/// 排序、错误类型），区别只在于数据真正落盘：
///
/// ```dart
/// final repository = SqlitePlannerRepository.open(); // %APPDATA%\计划台\data\app.db
/// // 或指定路径（测试、便携模式）
/// final sandbox = SqlitePlannerRepository.open(databasePath: r'C:\tmp\app.db');
/// ```
///
/// 每个写操作都是一个 `BEGIN IMMEDIATE ... COMMIT` 事务：级联删除、阶段解绑、
/// 变更日志要么一起写入，要么一行都不写（磁盘失败也不会留半条数据）。
final class SqlitePlannerRepository implements PlannerRepository {
  SqlitePlannerRepository(
    this.database, {
    DateTime Function()? clock,
    String Function()? idGenerator,
    String? deviceId,
  }) : _clock = clock ?? DateTime.now,
       _newId = idGenerator ?? Ids.newId,
       _injectedDeviceId = deviceId;

  /// 打开（必要时创建）默认位置或指定位置的数据库，并返回仓储。
  static SqlitePlannerRepository open({
    String? databasePath,
    DateTime Function()? clock,
    String Function()? idGenerator,
    String? deviceId,
    int busyTimeoutMs = 5000,
  }) => SqlitePlannerRepository(
    PlannerDatabase.open(path: databasePath, busyTimeoutMs: busyTimeoutMs),
    clock: clock,
    idGenerator: idGenerator,
    deviceId: deviceId,
  );

  /// 底层数据库，供备份服务与测试使用。
  final PlannerDatabase database;

  final DateTime Function() _clock;
  final String Function() _newId;
  final String? _injectedDeviceId;

  /// 本机设备 ID；首次写入时从 `device.json` 读取或生成。
  String? _deviceId;

  /// 待同步队列（与业务写入同事务写入）。
  late final SyncOutboxStore outbox = SyncOutboxStore(database);

  String get deviceId =>
      _deviceId ??=
      _injectedDeviceId ??
      DeviceIdentityStore.forDatabase(database.path).deviceId;

  final List<StreamController<Object?>> _streams =
      <StreamController<Object?>>[];
  bool _closed = false;

  // ---------------------------------------------------------------------------
  // 读：项目
  // ---------------------------------------------------------------------------

  @override
  Stream<List<Project>> watchProjects({bool includeArchived = false}) =>
      _watch(() => _selectProjects(includeArchived: includeArchived));

  @override
  Future<Project?> findProject(String id) async => _findProject(id);

  // ---------------------------------------------------------------------------
  // 读：任务
  // ---------------------------------------------------------------------------

  @override
  Stream<List<PlannerTask>> watchTasksInRange(LocalDateRange range) =>
      _watch(() => _selectTasksInRange(range));

  @override
  Stream<List<PlannerTask>> watchUnscheduledTasks() =>
      _watch(_selectUnscheduledTasks);

  @override
  Stream<List<PlannerTask>> watchTasksForProject(String projectId) =>
      _watch(() => _selectTasksForProject(projectId));

  @override
  Stream<List<PlannerTask>> watchAllTasks() => _watch(_selectAllTasks);

  @override
  Stream<PlannerTask?> watchTask(String id) => _watch(() => _findTask(id));

  @override
  Future<PlannerTask?> findTask(String id) async => _findTask(id);

  @override
  Future<List<PlannerTask>> tasksInRange(LocalDateRange range) async =>
      _selectTasksInRange(range);

  // ---------------------------------------------------------------------------
  // 读：跨天阶段
  // ---------------------------------------------------------------------------

  @override
  Stream<List<PlanSpan>> watchSpansInRange(LocalDateRange range) =>
      _watch(() => _selectSpansInRange(range));

  @override
  Stream<List<PlanSpan>> watchSpansForProject(String projectId) =>
      _watch(() => _selectSpansForProject(projectId));

  @override
  Stream<PlanSpan?> watchSpan(String id) => _watch(() => _findSpan(id));

  @override
  Future<PlanSpan?> findSpan(String id) async => _findSpan(id);

  // ---------------------------------------------------------------------------
  // 读：每日备注
  // ---------------------------------------------------------------------------

  @override
  Stream<DailyNote?> watchDailyNote(LocalDate date) =>
      _watch(() => _findLiveNote(date));

  @override
  Future<DailyNote?> findDailyNote(LocalDate date) async => _findLiveNote(date);

  // ---------------------------------------------------------------------------
  // 写：项目
  // ---------------------------------------------------------------------------

  @override
  Future<Project> createProject(ProjectDraft draft) => _write(() {
    final now = _now();
    final project = Project(
      id: _newId(),
      createdAt: now,
      updatedAt: now,
      revision: 1,
      name: draft.name,
      description: draft.description,
      color: draft.color ?? ProjectColor.suggestFor(_countLiveProjects()),
      status: draft.status,
      sortOrder: draft.sortOrder,
    );
    database.handle.execute(insertProjectSql, projectInsertParams(project));
    _recordChange(
      type: CloudEntityType.project,
      entityId: project.id,
      operation: OutboxOperation.create,
      baseRevision: 0,
      revision: project.revision,
      payload: projectSyncPayload(project),
      at: now,
    );
    return project;
  });

  @override
  Future<Project> updateProject(Project project) => _write(() {
    final stored = _requireProject(project.id);
    final baseRevision = _serverRevision('projects', project.id);
    _guardRevision(project.revision, stored.revision, '项目');
    final now = _now();
    final next = project.copyWith(
      createdAt: stored.createdAt,
      updatedAt: now,
      revision: stored.revision + 1,
    );
    database.handle.execute(updateProjectSql, projectUpdateParams(next));
    _recordChange(
      type: CloudEntityType.project,
      entityId: next.id,
      operation: baseRevision == 0
          ? OutboxOperation.create
          : OutboxOperation.update,
      baseRevision: baseRevision,
      revision: next.revision,
      payload: projectSyncPayload(next),
      at: now,
    );
    return next;
  });

  @override
  Future<void> deleteProject(String id) => _write<void>(() {
    final stored = _requireProject(id);
    final baseRevision = _serverRevision('projects', id);
    final now = _now();
    final stamp = encodeInstant(now);
    final nextRevision = stored.revision + 1;

    database.handle.execute(
      'UPDATE projects SET deleted_at = ?, updated_at = ?, revision = ? WHERE id = ?',
      <Object?>[stamp, stamp, nextRevision, id],
    );
    _recordChange(
      type: CloudEntityType.project,
      entityId: id,
      operation: OutboxOperation.delete,
      baseRevision: baseRevision,
      revision: nextRevision,
      payload: const <String, Object?>{},
      at: now,
    );

    final spanRows = database.handle.select(
      'SELECT id, revision, server_revision FROM plan_spans '
      'WHERE project_id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    for (final row in spanRows) {
      final spanId = row['id'] as String;
      final revision = (row['revision'] as int) + 1;
      database.handle.execute(
        'UPDATE plan_spans SET deleted_at = ?, updated_at = ?, revision = ? WHERE id = ?',
        <Object?>[stamp, stamp, revision, spanId],
      );
      _recordChange(
        type: CloudEntityType.span,
        entityId: spanId,
        operation: OutboxOperation.delete,
        baseRevision: row['server_revision'] as int,
        revision: revision,
        payload: const <String, Object?>{},
        at: now,
      );
    }

    final taskRows = database.handle.select(
      'SELECT id, revision, server_revision FROM planner_tasks '
      'WHERE project_id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    for (final row in taskRows) {
      final taskId = row['id'] as String;
      final revision = (row['revision'] as int) + 1;
      database.handle.execute(
        'UPDATE planner_tasks SET deleted_at = ?, updated_at = ?, revision = ? WHERE id = ?',
        <Object?>[stamp, stamp, revision, taskId],
      );
      _recordChange(
        type: CloudEntityType.task,
        entityId: taskId,
        operation: OutboxOperation.delete,
        baseRevision: row['server_revision'] as int,
        revision: revision,
        payload: const <String, Object?>{},
        at: now,
      );
    }
  });

  // ---------------------------------------------------------------------------
  // 写：任务
  // ---------------------------------------------------------------------------

  @override
  Future<PlannerTask> createTask(PlannerTaskDraft draft) => _write(() {
    _validateTaskRelations(projectId: draft.projectId, spanId: draft.spanId);
    final now = _now();
    final task = PlannerTask(
      id: _newId(),
      createdAt: now,
      updatedAt: now,
      revision: 1,
      projectId: draft.projectId,
      spanId: draft.spanId,
      title: draft.title,
      notes: draft.notes,
      scheduledDate: draft.scheduledDate,
      timeSlot: draft.timeSlot,
      priority: draft.priority,
      status: draft.status,
      completedAt: draft.status == TaskStatus.done ? now : null,
      sortOrder: draft.sortOrder,
    );
    database.handle.execute(insertTaskSql, taskInsertParams(task));
    _recordChange(
      type: CloudEntityType.task,
      entityId: task.id,
      operation: OutboxOperation.create,
      baseRevision: 0,
      revision: task.revision,
      payload: taskSyncPayload(task),
      at: now,
    );
    return task;
  });

  @override
  Future<PlannerTask> updateTask(PlannerTask task) => _write(() {
    final stored = _requireTask(task.id);
    final baseRevision = _serverRevision('planner_tasks', task.id);
    _guardRevision(task.revision, stored.revision, '任务');
    _validateTaskRelations(projectId: task.projectId, spanId: task.spanId);
    final now = _now();

    final DateTime? completedAt;
    if (task.status == TaskStatus.done) {
      completedAt = stored.status == TaskStatus.done
          ? (stored.completedAt ?? now)
          : now;
    } else {
      completedAt = null;
    }

    final next = task.copyWith(
      createdAt: stored.createdAt,
      updatedAt: now,
      revision: stored.revision + 1,
      completedAt: completedAt,
    );
    database.handle.execute(updateTaskSql, taskUpdateParams(next));
    _recordChange(
      type: CloudEntityType.task,
      entityId: next.id,
      operation: baseRevision == 0
          ? OutboxOperation.create
          : OutboxOperation.update,
      baseRevision: baseRevision,
      revision: next.revision,
      payload: taskSyncPayload(next),
      at: now,
    );
    return next;
  });

  @override
  Future<void> deleteTask(String id) => _write<void>(() {
    final stored = _requireTask(id);
    final baseRevision = _serverRevision('planner_tasks', id);
    final now = _now();
    final stamp = encodeInstant(now);
    final revision = stored.revision + 1;
    database.handle.execute(
      'UPDATE planner_tasks SET deleted_at = ?, updated_at = ?, revision = ? WHERE id = ?',
      <Object?>[stamp, stamp, revision, id],
    );
    _recordChange(
      type: CloudEntityType.task,
      entityId: id,
      operation: OutboxOperation.delete,
      baseRevision: baseRevision,
      revision: revision,
      payload: const <String, Object?>{},
      at: now,
    );
  });

  // ---------------------------------------------------------------------------
  // 写：跨天阶段
  // ---------------------------------------------------------------------------

  @override
  Future<PlanSpan> createSpan(PlanSpanDraft draft) => _write(() {
    _requireProject(draft.projectId);
    final now = _now();
    final span = PlanSpan(
      id: _newId(),
      createdAt: now,
      updatedAt: now,
      revision: 1,
      projectId: draft.projectId,
      title: draft.title,
      startDate: draft.startDate,
      endDate: draft.endDate,
      status: draft.status,
      description: draft.description,
      color: draft.color,
      sortOrder: draft.sortOrder,
    );
    database.handle.execute(insertSpanSql, spanInsertParams(span));
    _recordChange(
      type: CloudEntityType.span,
      entityId: span.id,
      operation: OutboxOperation.create,
      baseRevision: 0,
      revision: span.revision,
      payload: spanSyncPayload(span),
      at: now,
    );
    return span;
  });

  @override
  Future<PlanSpan> updateSpan(PlanSpan span) => _write(() {
    final stored = _requireSpan(span.id);
    final baseRevision = _serverRevision('plan_spans', span.id);
    _guardRevision(span.revision, stored.revision, '阶段');
    _requireProject(span.projectId);
    final now = _now();
    final next = span.copyWith(
      createdAt: stored.createdAt,
      updatedAt: now,
      revision: stored.revision + 1,
    );
    database.handle.execute(updateSpanSql, spanUpdateParams(next));
    _recordChange(
      type: CloudEntityType.span,
      entityId: next.id,
      operation: baseRevision == 0
          ? OutboxOperation.create
          : OutboxOperation.update,
      baseRevision: baseRevision,
      revision: next.revision,
      payload: spanSyncPayload(next),
      at: now,
    );
    return next;
  });

  @override
  Future<void> deleteSpan(String id) => _write<void>(() {
    final stored = _requireSpan(id);
    final baseRevision = _serverRevision('plan_spans', id);
    final now = _now();
    final stamp = encodeInstant(now);
    final revision = stored.revision + 1;

    database.handle.execute(
      'UPDATE plan_spans SET deleted_at = ?, updated_at = ?, revision = ? WHERE id = ?',
      <Object?>[stamp, stamp, revision, id],
    );
    _recordChange(
      type: CloudEntityType.span,
      entityId: id,
      operation: OutboxOperation.delete,
      baseRevision: baseRevision,
      revision: revision,
      payload: const <String, Object?>{},
      at: now,
    );

    final taskRows = database.handle.select(
      'SELECT id, revision, server_revision FROM planner_tasks '
      'WHERE span_id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    for (final row in taskRows) {
      final taskId = row['id'] as String;
      final nextRevision = (row['revision'] as int) + 1;
      database.handle.execute(
        'UPDATE planner_tasks SET span_id = NULL, updated_at = ?, revision = ? WHERE id = ?',
        <Object?>[stamp, nextRevision, taskId],
      );
      final task = _readTaskRow(taskId);
      if (task == null) continue;
      _recordChange(
        type: CloudEntityType.task,
        entityId: taskId,
        operation: OutboxOperation.update,
        baseRevision: row['server_revision'] as int,
        revision: nextRevision,
        payload: taskSyncPayload(task),
        at: now,
      );
    }
  });

  // ---------------------------------------------------------------------------
  // 写：每日备注
  // ---------------------------------------------------------------------------

  @override
  Future<DailyNote> saveDailyNote(
    LocalDate date, {
    String body = '',
    List<String> focusItems = const <String>[],
  }) => _write(() {
    final existing = _findLiveNote(date);
    final now = _now();
    final DailyNote next;
    if (existing == null) {
      next = DailyNote(
        id: _newId(),
        createdAt: now,
        updatedAt: now,
        revision: 1,
        date: date,
        body: body,
        focusItems: focusItems,
      );
      database.handle.execute(insertNoteSql, noteInsertParams(next));
      _recordChange(
        type: CloudEntityType.note,
        entityId: next.id,
        operation: OutboxOperation.create,
        baseRevision: 0,
        revision: next.revision,
        payload: noteSyncPayload(next),
        at: now,
      );
    } else {
      final baseRevision = _serverRevision('daily_notes', existing.id);
      next = existing.copyWith(
        body: body,
        focusItems: focusItems,
        updatedAt: now,
        revision: existing.revision + 1,
      );
      database.handle.execute(updateNoteSql, noteUpdateParams(next));
      _recordChange(
        type: CloudEntityType.note,
        entityId: next.id,
        operation: baseRevision == 0
            ? OutboxOperation.create
            : OutboxOperation.update,
        baseRevision: baseRevision,
        revision: next.revision,
        payload: noteSyncPayload(next),
        at: now,
      );
    }
    return next;
  });

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final controller in _streams) {
      if (!controller.isClosed) await controller.close();
    }
    _streams.clear();
    await database.close();
  }

  // ---------------------------------------------------------------------------
  // 内部：查询
  // ---------------------------------------------------------------------------

  List<Project> _selectProjects({required bool includeArchived}) {
    final where = includeArchived
        ? 'deleted_at IS NULL'
        : "deleted_at IS NULL AND status <> 'archived'";
    final rows = database.handle.select(
      'SELECT $projectColumns FROM projects WHERE $where $projectOrderClause',
    );
    return List<Project>.unmodifiable(rows.map(projectFromRow));
  }

  Project? _findProject(String id) {
    final rows = database.handle.select(
      'SELECT $projectColumns FROM projects WHERE id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    return rows.isEmpty ? null : projectFromRow(rows.first);
  }

  List<PlannerTask> _selectTasksInRange(LocalDateRange range) {
    final rows = database.handle.select(
      'SELECT $taskColumns FROM planner_tasks '
      'WHERE deleted_at IS NULL AND scheduled_date BETWEEN ? AND ? '
      '$taskOrderClause',
      <Object?>[range.start.iso, range.end.iso],
    );
    return List<PlannerTask>.unmodifiable(rows.map(plannerTaskFromRow));
  }

  List<PlannerTask> _selectUnscheduledTasks() {
    final rows = database.handle.select(
      'SELECT $taskColumns FROM planner_tasks '
      'WHERE deleted_at IS NULL AND scheduled_date IS NULL $taskOrderClause',
    );
    return List<PlannerTask>.unmodifiable(rows.map(plannerTaskFromRow));
  }

  List<PlannerTask> _selectTasksForProject(String projectId) {
    final rows = database.handle.select(
      'SELECT $taskColumns FROM planner_tasks '
      'WHERE deleted_at IS NULL AND project_id = ? $taskOrderClause',
      <Object?>[projectId],
    );
    return List<PlannerTask>.unmodifiable(rows.map(plannerTaskFromRow));
  }

  List<PlannerTask> _selectAllTasks() {
    final rows = database.handle.select(
      'SELECT $taskColumns FROM planner_tasks '
      'WHERE deleted_at IS NULL $taskOrderClause',
    );
    return List<PlannerTask>.unmodifiable(rows.map(plannerTaskFromRow));
  }

  PlannerTask? _findTask(String id) {
    final rows = database.handle.select(
      'SELECT $taskColumns FROM planner_tasks WHERE id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    return rows.isEmpty ? null : plannerTaskFromRow(rows.first);
  }

  List<PlanSpan> _selectSpansInRange(LocalDateRange range) {
    final rows = database.handle.select(
      'SELECT $spanColumns FROM plan_spans '
      'WHERE deleted_at IS NULL AND start_date <= ? AND end_date >= ? '
      '$spanOrderClause',
      <Object?>[range.end.iso, range.start.iso],
    );
    return List<PlanSpan>.unmodifiable(rows.map(planSpanFromRow));
  }

  List<PlanSpan> _selectSpansForProject(String projectId) {
    final rows = database.handle.select(
      'SELECT $spanColumns FROM plan_spans '
      'WHERE deleted_at IS NULL AND project_id = ? $spanOrderClause',
      <Object?>[projectId],
    );
    return List<PlanSpan>.unmodifiable(rows.map(planSpanFromRow));
  }

  PlanSpan? _findSpan(String id) {
    final rows = database.handle.select(
      'SELECT $spanColumns FROM plan_spans WHERE id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    return rows.isEmpty ? null : planSpanFromRow(rows.first);
  }

  DailyNote? _findLiveNote(LocalDate date) {
    final rows = database.handle.select(
      'SELECT $noteColumns FROM daily_notes '
      'WHERE date = ? AND deleted_at IS NULL',
      <Object?>[date.iso],
    );
    return rows.isEmpty ? null : dailyNoteFromRow(rows.first);
  }

  int _countLiveProjects() {
    final row = database.handle
        .select('SELECT COUNT(*) AS c FROM projects WHERE deleted_at IS NULL')
        .first;
    final value = row['c'];
    return value is int ? value : 0;
  }

  // ---------------------------------------------------------------------------
  // 内部：写入与校验
  // ---------------------------------------------------------------------------

  /// 统一写入口：开事务 → 执行 → 提交 → 广播变化。
  ///
  /// 磁盘错误（[SqliteException]）在这里转成可展示的 [LocalDatabaseException]，
  /// 事务已经整体回滚，不会留下半条数据。
  Future<T> _write<T>(T Function() body) async {
    _ensureOpen();
    final T result;
    try {
      result = database.transaction(body);
    } on SqliteException catch (error) {
      throw LocalDatabaseException(_writeFailureMessage(error), cause: error);
    }
    database.notifyLocalWrite();
    return result;
  }

  static String _writeFailureMessage(SqliteException error) =>
      switch (error.resultCode) {
        5 || 6 => '本地数据库正被占用（可能有另一个窗口在写），请稍后重试。',
        8 => '本地数据库文件是只读的，无法保存。请检查文件权限。',
        10 => '本地数据库读写失败，请检查磁盘是否正常。',
        13 => '磁盘空间不足，保存失败。请清理磁盘后重试。',
        19 => '数据不满足本地数据库约束，本次保存已取消：${error.message}',
        _ => '本地数据库写入失败：${error.message}',
      };

  DateTime _now() => _clock().toUtc();

  void _ensureOpen() {
    if (_closed) {
      throw StateError('SqlitePlannerRepository 已关闭，不能再读写');
    }
  }

  Project _requireProject(String id) {
    final project = _findProject(id);
    if (project == null) {
      throw PlannerNotFoundException('项目不存在或已删除：$id');
    }
    return project;
  }

  PlannerTask _requireTask(String id) {
    final task = _findTask(id);
    if (task == null) {
      throw PlannerNotFoundException('任务不存在或已删除：$id');
    }
    return task;
  }

  PlanSpan _requireSpan(String id) {
    final span = _findSpan(id);
    if (span == null) {
      throw PlannerNotFoundException('阶段不存在或已删除：$id');
    }
    return span;
  }

  void _guardRevision(int incoming, int actual, String label) {
    if (incoming != actual) {
      throw PlannerConflictException(
        '$label已被其他操作修改，请刷新后重试',
        expected: incoming,
        actual: actual,
      );
    }
  }

  void _validateTaskRelations({String? projectId, String? spanId}) {
    if (projectId != null) _requireProject(projectId);
    if (spanId != null) {
      final span = _requireSpan(spanId);
      if (projectId == null || span.projectId != projectId) {
        throw const PlannerValidationException('关联阶段必须属于任务所在的项目');
      }
    }
  }

  /// 业务写入之后：同事务记录变更日志 + 待上传操作。
  ///
  /// 任何一步失败都会让外层事务整体回滚——宁可这次保存失败让用户重试，
  /// 也不能留下"数据已写入、队列没记上、以后永远不同步"的隐性漏数据。
  void _recordChange({
    required CloudEntityType type,
    required String entityId,
    required OutboxOperation operation,
    required int baseRevision,
    required int revision,
    required Map<String, Object?> payload,
    required DateTime at,
  }) {
    final handle = database.handle;
    handle.execute(
      'INSERT INTO change_log(entity_type, entity_id, operation, revision, changed_at) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[
        type.wireName,
        entityId,
        operation.wire,
        revision,
        encodeInstant(at),
      ],
    );
    SyncOutboxStore.record(
      handle,
      entityType: type.wireName,
      entityId: entityId,
      operation: operation.wire,
      baseRevision: baseRevision,
      localRevision: revision,
      payload: payload,
      deviceId: deviceId,
      at: at,
      newOpId: Ids.newId(),
    );
  }

  /// 读取某张业务表里记录的服务端版本；不存在时按 0 处理。
  int _serverRevision(String table, String id) {
    final rows = database.handle.select(
      'SELECT server_revision FROM $table WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? 0 : rows.first['server_revision'] as int;
  }

  PlannerTask? _readTaskRow(String id) {
    final rows = database.handle.select(
      'SELECT $taskColumns FROM planner_tasks WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : plannerTaskFromRow(rows.first);
  }

  // ---------------------------------------------------------------------------
  // 内部：流
  // ---------------------------------------------------------------------------

  /// 把读取函数包装成"先推当前值，之后每次写入再推"的流。
  ///
  /// 变化信号来自 [PlannerDatabase.changes]：仓储、备份恢复、将来的同步层
  /// 写完后都会触发它，因此界面不会出现"改了数据但列表没变"。
  Stream<T> _watch<T>(T Function() read) {
    late final StreamController<T> controller;
    StreamSubscription<void>? subscription;

    controller = StreamController<T>(
      onListen: () {
        controller.add(read());
        subscription = database.changes.listen((_) {
          if (!controller.isClosed) controller.add(read());
        });
      },
      onCancel: () {
        final pending = subscription;
        subscription = null;
        if (pending != null) unawaited(pending.cancel());
      },
    );

    if (_closed) {
      unawaited(controller.close());
    } else {
      _streams.add(controller);
    }
    return controller.stream;
  }
}
