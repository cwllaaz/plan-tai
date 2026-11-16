/// 数据库结构的唯一权威定义（表、索引、迁移）。
///
/// 设计要点（全部来自 docs/DATA_CONTRACT.md）：
/// - 日期列 `TEXT`，固定 `YYYY-MM-DD`，**无时区**；字符串比较即日期比较。
/// - 时刻列（created/updated/deleted/completed）`TEXT`，固定
///   `YYYY-MM-DDTHH:MM:SS.ffffffZ`，UTC、定长，字符串序即时间序。
/// - 任务的"当天几点"拆成 `time_start_minute` + `time_duration_minutes` 两个
///   整数列，不用时间戳，避免时区换算把任务挪到别的日子。
/// - 软删除：所有查询过滤 `deleted_at IS NULL`；级联由仓储在同一事务里显式完成。
library;

import 'package:sqlite3/sqlite3.dart';

import 'sync/sync_schema.dart';

/// 当前应用支持的数据库结构版本。
///
/// 升级规则：只允许"加表 / 加列 / 加索引"的向后兼容迁移；删列、改名走
/// "新增列 → 搬迁 → 旧列保留一个版本"。绝不允许删除数据库重建。
///
/// v2（V2.0 云同步）：四张业务表加 `server_revision`，新增
/// `sync_outbox` / `sync_conflicts` / `sync_state`。既有数据原样保留。
const int kSchemaVersion = 2;

/// 一条结构迁移。`version` 是迁移完成后 [PRAGMA user_version] 的值。
final class SchemaMigration {
  const SchemaMigration({
    required this.version,
    required this.description,
    required this.apply,
  });

  final int version;
  final String description;
  final void Function(Database handle) apply;
}

// ---------------------------------------------------------------------------
// 列清单与排序子句（查询语句的唯一来源，避免各处手写列名漂移）
// ---------------------------------------------------------------------------

const String projectColumns =
    'id, created_at, updated_at, deleted_at, revision, name, description, '
    'color, status, sort_order';

const String spanColumns =
    'id, created_at, updated_at, deleted_at, revision, project_id, title, '
    'start_date, end_date, status, description, color, sort_order';

const String taskColumns =
    'id, created_at, updated_at, deleted_at, revision, project_id, span_id, '
    'title, notes, scheduled_date, time_start_minute, time_duration_minutes, '
    'priority, status, completed_at, sort_order';

const String noteColumns =
    'id, created_at, updated_at, deleted_at, revision, date, body, focus_items';

/// 项目：`sortOrder` ↑ → `createdAt` ↑。
const String projectOrderClause =
    'ORDER BY sort_order ASC, created_at ASC, id ASC';

/// 任务：已排期在前 → 日期 ↑ → 有时间的在前 → 开始分钟 ↑ →
/// 优先级 ↓ → `sortOrder` ↑ → 创建时间 ↑。
///
/// `(scheduled_date IS NULL) ASC` 把未排期沉到最后（SQLite 布尔值 0/1）。
const String taskOrderClause =
    'ORDER BY (scheduled_date IS NULL) ASC, scheduled_date ASC, '
    '(time_start_minute IS NULL) ASC, time_start_minute ASC, '
    'priority DESC, sort_order ASC, created_at ASC, id ASC';

/// 阶段：`startDate` ↑ → `endDate` ↓ → `sortOrder` ↑ → 创建时间 ↑。
const String spanOrderClause =
    'ORDER BY start_date ASC, end_date DESC, sort_order ASC, '
    'created_at ASC, id ASC';

const String noteOrderClause = 'ORDER BY date ASC';

// ---------------------------------------------------------------------------
// 写入语句（仓储与备份恢复共用，保证两条写入路径完全一致）
// ---------------------------------------------------------------------------

const String insertProjectSql =
    'INSERT INTO projects (id, created_at, updated_at, deleted_at, revision, '
    'name, description, color, status, sort_order) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

const String updateProjectSql =
    'UPDATE projects SET updated_at = ?, deleted_at = ?, name = ?, '
    'description = ?, color = ?, status = ?, sort_order = ?, revision = ? '
    'WHERE id = ?';

