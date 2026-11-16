# 计划台 · 数据契约（V1.0，已冻结）

> 本文件是公共数据模型的**唯一权威说明**。代码对应 `lib/core/models/` 与
> `lib/core/contracts/planner_repository.dart`；两者已冻结，任何字段/语义变更必须由
> 契约变更需同步更新文档与对应测试。
>
> SQLite 实现由 数据层 完成，表名/列名可自定，但**必须能无损映射本文的全部字段与语义**。

## 1. 六条全局规则

| 规则 | 内容 | 原因 |
|---|---|---|
| **日期型** | `LocalDate`，字符串 `YYYY-MM-DD`，**无时区** | 用户说"3 号"，在哪个时区都是 3 号。禁止用 UTC 时间戳表示某一天 |
| **日时刻** | `TimeSlot` = `startMinute`（0–1439）+ `durationMinutes`（1–1440），且 `start + duration ≤ 1440` | 任务的"09:00"是墙上的钟，不是时刻。禁止跨午夜，跨天用 `PlanSpan` |
| **时刻型** | `DateTime`（UTC），序列化 `YYYY-MM-DDTHH:MM:SSZ` | 仅用于同步/排序/审计，不参与"哪一天"的业务判断 |
| **闭区间** | 跨天阶段 `[startDate, endDate]` 首尾都算；3 日–7 日是 **5 天** | 避免"5 天写成 4 天"；重叠判断不会漏掉接触日 |
| **主键** | UUIDv7（小写、36 位、版本位 7、variant 10xx） | 客户端离线可生成、按时间有序、未来合并无冲突 |
| **软删除** | 只写 `deletedAt`，不 DELETE；查询默认过滤 | 同步必须能表达"删除"，硬删会让对端复活 |

> 时间戳必须是 UTC：`PlannerEntity` 在 debug 下用 assert 校验 `isUtc`，测试覆盖。
> 日期运算全部走 UTC 零点，避免夏令时导致 ±1 天。

## 2. 公共同步字段（四个实体都有）

| 字段 | Dart 类型 | 可空 | 说明 |
|---|---|---|---|
| `id` | `String` | 否 | UUIDv7；创建后永不变 |
| `createdAt` | `DateTime`（UTC） | 否 | 创建时刻 |
| `updatedAt` | `DateTime`（UTC） | 否 | 最后写入时刻，每次写更新 |
| `revision` | `int` | 否 | 从 1 开始，每次成功写入 +1 |
| `deletedAt` | `DateTime?`（UTC） | 是 | 非 null = 已删除（软删除） |

`isDeleted => deletedAt != null`。所有 `watch*` / `find*` 默认不返回已删除记录。

## 3. Project（项目）

| 字段 | 类型 | 约束 / 默认 | 说明 |
|---|---|---|---|
| `name` | `String` | 非空，trim 后 ≤ 80 | 项目名 |
| `description` | `String` | 默认 `''`，≤ 2000 | 简介 |
| `color` | `ProjectColor` | 默认蓝色 `#3E63DD` | 统一 `#RRGGBB`，不存 alpha、不存颜色名 |
| `status` | `ProjectStatus` | `active` | `active` / `paused` / `archived` |
| `sortOrder` | `int` | 默认 0 | 升序，其次按 `createdAt` |

**颜色格式**：`ProjectColor.hex` 输出大写 `#RRGGBB`；`rgb` 为 24 位整数。
8 色板：`#3E63DD #12A594 #30A46C #F5A524 #E5484D #8E4EC6 #0D8BD1 #D6409F`。
`createProject` 时 `color == null` 由仓储按 `ProjectColor.suggestFor(现有项目数)` 分配。

**删除项目**：二次确认后软删除该项目，并**级联软删除其全部阶段与任务**（同一批次、
同一时刻写入，各自 revision +1）。数据保留可恢复；列表/月历立即不再显示。

## 4. PlanSpan（跨天阶段 / 安排）

阶段必须属于某个项目，**不是任务**，不能塞进 `PlannerTask`。

