// 计划台 V2.0 云端同步 · 初始库结构
//
// 设计要点：
//  1. 业务表全部是原生 SQLite 表（不是 PocketBase collection），因此不存在
//     /api/collections/<name>/records 这类自动暴露的 REST 端点，客户端只能通过
//     /api/pa/sync/* 自定义路由读写，owner 一律取自服务端认证身份。
//  2. 每条业务记录以 (owner, id) 为主键：id 是客户端生成的 UUIDv7，owner 是
//     PocketBase users.id。跨用户同 id 不会互相覆盖，也无法越权读写。
//  3. 软删除用 deleted_at 表达；增量变更日志 pa_changes.seq 是 AUTOINCREMENT，
//     全局单调递增，作为 pull 的可靠游标。
//  4. pa_ops 记录已处理的 opId，重复提交直接返回首次结果（幂等）。
//
// 结构变更流程见 docs/sync/SYNC_DATA.md。

migrate((app) => {
  const statements = [
    // ---------------------------------------------------------------- 项目
    `CREATE TABLE IF NOT EXISTS pa_projects (
       owner        TEXT    NOT NULL,
       id           TEXT    NOT NULL,
       name         TEXT    NOT NULL,
       description  TEXT    NOT NULL DEFAULT '',
       color        TEXT    NOT NULL,
       status       TEXT    NOT NULL DEFAULT 'active',
       sort_order   INTEGER NOT NULL DEFAULT 0,
       created_at   TEXT    NOT NULL,
       updated_at   TEXT    NOT NULL,
       revision     INTEGER NOT NULL,
       deleted_at   TEXT,
       PRIMARY KEY (owner, id),
       CHECK (revision >= 1),
       CHECK (status IN ('active', 'paused', 'archived')),
       CHECK (length(name) > 0)
     )`,

    // ------------------------------------------------------------ 跨天阶段
    `CREATE TABLE IF NOT EXISTS pa_spans (
       owner        TEXT    NOT NULL,
       id           TEXT    NOT NULL,
       project_id   TEXT    NOT NULL,
       title        TEXT    NOT NULL,
       start_date   TEXT    NOT NULL,
       end_date     TEXT    NOT NULL,
       status       TEXT    NOT NULL DEFAULT 'planned',
       description  TEXT    NOT NULL DEFAULT '',
       color        TEXT,
       sort_order   INTEGER NOT NULL DEFAULT 0,
       created_at   TEXT    NOT NULL,
       updated_at   TEXT    NOT NULL,
       revision     INTEGER NOT NULL,
       deleted_at   TEXT,
       PRIMARY KEY (owner, id),
       CHECK (revision >= 1),
       CHECK (end_date >= start_date),
       CHECK (status IN ('planned', 'doing', 'done', 'dropped')),
       CHECK (length(title) > 0)
     )`,

    // ---------------------------------------------------------------- 任务
    `CREATE TABLE IF NOT EXISTS pa_tasks (
       owner            TEXT    NOT NULL,
       id               TEXT    NOT NULL,
       project_id       TEXT,
       span_id          TEXT,
       title            TEXT    NOT NULL,
       notes            TEXT    NOT NULL DEFAULT '',
       scheduled_date   TEXT,
       time_start       INTEGER,
       time_duration    INTEGER,
       priority         INTEGER NOT NULL DEFAULT 1,
       status           TEXT    NOT NULL DEFAULT 'todo',
       completed_at     TEXT,
       sort_order       INTEGER NOT NULL DEFAULT 0,
       created_at       TEXT    NOT NULL,
       updated_at       TEXT    NOT NULL,
       revision         INTEGER NOT NULL,
       deleted_at       TEXT,
       PRIMARY KEY (owner, id),
       CHECK (revision >= 1),
       CHECK (length(title) > 0),
       CHECK (priority BETWEEN 0 AND 3),
       CHECK (status IN ('todo', 'done')),
       CHECK (
         time_start IS NULL
         OR (
           scheduled_date IS NOT NULL
           AND time_start BETWEEN 0 AND 1439
           AND time_duration BETWEEN 1 AND 1440
           AND time_start + time_duration <= 1440
         )
       )
     )`,

    // ------------------------------------------------------------ 每日备注
    `CREATE TABLE IF NOT EXISTS pa_notes (
       owner        TEXT    NOT NULL,
       id           TEXT    NOT NULL,
       date         TEXT    NOT NULL,
       body         TEXT    NOT NULL DEFAULT '',
       focus_items  TEXT    NOT NULL DEFAULT '[]',
       created_at   TEXT    NOT NULL,
       updated_at   TEXT    NOT NULL,
       revision     INTEGER NOT NULL,
       deleted_at   TEXT,
       PRIMARY KEY (owner, id),
       CHECK (revision >= 1),
       CHECK (length(date) = 10)
     )`,

    // -------------------------------------------------------- 增量变更日志
    // seq 由 SQLite AUTOINCREMENT 分配：写事务提交顺序即 seq 顺序，
    // 客户端以 seq 为游标可以精确增量拉取，不会被客户端时钟影响。
    `CREATE TABLE IF NOT EXISTS pa_changes (
       seq             INTEGER PRIMARY KEY AUTOINCREMENT,
       owner           TEXT    NOT NULL,
       entity          TEXT    NOT NULL,
       entity_id       TEXT    NOT NULL,
       op              TEXT    NOT NULL,
       revision        INTEGER NOT NULL,
       payload         TEXT    NOT NULL,
       device_id       TEXT    NOT NULL DEFAULT '',
       client_updated_at TEXT,
       server_time     TEXT    NOT NULL,
       op_id           TEXT    NOT NULL,
       CHECK (entity IN ('project', 'span', 'task', 'note')),
       CHECK (op IN ('upsert', 'delete'))
     )`,

    // ------------------------------------------------------ 已处理操作去重
    `CREATE TABLE IF NOT EXISTS pa_ops (
       owner           TEXT    NOT NULL,
       op_id           TEXT    NOT NULL,
       entity          TEXT    NOT NULL,
       entity_id       TEXT    NOT NULL,
       status          TEXT    NOT NULL,
       code            TEXT    NOT NULL DEFAULT '',
       message         TEXT    NOT NULL DEFAULT '',
       server_revision INTEGER,
       server_seq      INTEGER,
       created_at      TEXT    NOT NULL,
       PRIMARY KEY (owner, op_id)
     )`,

    // ---------------------------------------------------------- 元信息表
    `CREATE TABLE IF NOT EXISTS pa_schema (
       key   TEXT PRIMARY KEY,
       value TEXT NOT NULL
     )`,

    // -------------------------------------------------------------- 索引
    `CREATE INDEX IF NOT EXISTS idx_pa_changes_owner_seq ON pa_changes (owner, seq)`,
    `CREATE INDEX IF NOT EXISTS idx_pa_spans_project ON pa_spans (owner, project_id)`,
    `CREATE INDEX IF NOT EXISTS idx_pa_tasks_project ON pa_tasks (owner, project_id)`,
    `CREATE INDEX IF NOT EXISTS idx_pa_tasks_span ON pa_tasks (owner, span_id)`,
    `CREATE INDEX IF NOT EXISTS idx_pa_tasks_date ON pa_tasks (owner, scheduled_date)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS ux_pa_notes_owner_date
       ON pa_notes (owner, date) WHERE deleted_at IS NULL`,
  ]

  for (let i = 0; i < statements.length; i++) {
    app.db().newQuery(statements[i]).execute()
  }

  app.db().newQuery("INSERT OR IGNORE INTO pa_schema (key, value) VALUES ('schema_version', '1')").execute()
  app.db().newQuery("INSERT OR IGNORE INTO pa_schema (key, value) VALUES ('protocol_version', '1')").execute()
}, (app) => {
  app.db().newQuery("DROP TABLE IF EXISTS pa_changes").execute()
  app.db().newQuery("DROP TABLE IF EXISTS pa_ops").execute()
  app.db().newQuery("DROP TABLE IF EXISTS pa_tasks").execute()
  app.db().newQuery("DROP TABLE IF EXISTS pa_spans").execute()
  app.db().newQuery("DROP TABLE IF EXISTS pa_notes").execute()
  app.db().newQuery("DROP TABLE IF EXISTS pa_projects").execute()
  app.db().newQuery("DROP TABLE IF EXISTS pa_schema").execute()
})