const String insertSpanSql =
    'INSERT INTO plan_spans (id, created_at, updated_at, deleted_at, '
    'revision, project_id, title, start_date, end_date, status, description, '
    'color, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

const String updateSpanSql =
    'UPDATE plan_spans SET updated_at = ?, deleted_at = ?, project_id = ?, '
    'title = ?, start_date = ?, end_date = ?, status = ?, description = ?, '
    'color = ?, sort_order = ?, revision = ? WHERE id = ?';

const String insertTaskSql =
    'INSERT INTO planner_tasks (id, created_at, updated_at, deleted_at, '
    'revision, project_id, span_id, title, notes, scheduled_date, '
    'time_start_minute, time_duration_minutes, priority, status, '
    'completed_at, sort_order) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

const String updateTaskSql =
    'UPDATE planner_tasks SET updated_at = ?, deleted_at = ?, project_id = ?, '
    'span_id = ?, title = ?, notes = ?, scheduled_date = ?, '
    'time_start_minute = ?, time_duration_minutes = ?, priority = ?, '
    'status = ?, completed_at = ?, sort_order = ?, revision = ? WHERE id = ?';

const String insertNoteSql =
    'INSERT INTO daily_notes (id, created_at, updated_at, deleted_at, '
    'revision, date, body, focus_items) VALUES (?, ?, ?, ?, ?, ?, ?, ?)';

const String updateNoteSql =
    'UPDATE daily_notes SET updated_at = ?, deleted_at = ?, body = ?, '
    'focus_items = ?, revision = ? WHERE id = ?';

// ---------------------------------------------------------------------------
// v1 结构
// ---------------------------------------------------------------------------

