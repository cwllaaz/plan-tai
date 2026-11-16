import '../models/models.dart';

/// 计划台唯一的本地数据访问接口（**已冻结**）。
///
/// 界面层只依赖这个接口，不直接接触 SQLite / Drift。这样可以：
/// - 用 [InMemoryPlannerRepository] 在没有数据库时并行开发 UI；
/// - 数据层 用 SQLite 实现正式仓储时，上层代码一行都不用改；
/// - 未来换成云同步实现时，界面仍然稳定。
///
/// ## 通用约定
///
/// 1. **响应式优先**：读操作同时提供 `watchXxx`（流，先推当前值再推变化）与
///    `findXxx`（一次性 Future）。界面默认用 `StreamBuilder` 订阅。
/// 2. **日期闭区间**：所有范围查询的 [LocalDateRange] 首尾都包含。
/// 3. **软删除**：`deleteXxx` 只写 `deletedAt` 并把 `revision` +1，不物理删除；
///    所有 watch/find 默认过滤已删除记录。
/// 4. **乐观并发**：`updateXxx` 必须传入带最新 `revision` 的完整实体；
///    版本不一致抛 [PlannerConflictException]，调用方应重新读取后重试。
/// 5. **级联**：删除项目会级联软删除其下所有阶段与任务；删除阶段只把任务的
///    `spanId` 置空（任务保留）。
/// 6. **排序**：流中返回的集合顺序稳定，具体规则见每个方法的注释。
/// 7. **错误**：只抛 [PlannerValidationException] / [PlannerNotFoundException] /
///    [PlannerConflictException]，不抛裸异常。
///
/// 完整字段语义见 docs/DATA_CONTRACT.md；模块如何使用见 docs/MODULE_API.md。
abstract interface class PlannerRepository {
  // ---------------------------------------------------------------------------
  // 项目
  // ---------------------------------------------------------------------------

  /// 监听项目集合。
  ///
  /// [includeArchived] 为 false（默认）时排除 `archived` 项目，但保留 `paused`。
  /// 顺序：`sortOrder` 升序，其次 `createdAt` 升序。
  Stream<List<Project>> watchProjects({bool includeArchived = false});

  /// 读取单个项目；不存在或已删除时返回 null。
  Future<Project?> findProject(String id);

  // ---------------------------------------------------------------------------
  // 任务
  // ---------------------------------------------------------------------------

  /// 监听 [range] 内已排期的任务（只含 `scheduledDate` 落在闭区间内的记录）。
  ///
  /// 未排期任务请用 [watchUnscheduledTasks]。
  /// 顺序：日期升序 → 有时间的在前（开始分钟升序）→ 优先级降序 →
  /// `sortOrder` 升序 → 创建时间升序。
  Stream<List<PlannerTask>> watchTasksInRange(LocalDateRange range);

  /// 监听所有未排期任务（收件箱），顺序同 [watchTasksInRange]。
  Stream<List<PlannerTask>> watchUnscheduledTasks();

  /// 监听某个项目下的全部任务（跨日期），用于侧栏计数与项目页。
  Stream<List<PlannerTask>> watchTasksForProject(String projectId);

  /// 监听所有未删除任务。数据量在 V1 量级（< 1 万条）内可接受，
  /// 但月历必须用 [watchTasksInRange]，不要用全量流做范围过滤。
  Stream<List<PlannerTask>> watchAllTasks();

  /// 监听单个任务；不存在或已删除时为 null。
  Stream<PlannerTask?> watchTask(String id);

  /// 一次性读取单个任务。
  Future<PlannerTask?> findTask(String id);

  /// 一次性读取 [range] 内的任务。
  Future<List<PlannerTask>> tasksInRange(LocalDateRange range);

  // ---------------------------------------------------------------------------
  // 跨天阶段
  // ---------------------------------------------------------------------------

  /// 监听与 [range] **有交集**的跨天阶段。
  ///
  /// 判定使用闭区间重叠：`span.startDate <= range.end && span.endDate >= range.start`。
  /// 跨月的阶段因此会同时出现在两个月里，由视图自行分段。
  /// 顺序：`startDate` 升序 → `endDate` 降序 → `sortOrder` 升序。
  Stream<List<PlanSpan>> watchSpansInRange(LocalDateRange range);

  /// 监听某个项目下的全部阶段。
  Stream<List<PlanSpan>> watchSpansForProject(String projectId);

  /// 监听单个阶段。
  Stream<PlanSpan?> watchSpan(String id);

  /// 一次性读取单个阶段。
  Future<PlanSpan?> findSpan(String id);

  // ---------------------------------------------------------------------------
  // 每日备注
  // ---------------------------------------------------------------------------

  /// 监听某一天的备注；没有记录时为 null（不等于空备注）。
  Stream<DailyNote?> watchDailyNote(LocalDate date);

  /// 一次性读取某一天的备注。
  Future<DailyNote?> findDailyNote(LocalDate date);

  // ---------------------------------------------------------------------------
  // 写操作：项目
  // ---------------------------------------------------------------------------

  /// 创建项目。id / 同步字段由仓储生成；[ProjectDraft.color] 为 null 时自动取色。
  Future<Project> createProject(ProjectDraft draft);

  /// 更新项目，返回写入后的新实体（`revision` 已 +1）。
  Future<Project> updateProject(Project project);

  /// 软删除项目，并级联软删除其下阶段与任务。
  Future<void> deleteProject(String id);

  // ---------------------------------------------------------------------------
  // 写操作：任务
  // ---------------------------------------------------------------------------

  /// 创建任务。若带 [PlannerTaskDraft.spanId]，该阶段必须存在且属于同一项目。
  Future<PlannerTask> createTask(PlannerTaskDraft draft);

  /// 更新任务，返回写入后的新实体。
  ///
  /// 完成/取消完成时由仓储维护 `completedAt`（UTC）。
  Future<PlannerTask> updateTask(PlannerTask task);

  /// 软删除任务。
  Future<void> deleteTask(String id);

  // ---------------------------------------------------------------------------
  // 写操作：跨天阶段
  // ---------------------------------------------------------------------------

  /// 创建阶段，返回新实体。
  Future<PlanSpan> createSpan(PlanSpanDraft draft);

  /// 更新阶段，返回写入后的新实体。
  Future<PlanSpan> updateSpan(PlanSpan span);

  /// 软删除阶段；其下任务的 `spanId` 会被置空，任务本身保留。
  Future<void> deleteSpan(String id);

  // ---------------------------------------------------------------------------
  // 写操作：每日备注
  // ---------------------------------------------------------------------------

  /// 保存（upsert）某一天的备注。同一天只有一条记录。
  ///
  /// [focusItems] 超过 3 条或单条超过 60 字会抛 [PlannerValidationException]。
  Future<DailyNote> saveDailyNote(
    LocalDate date, {
    String body = '',
    List<String> focusItems = const <String>[],
  });

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 释放流与底层连接；可重复调用。应用退出时调用一次。
  Future<void> close();
}
