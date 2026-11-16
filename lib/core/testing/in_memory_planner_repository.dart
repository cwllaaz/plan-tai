import 'dart:async';

import '../contracts/planner_repository.dart';
import '../models/models.dart';

/// 取当前时刻的注入点，测试里可固定时间。
typedef Clock = DateTime Function();

/// 生成实体 ID 的注入点，测试里可产生可读 ID。
typedef IdGenerator = String Function();

/// 纯内存仓储：**只用于 UI 开发与测试**，不写磁盘、不参与正式用户数据。
///
/// 它完整实现 [PlannerRepository] 的语义（流、范围查询、软删除、级联、
/// 乐观并发、校验），让 月历模块/B 在没有数据库的情况下就能把界面跑通。
/// 正式数据由 数据层 的 SQLite 实现提供，两者可互换（见 docs/MODULE_API.md）。
///
/// 使用时显式构造，例如：
/// ```dart
/// final repo = InMemoryPlannerRepository();
/// await seedDemoData(repo); // lib/core/testing/demo_data.dart
/// ```
final class InMemoryPlannerRepository implements PlannerRepository {
  InMemoryPlannerRepository({Clock? clock, IdGenerator? idGenerator})
    : _clock = clock ?? DateTime.now,
      _newId = idGenerator ?? Ids.newId;

  final Clock _clock;
  final IdGenerator _newId;

  final Map<String, Project> _projects = <String, Project>{};
  final Map<String, PlanSpan> _spans = <String, PlanSpan>{};
  final Map<String, PlannerTask> _tasks = <String, PlannerTask>{};
  final Map<String, DailyNote> _notesByDate = <String, DailyNote>{};

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<StreamController<Object?>> _streams =
      <StreamController<Object?>>[];
  bool _closed = false;

  // ---------------------------------------------------------------------------
  // 读：项目
  // ---------------------------------------------------------------------------

  @override
  Stream<List<Project>> watchProjects({bool includeArchived = false}) =>
      _watch(() => _sortedProjects(includeArchived: includeArchived));

  @override
  Future<Project?> findProject(String id) async {
    final project = _projects[id];
    return project == null || project.isDeleted ? null : project;
  }

  // ---------------------------------------------------------------------------
  // 读：任务
  // ---------------------------------------------------------------------------

  @override
  Stream<List<PlannerTask>> watchTasksInRange(LocalDateRange range) => _watch(
    () => _sortedTasks(
      _aliveTasks.where((task) {
        final day = task.scheduledDate;
        return day != null && range.contains(day);
      }),
    ),
  );

  @override
  Stream<List<PlannerTask>> watchUnscheduledTasks() => _watch(
    () => _sortedTasks(_aliveTasks.where((task) => task.isUnscheduled)),
  );

  @override
  Stream<List<PlannerTask>> watchTasksForProject(String projectId) => _watch(
    () =>
        _sortedTasks(_aliveTasks.where((task) => task.projectId == projectId)),
  );

  @override
  Stream<List<PlannerTask>> watchAllTasks() =>
      _watch(() => _sortedTasks(_aliveTasks));

  @override
  Stream<PlannerTask?> watchTask(String id) => _watch(() {
    final task = _tasks[id];
    return task == null || task.isDeleted ? null : task;
  });

  @override
  Future<PlannerTask?> findTask(String id) async {
    final task = _tasks[id];
    return task == null || task.isDeleted ? null : task;
  }

  @override
  Future<List<PlannerTask>> tasksInRange(LocalDateRange range) async =>
      _sortedTasks(
        _aliveTasks.where((task) {
          final day = task.scheduledDate;
          return day != null && range.contains(day);
        }),
      );

  // ---------------------------------------------------------------------------
  // 读：跨天阶段
  // ---------------------------------------------------------------------------

  @override
  Stream<List<PlanSpan>> watchSpansInRange(LocalDateRange range) => _watch(
    () => _sortedSpans(_aliveSpans.where((span) => span.overlaps(range))),
  );

  @override
  Stream<List<PlanSpan>> watchSpansForProject(String projectId) => _watch(
    () =>
        _sortedSpans(_aliveSpans.where((span) => span.projectId == projectId)),
  );

  @override
  Stream<PlanSpan?> watchSpan(String id) => _watch(() {
    final span = _spans[id];
    return span == null || span.isDeleted ? null : span;
  });

  @override
  Future<PlanSpan?> findSpan(String id) async {
    final span = _spans[id];
    return span == null || span.isDeleted ? null : span;
  }