/// v1 建表语句。所有 `CREATE` 都带 `IF NOT EXISTS`，重复执行安全。
const List<String> createSchemaV1Statements = <String>[
  '''
CREATE TABLE IF NOT EXISTS projects (
  id          TEXT    NOT NULL PRIMARY KEY,
  created_at  TEXT    NOT NULL,
  updated_at  TEXT    NOT NULL,
  deleted_at  TEXT,
  revision    INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  name        TEXT    NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
  description TEXT    NOT NULL DEFAULT '',
  color       TEXT    NOT NULL CHECK (length(color) = 7 AND substr(color, 1, 1) = '#'),
  status      TEXT    NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'paused', 'archived')),
  sort_order  INTEGER NOT NULL DEFAULT 0
)''',
  'CREATE INDEX IF NOT EXISTS idx_projects_order '
      'ON projects(sort_order, created_at)',
  'CREATE INDEX IF NOT EXISTS idx_projects_alive '
      'ON projects(id) WHERE deleted_at IS NULL',
  '''
CREATE TABLE IF NOT EXISTS plan_spans (
  id          TEXT    NOT NULL PRIMARY KEY,
  created_at  TEXT    NOT NULL,
  updated_at  TEXT    NOT NULL,
  deleted_at  TEXT,
  revision    INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  project_id  TEXT    NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
  title       TEXT    NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 120),
  start_date  TEXT    NOT NULL CHECK (length(start_date) = 10),
  end_date    TEXT    NOT NULL CHECK (length(end_date) = 10),
  status      TEXT    NOT NULL DEFAULT 'planned'
                      CHECK (status IN ('planned', 'doing', 'done', 'dropped')),
  description TEXT    NOT NULL DEFAULT '',
  color       TEXT,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  CHECK (end_date >= start_date)
)''',
  'CREATE INDEX IF NOT EXISTS idx_spans_range '
      'ON plan_spans(start_date, end_date)',
  'CREATE INDEX IF NOT EXISTS idx_spans_project ON plan_spans(project_id)',
  '''
CREATE TABLE IF NOT EXISTS planner_tasks (
  id                    TEXT    NOT NULL PRIMARY KEY,
  created_at            TEXT    NOT NULL,
  updated_at            TEXT    NOT NULL,
  deleted_at            TEXT,
  revision              INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  project_id            TEXT    REFERENCES projects(id) ON DELETE RESTRICT,
  span_id               TEXT    REFERENCES plan_spans(id) ON DELETE RESTRICT,
  title                 TEXT    NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 200),
  notes                 TEXT    NOT NULL DEFAULT '',
  scheduled_date        TEXT    CHECK (scheduled_date IS NULL OR length(scheduled_date) = 10),
  time_start_minute     INTEGER,
  time_duration_minutes INTEGER,
  priority              INTEGER NOT NULL DEFAULT 1 CHECK (priority BETWEEN 0 AND 3),
  status                TEXT    NOT NULL DEFAULT 'todo'
                                CHECK (status IN ('todo', 'done')),
  completed_at          TEXT,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  CHECK (time_start_minute IS NULL OR scheduled_date IS NOT NULL),
  CHECK ((time_start_minute IS NULL) = (time_duration_minutes IS NULL)),
  CHECK (time_start_minute IS NULL
         OR (time_start_minute BETWEEN 0 AND 1439)),
  CHECK (time_duration_minutes IS NULL
         OR (time_duration_minutes BETWEEN 1 AND 1440)),
  CHECK (time_start_minute IS NULL
         OR time_start_minute + time_duration_minutes <= 1440),
  CHECK (span_id IS NULL OR project_id IS NOT NULL),
  CHECK (completed_at IS NULL OR status = 'done')
)''',
  'CREATE INDEX IF NOT EXISTS idx_tasks_scheduled '
      'ON planner_tasks(scheduled_date)',
  'CREATE INDEX IF NOT EXISTS idx_tasks_project ON planner_tasks(project_id)',
  'CREATE INDEX IF NOT EXISTS idx_tasks_span ON planner_tasks(span_id)',
  'CREATE INDEX IF NOT EXISTS idx_tasks_status '
      'ON planner_tasks(status, completed_at)',
  '''
CREATE TABLE IF NOT EXISTS daily_notes (
  id          TEXT    NOT NULL PRIMARY KEY,
  created_at  TEXT    NOT NULL,
  updated_at  TEXT    NOT NULL,
  deleted_at  TEXT,
  revision    INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  date        TEXT    NOT NULL CHECK (length(date) = 10),
  body        TEXT    NOT NULL DEFAULT '',
  focus_items TEXT    NOT NULL DEFAULT '[]'
)''',
  'CREATE INDEX IF NOT EXISTS idx_notes_date '
      'ON daily_notes(date) WHERE deleted_at IS NULL',
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_notes_date_alive '
      'ON daily_notes(date) WHERE deleted_at IS NULL',
  '''
CREATE TABLE IF NOT EXISTS change_log (
  seq         INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT    NOT NULL,
  entity_id   TEXT    NOT NULL,
  operation   TEXT    NOT NULL CHECK (operation IN ('create', 'update', 'delete', 'restore')),
  revision    INTEGER NOT NULL,
  changed_at  TEXT    NOT NULL
)''',
  'CREATE INDEX IF NOT EXISTS idx_change_log_entity '
      'ON change_log(entity_type, entity_id, seq)',
  'CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq)',
  '''
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''',
];

void _applyV1(Database handle) {
  for (final statement in createSchemaV1Statements) {
    handle.execute(statement);
  }
  handle.execute(
    'INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)',
    <Object?>['schema_version', '$kSchemaVersion'],
  );
}

/// 内置迁移链。将来加结构变更时在这里追加一条 `version: 3` 的记录，
/// 并把 [kSchemaVersion] +1。
const List<SchemaMigration> defaultSchemaMigrations = <SchemaMigration>[
  SchemaMigration(
    version: 1,
    description: '初始结构：项目 / 跨天阶段 / 任务 / 每日备注 / 变更日志 / 设置',
    apply: _applyV1,
  ),
  SchemaMigration(
    version: 2,
    description: '云同步：服务端版本列 / 离线操作队列 / 冲突表 / 同步状态',
    apply: applySyncSchemaV2,
  ),
];
