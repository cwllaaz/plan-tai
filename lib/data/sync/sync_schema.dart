/// 本地数据库 v2 结构：同步引擎所需的列与三张表。
///
/// 与 docs/sync/DATA_CONTRACT.md §7 严格一致（字段名、约束、索引都不可改）：
/// - 四张业务表只加 `server_revision` 列，既有记录默认 0（= 尚未在云端确认）；
/// - `sync_outbox`：离线操作队列，唯一索引只约束 **pending** 行，
///   因此"正在发送的旧操作 + 新的 pending 操作"可以并存；
/// - `sync_conflicts`：冲突持久化；
/// - `sync_state`：单行游标与自动同步开关。
///
/// 只允许加表/加列/加索引；删列、改名必须走新的 schemaVersion。
library;

import 'package:sqlite3/sqlite3.dart';

const List<String> createSyncSchemaV2Statements = <String>[
  'ALTER TABLE projects ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE plan_spans ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE planner_tasks ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE daily_notes ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0',
  '''
CREATE TABLE IF NOT EXISTS sync_outbox (
  op_id           TEXT PRIMARY KEY,
  entity_type     TEXT NOT NULL
                          CHECK (entity_type IN ('project', 'span', 'task', 'note')),
  entity_id       TEXT NOT NULL,
  operation       TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
  base_revision   INTEGER NOT NULL CHECK (base_revision >= 0),
  local_revision  INTEGER NOT NULL CHECK (local_revision >= 1),
  payload         TEXT NOT NULL,
  device_id       TEXT NOT NULL,
  state           TEXT NOT NULL DEFAULT 'pending'
                          CHECK (state IN ('pending', 'sending', 'failed')),
  attempts        INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at TEXT,
  last_error      TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
)''',
  'CREATE INDEX IF NOT EXISTS idx_outbox_pending '
      'ON sync_outbox(state, next_attempt_at, created_at)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_outbox_entity_pending '
      "ON sync_outbox(entity_type, entity_id) WHERE state = 'pending'",
  'CREATE INDEX IF NOT EXISTS idx_outbox_entity '
      'ON sync_outbox(entity_type, entity_id)',
  '''
CREATE TABLE IF NOT EXISTS sync_conflicts (
  id              TEXT PRIMARY KEY,
  entity_type     TEXT NOT NULL
                          CHECK (entity_type IN ('project', 'span', 'task', 'note')),
  entity_id       TEXT NOT NULL,
  kind            TEXT NOT NULL,
  base_revision   INTEGER NOT NULL DEFAULT 0,
  server_revision INTEGER NOT NULL DEFAULT 0,
  server_deleted  INTEGER NOT NULL DEFAULT 0,
  local_payload   TEXT,
  server_payload  TEXT,
  detected_at     TEXT NOT NULL,
  resolved_at     TEXT
)''',
  'CREATE INDEX IF NOT EXISTS idx_conflicts_open '
      'ON sync_conflicts(resolved_at, detected_at)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_conflicts_entity_open '
      'ON sync_conflicts(entity_type, entity_id) WHERE resolved_at IS NULL',
  '''
CREATE TABLE IF NOT EXISTS sync_state (
  id               INTEGER PRIMARY KEY CHECK (id = 1),
  protocol_version INTEGER NOT NULL DEFAULT 1,
  cursor           TEXT,
  last_sync_at     TEXT,
  auto_sync        INTEGER NOT NULL DEFAULT 1,
  last_error       TEXT,
  needs_reconcile  INTEGER NOT NULL DEFAULT 0
)''',
  'INSERT OR IGNORE INTO sync_state(id) VALUES (1)',
];

/// 执行 v2 迁移（由 `PlannerDatabase.applyMigrations` 调用，已在事务内）。
void applySyncSchemaV2(Database handle) {
  for (final statement in createSyncSchemaV2Statements) {
    handle.execute(statement);
  }
}