  // ---------------------------------------------------------------------------
  // 读：每日备注
  // ---------------------------------------------------------------------------

  @override
  Stream<DailyNote?> watchDailyNote(LocalDate date) =>
      _watch(() => _liveNote(date));

  @override
  Future<DailyNote?> findDailyNote(LocalDate date) async => _liveNote(date);

  // ---------------------------------------------------------------------------
  // 写：项目
  // ---------------------------------------------------------------------------

  @override
  Future<Project> createProject(ProjectDraft draft) async {
    _ensureOpen();
    final now = _now();
    final liveCount = _projects.values
        .where((project) => !project.isDeleted)
        .length;
    final project = Project(
      id: _newId(),
      createdAt: now,
      updatedAt: now,
      revision: 1,
      name: draft.name,
      description: draft.description,
      color: draft.color ?? ProjectColor.suggestFor(liveCount),
      status: draft.status,
      sortOrder: draft.sortOrder,
    );
    _projects[project.id] = project;
    _emit();
    return project;
  }

  @override
  Future<Project> updateProject(Project project) async {
    _ensureOpen();
    final stored = _requireProject(project.id);
    _guardRevision(project.revision, stored.revision, '项目');
    final now = _now();
    final next = project.copyWith(
      createdAt: stored.createdAt,
      updatedAt: now,
      revision: stored.revision + 1,
    );
    _projects[next.id] = next;
    _emit();
    return next;
  }

  @override
  Future<void> deleteProject(String id) async {
    _ensureOpen();
    final stored = _requireProject(id);
    final now = _now();
    final nextRevision = stored.revision + 1;

    _projects[id] = stored.copyWith(
      deletedAt: now,
      updatedAt: now,
      revision: nextRevision,
    );
    // 级联软删除：阶段与任务一起消失，但数据保留，未来可恢复。
    for (final span in _spans.values.toList()) {
      if (span.projectId != id || span.isDeleted) continue;
      _spans[span.id] = span.copyWith(
        deletedAt: now,
        updatedAt: now,
        revision: span.revision + 1,
      );
    }
    for (final task in _tasks.values.toList()) {
      if (task.projectId != id || task.isDeleted) continue;
      _tasks[task.id] = task.copyWith(
        deletedAt: now,
        updatedAt: now,
        revision: task.revision + 1,
      );
    }
    _emit();
  }

  // ---------------------------------------------------------------------------
  // 写：任务
  // ---------------------------------------------------------------------------

  @override
  Future<PlannerTask> createTask(PlannerTaskDraft draft) async {
    _ensureOpen();
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
    _tasks[task.id] = task;
    _emit();
    return task;
  }

  @override
  Future<PlannerTask> updateTask(PlannerTask task) async {
    _ensureOpen();
    final stored = _requireTask(task.id);
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
    _tasks[next.id] = next;
    _emit();
    return next;
  }

  @override
  Future<void> deleteTask(String id) async {
    _ensureOpen();
    final stored = _requireTask(id);
    final now = _now();
    _tasks[id] = stored.copyWith(
      deletedAt: now,
      updatedAt: now,
      revision: stored.revision + 1,
    );
    _emit();
  }

  // ---------------------------------------------------------------------------
  // 写：跨天阶段
  // ---------------------------------------------------------------------------

  @override
  Future<PlanSpan> createSpan(PlanSpanDraft draft) async {
    _ensureOpen();
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
    _spans[span.id] = span;
    _emit();
    return span;
  }

  @override
  Future<PlanSpan> updateSpan(PlanSpan span) async {
    _ensureOpen();
    final stored = _requireSpan(span.id);
    _guardRevision(span.revision, stored.revision, '阶段');
    _requireProject(span.projectId);
    final now = _now();
    final next = span.copyWith(
      createdAt: stored.createdAt,
      updatedAt: now,
      revision: stored.revision + 1,
    );
    _spans[next.id] = next;
    _emit();
    return next;
  }

  @override
  Future<void> deleteSpan(String id) async {
    _ensureOpen();
    final stored = _requireSpan(id);
    final now = _now();
    _spans[id] = stored.copyWith(
      deletedAt: now,
      updatedAt: now,
      revision: stored.revision + 1,
    );
    // 阶段删除后任务保留，只解除关联。
    for (final task in _tasks.values.toList()) {
      if (task.spanId != id || task.isDeleted) continue;
      _tasks[task.id] = task.copyWith(
        spanId: null,
        updatedAt: now,
        revision: task.revision + 1,
      );
    }
    _emit();
  }

