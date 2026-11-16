import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export const TASK_STATUSES = ['todo', 'doing', 'done'];
export const PRIORITIES = ['low', 'normal', 'high', 'urgent'];
export const PROJECT_STATUSES = ['active', 'paused', 'archived'];

export const PALETTE = [
  '#6366f1', '#0ea5e9', '#10b981', '#f59e0b',
  '#ef4444', '#ec4899', '#8b5cf6', '#14b8a6',
];

const SCHEMA = `
CREATE TABLE IF NOT EXISTS projects (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  color       TEXT NOT NULL DEFAULT '#6366f1',
  description TEXT NOT NULL DEFAULT '',
  status      TEXT NOT NULL DEFAULT 'active',
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  archived_at TEXT
);

CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY,
  project_id   TEXT REFERENCES projects(id) ON DELETE SET NULL,
  title        TEXT NOT NULL,
  notes        TEXT NOT NULL DEFAULT '',
  status       TEXT NOT NULL DEFAULT 'todo',
  priority     TEXT NOT NULL DEFAULT 'normal',
  estimate_min INTEGER,
  due_date     TEXT,
  start_at     TEXT,
  end_at       TEXT,
  completed_at TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  sort_order   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS subtasks (
  id         TEXT PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title      TEXT NOT NULL,
  done       INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS time_entries (
  id         TEXT PRIMARY KEY,
  task_id    TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  started_at TEXT NOT NULL,
  ended_at   TEXT,
  minutes    INTEGER,
  note       TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_due   ON tasks(due_date);
CREATE INDEX IF NOT EXISTS idx_tasks_start ON tasks(start_at);
CREATE INDEX IF NOT EXISTS idx_subtasks    ON subtasks(task_id);
CREATE INDEX IF NOT EXISTS idx_entries     ON time_entries(started_at);
`;

export class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ValidationError';
    this.status = 400;
  }
}

export class NotFoundError extends Error {
  constructor(message = '资源不存在') {
    super(message);
    this.name = 'NotFoundError';
    this.status = 404;
  }
}

const nowIso = () => new Date().toISOString();

/* ------------------------------------------------------------------ */
/* validation helpers                                                 */
/* ------------------------------------------------------------------ */

function text(value, field, { max = 500, required = false, fallback = '' } = {}) {
  if (value === undefined || value === null) {
    if (required) throw new ValidationError(`${field}不能为空`);
    return fallback;
  }
  if (typeof value !== 'string') throw new ValidationError(`${field}必须是文本`);
  const trimmed = value.trim();
  if (required && !trimmed) throw new ValidationError(`${field}不能为空`);
  if (trimmed.length > max) throw new ValidationError(`${field}不能超过 ${max} 个字符`);
  return trimmed;
}

function oneOf(value, field, allowed, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  if (!allowed.includes(value)) {
    throw new ValidationError(`${field}必须是 ${allowed.join(' / ')} 之一`);
  }
  return value;
}

function intOrNull(value, field, { min = 0, max = 100000 } = {}) {
  if (value === undefined || value === null || value === '') return null;
  const n = Number(value);
  if (!Number.isFinite(n)) throw new ValidationError(`${field}必须是数字`);
  const rounded = Math.round(n);
  if (rounded < min || rounded > max) {
    throw new ValidationError(`${field}必须在 ${min} 到 ${max} 之间`);
  }
  return rounded;
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const DT_RE = /^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?$/;

export function cleanDate(value, field) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || !DATE_RE.test(value)) {
    throw new ValidationError(`${field}必须是 YYYY-MM-DD 格式`);
  }
  const [y, m, d] = value.split('-').map(Number);
  const probe = new Date(Date.UTC(y, m - 1, d));
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) {
    throw new ValidationError(`${field}不是有效日期`);
  }
  return value;
}

export function cleanDateTime(value, field) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || !DT_RE.test(value)) {
    throw new ValidationError(`${field}必须是 YYYY-MM-DDTHH:MM 格式`);
  }
  const normalized = value.replace(' ', 'T');
  const withSeconds = normalized.length === 16 ? `${normalized}:00` : normalized;
  return withSeconds;
}

function isoOrNull(value, field) {
  if (value === undefined || value === null || value === '') return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw new ValidationError(`${field}不是有效时间`);
  return d.toISOString();
}