| 字段 | 类型 | 约束 / 默认 | 说明 |
|---|---|---|---|
| `projectId` | `String` | 非空，必须存在 | 所属项目 |
| `title` | `String` | 非空，≤ 120 | 阶段名 |
| `startDate` | `LocalDate` | 必填 | 起始日，**含** |
| `endDate` | `LocalDate` | 必填，`>= startDate` | 结束日，**含** |
| `status` | `PlanSpanStatus` | `planned` | `planned` / `doing` / `done` / `dropped` |
| `description` | `String` | 默认 `''`，≤ 2000 | 说明 |
| `color` | `ProjectColor?` | `null` | null = 继承项目色 |
| `sortOrder` | `int` | 默认 0 | 同日多条时的排序 |

校验：`endDate >= startDate`；`lengthInDays = end - start + 1 ≤ 366`。

**删除阶段**：软删除阶段；其下任务的 `spanId` 置为 null（任务保留，revision +1）。

## 5. PlannerTask（任务）

| 字段 | 类型 | 约束 / 默认 | 说明 |
|---|---|---|---|
| `projectId` | `String?` | null = 收件箱 | 可无项目 |
| `spanId` | `String?` | 若设置则 `projectId` 必须非空且同一项目 | 可选归属阶段 |
| `title` | `String` | 非空，≤ 200 | 标题 |
| `notes` | `String` | 默认 `''`，≤ 5000 | 备注 |
| `scheduledDate` | `LocalDate?` | null = **未排期（收件箱）** | 排到哪一天 |
| `timeSlot` | `TimeSlot?` | 有值时必须 `scheduledDate != null` | null = 当天无固定时刻 |
| `priority` | `TaskPriority` | `normal`(1) | `low`(0) / `normal`(1) / `high`(2) / `urgent`(3) |
| `status` | `TaskStatus` | `todo` | `todo` / `done` |
| `completedAt` | `DateTime?`（UTC） | 仅当 `status == done` 时非 null | 由仓储维护 |
| `sortOrder` | `int` | 默认 0 | 同日手工排序 |

关键语义：

- **可以没有具体时间**：`timeSlot == null` 表示"当天要做，不排几点"。
- **不能跨午夜**：`timeSlot` 的 `start + duration ≤ 1440`；跨天请建 `PlanSpan`。
- **完成 ≠ 删除**：`status=done` 的任务仍留在当天；"已完成"是筛选视图。
- **完成时刻**：仓储在 `todo → done` 时写入当前 UTC；`done → todo` 时清空。
- **`copyWith(status: todo)` 会自动清空 `completedAt`**，保证模型不变量。

## 6. DailyNote（每日备注）

| 字段 | 类型 | 约束 / 默认 | 说明 |
|---|---|---|---|
| `date` | `LocalDate` | 必填，**唯一**（一天一条） | 所属日历日 |
| `body` | `String` | 默认 `''`，≤ 10000 | 自由文本 |
| `focusItems` | `List<String>` | 最多 3 条，单条 ≤ 60，trim、去空串、不可变 | 当日重点 |

保存用 upsert：同一天第二次保存复用同一条记录（id 不变，revision +1）。
删除日历日备注一般不发生；恢复备份时按 date upsert。

## 7. 关系、级联与索引

```
projects 1──n plan_spans
projects 1──n planner_tasks (projectId 可空)
plan_spans 1──n planner_tasks (spanId 可空)
daily_notes 独立（按 date 唯一）
```

| 操作 | 结果 |
|---|---|
| 删除项目 | 项目 + 其阶段 + 其任务全部软删除，同一 `deletedAt` |
| 删除阶段 | 阶段软删除；任务保留，`spanId → null` |
| 删除任务 | 任务软删除 |
| 删除备注 | 不提供（可写空内容） |

SQLite 实现必须建这些索引（查询才能走范围）：