  // ---------------------------------------------------------------------------
  // 写：每日备注
  // ---------------------------------------------------------------------------

  @override
  Future<DailyNote> saveDailyNote(
    LocalDate date, {
    String body = '',
    List<String> focusItems = const <String>[],
  }) async {
    _ensureOpen();
    final existing = _liveNote(date);
    final now = _now();
    final next = existing == null
        ? DailyNote(
            id: _newId(),
            createdAt: now,
            updatedAt: now,
            revision: 1,
            date: date,
            body: body,
            focusItems: focusItems,
          )
        : existing.copyWith(
            body: body,
            focusItems: focusItems,
            updatedAt: now,
            revision: existing.revision + 1,
          );
    _notesByDate[date.iso] = next;
    _emit();
    return next;
  }

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
    await _changes.close();
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  DateTime _now() => _clock().toUtc();

  bool _ensureOpen() {
    if (_closed) {
      throw StateError('InMemoryPlannerRepository 已关闭，不能再读写');
    }
    return true;
  }

  Iterable<PlannerTask> get _aliveTasks =>
      _tasks.values.where((task) => !task.isDeleted);

  Iterable<PlanSpan> get _aliveSpans =>
      _spans.values.where((span) => !span.isDeleted);

  DailyNote? _liveNote(LocalDate date) {
    final note = _notesByDate[date.iso];
    return note == null || note.isDeleted ? null : note;
  }

  Project _requireProject(String id) {
    final project = _projects[id];
    if (project == null || project.isDeleted) {
      throw PlannerNotFoundException('项目不存在或已删除：$id');
    }
    return project;
  }

  PlannerTask _requireTask(String id) {
    final task = _tasks[id];
    if (task == null || task.isDeleted) {
      throw PlannerNotFoundException('任务不存在或已删除：$id');
    }
    return task;
  }

  PlanSpan _requireSpan(String id) {
    final span = _spans[id];
    if (span == null || span.isDeleted) {
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

  List<Project> _sortedProjects({required bool includeArchived}) {
    final list =
        _projects.values
            .where((project) => !project.isDeleted)
            .where((project) => includeArchived || !project.isArchived)
            .toList()
          ..sort(_compareProjects);
    return List<Project>.unmodifiable(list);
  }

  List<PlannerTask> _sortedTasks(Iterable<PlannerTask> source) {
    final list = source.toList()..sort(_compareTasks);
    return List<PlannerTask>.unmodifiable(list);
  }

  List<PlanSpan> _sortedSpans(Iterable<PlanSpan> source) {
    final list = source.toList()..sort(_compareSpans);
    return List<PlanSpan>.unmodifiable(list);
  }

  static int _compareProjects(Project a, Project b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.createdAt.compareTo(b.createdAt);
  }

  static int _compareTasks(PlannerTask a, PlannerTask b) {
    final aDay = a.scheduledDate;
    final bDay = b.scheduledDate;
    if (aDay != null && bDay == null) return -1;
    if (aDay == null && bDay != null) return 1;
    if (aDay != null && bDay != null) {
      final byDay = aDay.compareTo(bDay);
      if (byDay != 0) return byDay;
    }

    final aStart = a.timeSlot?.startMinute;
    final bStart = b.timeSlot?.startMinute;
    if (aStart != null && bStart == null) return -1;
    if (aStart == null && bStart != null) return 1;
    if (aStart != null && bStart != null) {
      final byStart = aStart.compareTo(bStart);
      if (byStart != 0) return byStart;
    }

    final byPriority = b.priority.level.compareTo(a.priority.level);
    if (byPriority != 0) return byPriority;
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.createdAt.compareTo(b.createdAt);
  }

  static int _compareSpans(PlanSpan a, PlanSpan b) {
    final byStart = a.startDate.compareTo(b.startDate);
    if (byStart != 0) return byStart;
    final byEnd = b.endDate.compareTo(a.endDate);
    if (byEnd != 0) return byEnd;
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.createdAt.compareTo(b.createdAt);
  }

  /// 把读取函数包装成一个"先推当前值，之后每次写入再推"的流。
  Stream<T> _watch<T>(T Function() read) {
    late final StreamController<T> controller;
    StreamSubscription<void>? subscription;

    controller = StreamController<T>(
      onListen: () {
        controller.add(read());
        subscription = _changes.stream.listen((_) {
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

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
