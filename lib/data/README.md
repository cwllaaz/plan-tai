# lib/data —— 本地数据层（数据层）

正式本地持久化：**SQLite**（`package:sqlite3` + Windows 自带 `winsqlite3.dll`，手写 SQL 与
迁移）。**不引入 Drift / build_runner**，理由见 `docs/ARCHITECTURE.md` §4。

- 仓储实现：`SqlitePlannerRepository implements PlannerRepository`
- 数据库位置：`%APPDATA%\计划台\data\app.db`
- 完全离线可用；关闭软件再打开，数据完整保留。

## 1. 如何初始化与使用仓储

```dart
import 'package:jihuatai/data/data.dart';

// 打开（必要时创建目录、建表、执行迁移）。同步返回，不阻塞首帧。
final repository = SqlitePlannerRepository.open();

// 备份 / 恢复服务（可选，供设置页调用）
final backups = BackupService(repository, appVersion: '1.0.0');

// 退出时关闭（会 checkpoint WAL 并释放连接；可重复调用）
await repository.close();
```

上层只依赖 `PlannerRepository`（`lib/core/contracts/`），不知道下面是 SQLite：

```dart
StreamBuilder<List<PlannerTask>>(
  stream: repository.watchTasksInRange(monthRange),
  builder: (context, snapshot) => ...,
);
```

需要注意的三点：

1. **`open()` 打开失败不是"降级"，是错误**。磁盘无权限、库损坏、库版本比程序新，都会抛
   `LocalDatabaseException`；界面必须提示用户并引导从备份恢复，**不要**静默换回演示数据。
2. 测试 / 便携模式用 `SqlitePlannerRepository.open(databasePath: ...)` 指定路径，或设置环境变量
   `JIHUATAI_DATA_DIR`。
3. 所有写操作都是事务：级联删除、阶段解绑、变更日志要么全写，要么全不写。

## 2. 文件分工

| 文件 | 职责 |
|---|---|
| `sqlite_planner_repository.dart` | 正式仓储：全部 `watch* / find* / create* / update* / delete* / saveDailyNote` |
| `planner_database.dart` | 连接、PRAGMA、事务、迁移执行、完整性检查、`VACUUM INTO` 快照、关闭 |
| `sql_schema.dart` | 表 / 索引 / 列清单 / 排序子句 / 迁移链（结构的唯一权威） |
| `entity_codec.dart` | 实体与行 / JSON 的编解码、写入参数（日期与时刻的边界就这里） |
| `backup_service.dart` | JSON 备份导出 / 校验 / 恢复 + 一致性数据库快照 |
| `planner_paths.dart` | 存储位置规则（绝不写工作目录、临时目录、安装目录） |
| `data_exception.dart` | `LocalDatabaseException`（存储故障）、`BackupException`（备份故障） |

## 3. 存储位置

| 平台 | 路径 |
|---|---|
| Windows | `%APPDATA%\计划台\data\app.db` |
| 备份 | `%APPDATA%\计划台\data\backups\` |
| 覆盖基目录 | 环境变量 `JIHUATAI_DATA_DIR` |

拿不到用户目录时**抛异常而不是退到临时目录**，避免真实数据落进会被清理的位置。

## 4. 表结构（v1）

| 表 | 说明 |
|---|---|
| `projects` | 项目 |
| `plan_spans` | 跨天阶段（闭区间 `start_date`/`end_date`） |
| `planner_tasks` | 任务（`scheduled_date` 可为空 = 收件箱） |
| `daily_notes` | 每日备注（`date` 唯一，软删除后用部分唯一索引保证一天一条有效记录） |
| `change_log` | 变更日志，V1 **只写不读**，为 V2 同步预留 |
| `settings` | 键值表，存 `schema_version` 镜像 |

日期与时刻分开存：

- 日期列 `TEXT`，固定 `YYYY-MM-DD`，无时区。字符串序即日期序，范围查询用 `BETWEEN`。
- 时刻列 `TEXT`，固定 `YYYY-MM-DDTHH:MM:SS.ffffffZ`（UTC、定长）。定长才能让 SQL 排序 == 时间排序。
- 任务的"当天几点"拆成 `time_start_minute` + `time_duration_minutes` 两个整数列，
  **不存时间戳**，所以 11 月 16 日的任务不可能因为时区变成 11 月 15 日。

索引：`idx_tasks_scheduled / idx_tasks_project / idx_tasks_span / idx_tasks_status /
idx_spans_range / idx_spans_project / idx_notes_date`（见 `docs/DATA_CONTRACT.md` §7）。

## 5. 备份与恢复

两种产物：

1. **JSON 备份**（`exportJson` / `inspect` / `restore`）：正式导出格式，带
   `format / formatVersion / schemaVersion / appVersion / exportedAt` 与四张表数组；
   包含软删除记录（墓碑），恢复后不会"复活"已删数据。
2. **SQLite 一致性快照**（`snapshotDatabase`）：走 `VACUUM INTO`，即使库正在写入也能拿到
   同一事务的完整副本，**不会得到半个数据库**。

恢复流程固定为：校验备份 → 自动快照当前数据 → 单事务整体替换 → 回读逐条比对 →
通知界面刷新。任何一步失败都整体回滚，旧数据不受影响；本地已有数据时必须显式
`confirmOverwrite: true` 才会覆盖。

```dart
final preview = await backups.inspect(path);   // 只读校验，返回摘要与数量
await backups.restore(preview, confirmOverwrite: true);
```

错误分类：`BackupErrorKind.fileNotFound / invalidFormat / newerSchema /
overwriteRefused / integrityFailed / ioFailure`，`message` 都是可直接展示的中文。

## 6. 迁移

- `PRAGMA user_version` 是权威版本，当前 `kSchemaVersion = 1`。
- `defaultSchemaMigrations` 是迁移链，加结构变更时追加一条并把 `kSchemaVersion` +1；
  每条迁移单独事务，失败自动回滚。
- 只允许"加表 / 加列 / 加索引"的向后兼容变更；删列、改名走"新增列 → 搬迁 → 旧列留一版"。
- 库版本高于程序时**拒绝打开**并提示升级，绝不删除重建。
- 打开时执行 `PRAGMA quick_check`，发现损坏就停下并提示从备份恢复。

## 7. 测试

```powershell
flutter analyze
flutter test test/data
```

测试全部使用系统临时目录里的真实 SQLite 文件（`TestEnv`），不会碰用户的
`%APPDATA%\计划台`。覆盖：CRUD、排序与范围查询、跨月/闰年日期、软删除、级联、
乐观并发、事务回滚、写入失败（磁盘满 / 被占用）、重启持久化、异常退出恢复、
迁移机制、备份导出/校验/恢复、以及与内存仓储的行为等价性。