```sql
CREATE INDEX idx_tasks_scheduled ON planner_tasks(scheduled_date);
CREATE INDEX idx_tasks_project    ON planner_tasks(project_id);
CREATE INDEX idx_tasks_span       ON planner_tasks(span_id);
CREATE INDEX idx_tasks_status     ON planner_tasks(status, completed_at);
CREATE INDEX idx_spans_range      ON plan_spans(start_date, end_date);
CREATE INDEX idx_spans_project    ON plan_spans(project_id);
CREATE INDEX idx_notes_date       ON daily_notes(date) WHERE deleted_at IS NULL;
```

## 8. 查询与排序契约

| 查询 | 返回 |
|---|---|
| `watchTasksInRange(range)` | `scheduledDate` 落在闭区间内的任务；不含未排期 |
| `watchUnscheduledTasks()` | `scheduledDate == null` 的任务 |
| `watchTasksForProject(id)` | 该项目全部任务（跨日期） |
| `watchAllTasks()` | 全部未删除任务（仅限计数/搜索等小规模用途） |
| `watchSpansInRange(range)` | 与区间**闭区间重叠**的阶段（跨月阶段会同时出现在两月） |
| `watchDailyNote(date)` | 当天备注或 null |

排序规则（实现与内存仓储必须一致，保证测试可复用）：

- 项目：`sortOrder` ↑ → `createdAt` ↑
- 任务：`scheduledDate` ↑（已排期在未排期前）→ 有时间的在前、`startMinute` ↑
  → `priority.level` ↓ → `sortOrder` ↑ → `createdAt` ↑
- 阶段：`startDate` ↑ → `endDate` ↓ → `sortOrder` ↑ → `createdAt` ↑

## 9. 并发与写入

- `create*` 接收 **Draft**；id 与同步字段由仓储生成。
- `update*` 接收**完整实体**，以 `entity.revision` 作为期望版本：
  - 与库中一致 → 写入，`revision + 1`，刷新 `updatedAt`；
  - 不一致 → 抛 `PlannerConflictException(expected, actual)`，调用方重新读取后再改。
- `delete*` 不改调用方持有的对象，直接以库中版本 +1 写 `deletedAt`。
- 内存实现与 SQLite 实现必须行为一致，`test/core/in_memory_repository_test.dart` 是行为基准。

## 10. 持久化与迁移（数据层 负责）

- 位置：`%APPDATA%\计划台\data\app.db`（`path_provider` 解析，禁止写工作目录）。
- 表名建议 `projects / plan_spans / planner_tasks / daily_notes / change_log / settings`；
  列名 snake_case；日期列 TEXT；时刻列 TEXT（ISO8601 UTC）；`revision` INTEGER。
- 必须 `PRAGMA foreign_keys = ON`；外键删除行为用 `ON DELETE RESTRICT`，级联由仓储在
  同一事务内显式完成（保证可审计、可回滚）。
- `schema_version` 从 1 开始，只允许"加表 / 加列 / 加索引"的向后兼容迁移；删列/改名走
  "新增列 → 搬迁 → 保留旧列一个版本"。
- V1 只建 `change_log`（只写不读），为 V2 同步留口。
- 备份 JSON 形状（V1 验收项）：
  ```json
  {
    "schemaVersion": 1,
    "appVersion": "1.0.0",
    "exportedAt": "2026-11-14T12:00:00Z",
    "projects": [], "planSpans": [], "plannerTasks": [], "dailyNotes": []
  }
  ```
  不包含日志、设备 ID。恢复时先校验 `schemaVersion`，高于当前版本拒绝并提示升级。

## 11. 冻结与变更流程

1. 本文件与 `lib/core/models`、`lib/core/contracts` 处于冻结状态。
2. 任何 Agent 发现契约不足（例如需要"任务标签"），**不得自行加字段**；
   向维护者提交：场景、字段、默认值、对旧数据的影响、测试用例。
3. 维护者在主干统一修改模型 + 内存实现 + 测试 + 本文件，然后同步三个工作区。
4. 版本号：模型不兼容变更 → V1.x 中标注 **BREAKING**，并给出迁移方法。