function color(value) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(value)) {
    throw new ValidationError('颜色必须是 #RRGGBB 格式');
  }
  return value.toLowerCase();
}

/* ------------------------------------------------------------------ */
/* row mappers                                                        */
/* ------------------------------------------------------------------ */

const PROJECT_COLS = `id, name, color, description, status, sort_order AS sortOrder, created_at AS createdAt, archived_at AS archivedAt`;
const TASK_COLS = `id, project_id AS projectId, title, notes, status, priority, estimate_min AS estimateMin,
  due_date AS dueDate, start_at AS startAt, end_at AS endAt, completed_at AS completedAt,
  created_at AS createdAt, updated_at AS updatedAt, sort_order AS sortOrder`;
const ENTRY_COLS = `id, task_id AS taskId, started_at AS startedAt, ended_at AS endedAt, minutes, note`;
const SUBTASK_COLS = `id, task_id AS taskId, title, done, sort_order AS sortOrder`;

/* ------------------------------------------------------------------ */
/* store                                                              */
/* ------------------------------------------------------------------ */

export function openStore(file) {
  if (file !== ':memory:') mkdirSync(dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec('PRAGMA foreign_keys = ON;');
  if (file !== ':memory:') db.exec('PRAGMA journal_mode = WAL;');
  db.exec(SCHEMA);

  const q = new Map();
  const stmt = (sql) => {
    if (!q.has(sql)) q.set(sql, db.prepare(sql));
    return q.get(sql);
  };
  const all = (sql, ...args) => stmt(sql).all(...args);
  const get = (sql, ...args) => stmt(sql).get(...args);
  const run = (sql, ...args) => stmt(sql).run(...args);

  function nextSort(table, filterCol, filterVal) {
    const row = filterCol
      ? get(`SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM ${table} WHERE ${filterCol} = ?`, filterVal)
      : get(`SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM ${table}`);
    return row.n;
  }

  /* ----------------------------- projects ----------------------------- */

  function listProjects() {
    return all(`SELECT ${PROJECT_COLS} FROM projects ORDER BY status = 'archived', sort_order, created_at`);
  }

  function getProject(id) {
    const row = get(`SELECT ${PROJECT_COLS} FROM projects WHERE id = ?`, id);
    if (!row) throw new NotFoundError('项目不存在');
    return row;
  }

  function createProject(input = {}) {
    const name = text(input.name, '项目名称', { max: 80, required: true });
    const id = randomUUID();
    const createdAt = nowIso();
    const count = get('SELECT COUNT(*) AS n FROM projects').n;
    const chosen = color(input.color) ?? PALETTE[count % PALETTE.length];
    run(
      `INSERT INTO projects (id, name, color, description, status, sort_order, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      id,
      name,
      chosen,
      text(input.description, '描述', { max: 1000 }),
      oneOf(input.status, '项目状态', PROJECT_STATUSES, 'active'),
      nextSort('projects'),
      createdAt,
    );
    return getProject(id);
  }

  function updateProject(id, input = {}) {
    const current = getProject(id);
    const next = {
      name: input.name === undefined ? current.name : text(input.name, '项目名称', { max: 80, required: true }),
      color: input.color === undefined ? current.color : (color(input.color) ?? current.color),
      description: input.description === undefined ? current.description : text(input.description, '描述', { max: 1000 }),
      status: input.status === undefined ? current.status : oneOf(input.status, '项目状态', PROJECT_STATUSES, current.status),
      sortOrder: input.sortOrder === undefined ? current.sortOrder : Math.round(Number(input.sortOrder) || 0),
      archivedAt: input.status === 'archived' && current.status !== 'archived'
        ? nowIso()
        : (input.status && input.status !== 'archived' ? null : current.archivedAt),
    };
    run(
      `UPDATE projects SET name = ?, color = ?, description = ?, status = ?, sort_order = ?, archived_at = ?
       WHERE id = ?`,
      next.name, next.color, next.description, next.status, next.sortOrder, next.archivedAt, id,
    );
    return getProject(id);
  }

  function deleteProject(id) {
    getProject(id);
    run('DELETE FROM projects WHERE id = ?', id);
    return { ok: true };
  }

  /* ------------------------------ tasks ------------------------------- */

  function listTasks() {
    return all(`SELECT ${TASK_COLS} FROM tasks ORDER BY sort_order, created_at`);
  }

  function getTask(id) {
    const row = get(`SELECT ${TASK_COLS} FROM tasks WHERE id = ?`, id);
    if (!row) throw new NotFoundError('任务不存在');
    return row;
  }

  function normalizeTask(input, current = null) {
    const status = input.status === undefined
      ? (current ? current.status : 'todo')
      : oneOf(input.status, '任务状态', TASK_STATUSES, 'todo');
    const startAt = input.startAt === undefined
      ? (current ? current.startAt : null)
      : cleanDateTime(input.startAt, '开始时间');
    const durationHint = intOrNull(input.estimateMin, '预计时长', { min: 1, max: 60 * 24 });
    let endAt = input.endAt === undefined
      ? (current ? current.endAt : null)
      : cleanDateTime(input.endAt, '结束时间');

    // Keep start/end coherent when possible.
    if (startAt && endAt && endAt <= startAt) endAt = null;
    if (startAt && !endAt) {
      const minutes = durationHint ?? (current?.estimateMin ?? 60);
      endAt = addMinutes(startAt, minutes);
    }
    if (!startAt) endAt = null;

    return {
      projectId: input.projectId === undefined
        ? (current ? current.projectId : null)
        : (input.projectId ? text(input.projectId, '项目', { max: 64, required: true }) : null),
      title: input.title === undefined ? (current ? current.title : '') : text(input.title, '任务标题', { max: 200, required: true }),
      notes: input.notes === undefined ? (current?.notes ?? '') : text(input.notes, '备注', { max: 5000 }),
      status,
      priority: input.priority === undefined
        ? (current ? current.priority : 'normal')
        : oneOf(input.priority, '优先级', PRIORITIES, 'normal'),
      estimateMin: input.estimateMin === undefined
        ? (current ? current.estimateMin : null)
        : intOrNull(input.estimateMin, '预计时长', { min: 1, max: 60 * 24 }),
      dueDate: input.dueDate === undefined
        ? (current ? current.dueDate : null)
        : cleanDate(input.dueDate, '截止日期'),
      startAt,
      endAt,
      completedAt: status === 'done'
        ? (current?.completedAt ?? nowIso())
        : null,
    };
  }

  function createTask(input = {}) {
    const data = normalizeTask(input);
    if (!data.title) throw new ValidationError('任务标题不能为空');
    if (data.projectId && !get('SELECT 1 AS ok FROM projects WHERE id = ?', data.projectId)) {
      throw new ValidationError('指定的项目不存在');
    }
    const id = randomUUID();
    const ts = nowIso();
    run(
      `INSERT INTO tasks (id, project_id, title, notes, status, priority, estimate_min, due_date,
        start_at, end_at, completed_at, created_at, updated_at, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id, data.projectId, data.title, data.notes, data.status, data.priority, data.estimateMin,
      data.dueDate, data.startAt, data.endAt, data.completedAt, ts, ts, nextSort('tasks'),
    );

    if (Array.isArray(input.subtasks)) {
      input.subtasks.forEach((s, i) => {
        const title = text(s?.title ?? s, '子任务', { max: 200, required: true });
        run(
          'INSERT INTO subtasks (id, task_id, title, done, sort_order) VALUES (?, ?, ?, ?, ?)',
          randomUUID(), id, title, s?.done ? 1 : 0, i,
        );
      });
    }
    return getTask(id);
  }

  function updateTask(id, input = {}) {
    const current = getTask(id);
    const data = normalizeTask(input, current);
    if (data.projectId && !get('SELECT 1 AS ok FROM projects WHERE id = ?', data.projectId)) {
      throw new ValidationError('指定的项目不存在');
    }
    // If only the estimate changed, stretch the block length to match it.
    if (input.estimateMin !== undefined && input.startAt === undefined && data.startAt && data.estimateMin) {
      data.endAt = addMinutes(data.startAt, data.estimateMin);
    }
    run(
      `UPDATE tasks SET project_id = ?, title = ?, notes = ?, status = ?, priority = ?,
        estimate_min = ?, due_date = ?, start_at = ?, end_at = ?, completed_at = ?, updated_at = ?
       WHERE id = ?`,
      data.projectId, data.title, data.notes, data.status, data.priority, data.estimateMin,
      data.dueDate, data.startAt, data.endAt, data.completedAt, nowIso(), id,
    );
    return getTask(id);
  }

  function deleteTask(id) {
    getTask(id);
    run('DELETE FROM tasks WHERE id = ?', id);
    return { ok: true };
  }

  function reorderTasks(ids) {
    if (!Array.isArray(ids)) throw new ValidationError('排序数据格式错误');
    const ts = nowIso();
    ids.forEach((id, index) => {
      run('UPDATE tasks SET sort_order = ?, updated_at = ? WHERE id = ?', index, ts, String(id));
    });
    return listTasks();
  }

  /* ----------------------------- subtasks ----------------------------- */

  function listSubtasks() {
    return all(`SELECT ${SUBTASK_COLS} FROM subtasks ORDER BY sort_order, rowid`);
  }

  function createSubtask(taskId, input = {}) {
    getTask(taskId);
    const id = randomUUID();
    run(
      'INSERT INTO subtasks (id, task_id, title, done, sort_order) VALUES (?, ?, ?, ?, ?)',
      id, taskId, text(input.title, '子任务', { max: 200, required: true }), input.done ? 1 : 0,
      nextSort('subtasks', 'task_id', taskId),
    );
    return get(`SELECT ${SUBTASK_COLS} FROM subtasks WHERE id = ?`, id);
  }

  function updateSubtask(id, input = {}) {
    const current = get('SELECT * FROM subtasks WHERE id = ?', id);
    if (!current) throw new NotFoundError('子任务不存在');
    const title = input.title === undefined ? current.title : text(input.title, '子任务', { max: 200, required: true });
    const done = input.done === undefined ? current.done : (input.done ? 1 : 0);
    run('UPDATE subtasks SET title = ?, done = ? WHERE id = ?', title, done, id);
    return get(`SELECT ${SUBTASK_COLS} FROM subtasks WHERE id = ?`, id);
  }

  function deleteSubtask(id) {
    const row = get('SELECT id FROM subtasks WHERE id = ?', id);
    if (!row) throw new NotFoundError('子任务不存在');
    run('DELETE FROM subtasks WHERE id = ?', id);
    return { ok: true };
  }

  /* ---------------------------- time tracking ------------------------- */

  function listEntries() {
    return all(`SELECT ${ENTRY_COLS} FROM time_entries ORDER BY started_at DESC`);
  }

  function runningEntry() {
    return get(`SELECT ${ENTRY_COLS} FROM time_entries WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1`) ?? null;
  }

  function startTimer(taskId, at = null) {
    getTask(taskId);
    const startedAt = at ? isoOrNull(at, '开始时间') : nowIso();
    run(
      'UPDATE time_entries SET ended_at = ?, minutes = ? WHERE ended_at IS NULL',
      nowIso(),
      Math.max(1, Math.round((Date.now() - new Date(startedAt).getTime()) / 60000)),
    );
    const id = randomUUID();
    run('INSERT INTO time_entries (id, task_id, started_at) VALUES (?, ?, ?)', id, taskId, startedAt);
    return get(`SELECT ${ENTRY_COLS} FROM time_entries WHERE id = ?`, id);
  }

  function stopTimer(at = null) {
    const running = runningEntry();
    if (!running) return null;
    const endedAt = at ? isoOrNull(at, '结束时间') : nowIso();
    const minutes = Math.max(1, Math.round((new Date(endedAt).getTime() - new Date(running.startedAt).getTime()) / 60000));
    run('UPDATE time_entries SET ended_at = ?, minutes = ? WHERE id = ?', endedAt, minutes, running.id);
    return get(`SELECT ${ENTRY_COLS} FROM time_entries WHERE id = ?`, running.id);
  }

  function createEntry(input = {}) {
    const taskId = input.taskId ? text(input.taskId, '任务', { max: 64, required: true }) : null;
    if (taskId) getTask(taskId);
    if (!input.startedAt) throw new ValidationError('开始时间不能为空');
    const startedAt = isoOrNull(input.startedAt, '开始时间');
    const endedAt = input.endedAt ? isoOrNull(input.endedAt, '结束时间') : null;
    const minutes = input.minutes !== undefined && input.minutes !== null && input.minutes !== ''
      ? intOrNull(input.minutes, '时长', { min: 1, max: 60 * 24 })
      : (endedAt ? Math.max(1, Math.round((new Date(endedAt) - new Date(startedAt)) / 60000)) : null);
    const id = randomUUID();
    run(
      'INSERT INTO time_entries (id, task_id, started_at, ended_at, minutes, note) VALUES (?, ?, ?, ?, ?, ?)',
      id, taskId, startedAt, endedAt, minutes, text(input.note, '备注', { max: 500 }),
    );
    return get(`SELECT ${ENTRY_COLS} FROM time_entries WHERE id = ?`, id);
  }

  function updateEntry(id, input = {}) {
    const current = get('SELECT * FROM time_entries WHERE id = ?', id);
    if (!current) throw new NotFoundError('时间记录不存在');
    const minutes = input.minutes === undefined
      ? current.minutes
      : intOrNull(input.minutes, '时长', { min: 1, max: 60 * 24 });
    const note = input.note === undefined ? current.note : text(input.note, '备注', { max: 500 });
    run('UPDATE time_entries SET minutes = ?, note = ? WHERE id = ?', minutes, note, id);
    return get(`SELECT ${ENTRY_COLS} FROM time_entries WHERE id = ?`, id);
  }

  function deleteEntry(id) {
    if (!get('SELECT id FROM time_entries WHERE id = ?', id)) throw new NotFoundError('时间记录不存在');
    run('DELETE FROM time_entries WHERE id = ?', id);
    return { ok: true };
  }

  /* ------------------------------ settings ---------------------------- */

  const DEFAULT_SETTINGS = {
    weekStart: 1,
    dayStartHour: 7,
    dayEndHour: 23,
    theme: 'auto',
    focusMinutes: 25,
    dailyGoalMinutes: 240,
  };

  function listSettings() {
    const out = { ...DEFAULT_SETTINGS };
    for (const row of all('SELECT key, value FROM settings')) {
      try {
        out[row.key] = JSON.parse(row.value);
      } catch {
        out[row.key] = row.value;
      }
    }
    return out;
  }

  function updateSettings(patch = {}) {
    const allowed = Object.keys(DEFAULT_SETTINGS);
    for (const [key, value] of Object.entries(patch)) {
      if (!allowed.includes(key)) continue;
      if (key === 'weekStart') {
        if (![0, 1, 6].includes(Number(value))) throw new ValidationError('每周起始日无效');
      }
      if (key === 'dayStartHour' || key === 'dayEndHour') {
        const n = Number(value);
        if (!Number.isInteger(n) || n < 0 || n > 24) throw new ValidationError('时间范围无效');
      }
      if (key === 'theme' && !['light', 'dark', 'auto'].includes(value)) {
        throw new ValidationError('主题无效');
      }
      run(
        'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        key, JSON.stringify(value),
      );
    }
    return listSettings();
  }

  /* -------------------------------- state ----------------------------- */

  function snapshot() {
    return {
      projects: listProjects(),
      tasks: listTasks(),
      subtasks: listSubtasks(),
      entries: listEntries(),
      running: runningEntry(),
      settings: listSettings(),
      serverTime: nowIso(),
    };
  }

  function close() {
    db.close();
  }

  return {
    raw: db,
    snapshot,
    close,
    listProjects, getProject, createProject, updateProject, deleteProject,
    listTasks, getTask, createTask, updateTask, deleteTask, reorderTasks,
    listSubtasks, createSubtask, updateSubtask, deleteSubtask,
    listEntries, runningEntry, startTimer, stopTimer, createEntry, updateEntry, deleteEntry,
    listSettings, updateSettings,
  };
}

const pad = (n) => String(n).padStart(2, '0');

/** Add minutes to a naive local datetime string (`YYYY-MM-DDTHH:MM:SS`). */
export function addMinutes(datetime, minutes) {
  const [datePart, timePart = '00:00:00'] = datetime.split('T');
  const [y, m, d] = datePart.split('-').map(Number);
  const [hh, mm] = timePart.split(':').map(Number);
  const base = new Date(y, m - 1, d, hh, mm, 0, 0);
  base.setMinutes(base.getMinutes() + minutes);
  return `${base.getFullYear()}-${pad(base.getMonth() + 1)}-${pad(base.getDate())}T${pad(base.getHours())}:${pad(base.getMinutes())}:00`;
}
