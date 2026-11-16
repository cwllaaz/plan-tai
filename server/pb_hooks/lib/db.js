// 数据访问层：业务表的读写、变更日志追加、操作去重表。
// 表名/列名全部来自本文件的常量，用户输入只以命名参数绑定，不拼接 SQL。

const util = require("./util.js")

const PROTOCOL_VERSION = "1"
const SCHEMA_VERSION = "1"

const ENTITIES = {
  project: {
    table: "pa_projects",
    select:
      "json_object('id', id, 'name', name, 'description', description, 'color', color," +
      " 'status', status, 'sortOrder', sort_order, 'createdAt', created_at," +
      " 'updatedAt', updated_at, 'revision', revision, 'deletedAt', deleted_at) AS data",
    toColumns: function (p) {
      return {
        name: p.name,
        description: p.description,
        color: p.color,
        status: p.status,
        sort_order: p.sortOrder,
      }
    },
    normalize: function (raw) {
      return raw
    },
  },
  span: {
    table: "pa_spans",
    select:
      "json_object('id', id, 'projectId', project_id, 'title', title, 'startDate', start_date," +
      " 'endDate', end_date, 'status', status, 'description', description, 'color', color," +
      " 'sortOrder', sort_order, 'createdAt', created_at, 'updatedAt', updated_at," +
      " 'revision', revision, 'deletedAt', deleted_at) AS data",
    toColumns: function (p) {
      return {
        project_id: p.projectId,
        title: p.title,
        start_date: p.startDate,
        end_date: p.endDate,
        status: p.status,
        description: p.description,
        color: p.color,
        sort_order: p.sortOrder,
      }
    },
    normalize: function (raw) {
      return raw
    },
  },
  task: {
    table: "pa_tasks",
    select:
      "json_object('id', id, 'projectId', project_id, 'spanId', span_id, 'title', title," +
      " 'notes', notes, 'scheduledDate', scheduled_date, 'timeStart', time_start," +
      " 'timeDuration', time_duration, 'priority', priority, 'status', status," +
      " 'completedAt', completed_at, 'sortOrder', sort_order, 'createdAt', created_at," +
      " 'updatedAt', updated_at, 'revision', revision, 'deletedAt', deleted_at) AS data",
    toColumns: function (p) {
      const slot = p.timeSlot
      return {
        project_id: p.projectId,
        span_id: p.spanId,
        title: p.title,
        notes: p.notes,
        scheduled_date: p.scheduledDate,
        time_start: slot ? slot.startMinute : null,
        time_duration: slot ? slot.durationMinutes : null,
        priority: p.priority,
        status: p.status,
        completed_at: p.completedAt,
        sort_order: p.sortOrder,
      }
    },
    normalize: function (raw) {
      const out = {
        id: raw.id,
        projectId: raw.projectId,
        spanId: raw.spanId,
        title: raw.title,
        notes: raw.notes,
        scheduledDate: raw.scheduledDate,
        timeSlot: null,
        priority: raw.priority,
        status: raw.status,
        completedAt: raw.completedAt,
        sortOrder: raw.sortOrder,
        createdAt: raw.createdAt,
        updatedAt: raw.updatedAt,
        revision: raw.revision,
        deletedAt: raw.deletedAt,
      }
      if (raw.timeStart !== null && raw.timeStart !== undefined) {
        out.timeSlot = {
          startMinute: raw.timeStart,
          durationMinutes: raw.timeDuration,
        }
      }
      return out
    },
  },
  note: {
    table: "pa_notes",
    select:
      "json_object('id', id, 'date', date, 'body', body, 'focusRaw', focus_items," +
      " 'createdAt', created_at, 'updatedAt', updated_at, 'revision', revision," +
      " 'deletedAt', deleted_at) AS data",
    toColumns: function (p) {
      return {
        date: p.date,
        body: p.body,
        focus_items: JSON.stringify(p.focusItems),
      }
    },
    normalize: function (raw) {
      const out = {
        id: raw.id,
        date: raw.date,
        body: raw.body,
        focusItems: util.parseJson(raw.focusRaw, []),
        createdAt: raw.createdAt,
        updatedAt: raw.updatedAt,
        revision: raw.revision,
        deletedAt: raw.deletedAt,
      }
      return out
    },
  },
}

function rowsFrom(app, sql, params) {
  const holder = arrayOf(new DynamicModel({ data: "" }))
  app.db().newQuery(sql).bind(params).all(holder)
  const out = []
  for (let i = 0; i < holder.length; i++) {
    out.push(JSON.parse(holder[i].data))
  }
  return out
}

function entityOf(name) {
  const desc = ENTITIES[name]
  if (!desc) {
    util.fail("invalid_entity", "不支持的实体类型: " + name, "entity")
  }
  return desc
}

function selectEntity(app, entityName, owner, id) {
  const desc = entityOf(entityName)
  const rows = rowsFrom(
    app,
    "SELECT " + desc.select + " FROM " + desc.table + " WHERE owner={:owner} AND id={:id} LIMIT 1",
    { owner: owner, id: id }
  )
  if (rows.length === 0) return null
  return desc.normalize(rows[0])
}

function countByOwner(app, table, owner) {
  const holder = arrayOf(new DynamicModel({ n: 0 }))
  app.db().newQuery("SELECT count(*) AS n FROM " + table + " WHERE owner={:owner}").bind({ owner: owner }).all(holder)
  if (holder.length === 0) return 0
  return holder[0].n
}

function insertEntity(txApp, entityName, owner, payload, revision, createdAt, updatedAt) {
  const desc = entityOf(entityName)
  const row = desc.toColumns(payload)
  row.owner = owner
  row.id = payload.id
  row.created_at = createdAt
  row.updated_at = updatedAt
  row.revision = revision
  row.deleted_at = null

  const cols = Object.keys(row)
  const placeholders = []
  const params = {}
  for (let i = 0; i < cols.length; i++) {
    placeholders.push("{:" + cols[i] + "}")
    const v = row[cols[i]]
    params[cols[i]] = v === undefined ? null : v
  }
  txApp
    .db()
    .newQuery(
      "INSERT INTO " + desc.table + " (" + cols.join(", ") + ") VALUES (" + placeholders.join(", ") + ")"
    )
    .bind(params)
    .execute()
}

function updateEntity(txApp, entityName, owner, payload, revision, updatedAt) {
  const desc = entityOf(entityName)
  const row = desc.toColumns(payload)
  row.updated_at = updatedAt
  row.revision = revision
  row.deleted_at = payload.deletedAt ? payload.deletedAt : null

  const cols = Object.keys(row)
  const sets = []
  const params = { owner: owner, id: payload.id }
  for (let i = 0; i < cols.length; i++) {
    sets.push(cols[i] + "={:" + cols[i] + "}")
    const v = row[cols[i]]
    params[cols[i]] = v === undefined ? null : v
  }
  txApp
    .db()
    .newQuery("UPDATE " + desc.table + " SET " + sets.join(", ") + " WHERE owner={:owner} AND id={:id}")
    .bind(params)
    .execute()
}

// 追加一条变更日志，返回分配的 seq（AUTOINCREMENT，事务内单调）。
function appendChange(txApp, change) {
  const params = {
    owner: change.owner,
    entity: change.entity,
    entity_id: change.entityId,
    op: change.op,
    revision: change.revision,
    payload: JSON.stringify(change.payload),
    device_id: change.deviceId || "",
    client_updated_at: change.clientUpdatedAt ? change.clientUpdatedAt : null,
    server_time: change.serverTime,
    op_id: change.opId,
  }
  txApp
    .db()
    .newQuery(
      "INSERT INTO pa_changes (owner, entity, entity_id, op, revision, payload, device_id," +
        " client_updated_at, server_time, op_id)" +
        " VALUES ({:owner}, {:entity}, {:entity_id}, {:op}, {:revision}, {:payload}," +
        " {:device_id}, {:client_updated_at}, {:server_time}, {:op_id})"
    )
    .bind(params)
    .execute()

  const holder = arrayOf(new DynamicModel({ seq: 0 }))
  txApp.db().newQuery("SELECT last_insert_rowid() AS seq").all(holder)
  return holder[0].seq
}

// 已处理过的 opId（幂等去重）。返回 null 表示首次提交。
function findProcessedOp(app, owner, opId) {
  const rows = rowsFrom(
    app,
    "SELECT json_object('opId', op_id, 'entity', entity, 'entityId', entity_id," +
      " 'status', status, 'code', code, 'message', message," +
      " 'serverRevision', server_revision, 'serverSeq', server_seq) AS data" +
      " FROM pa_ops WHERE owner={:owner} AND op_id={:opId} LIMIT 1",
    { owner: owner, opId: opId }
  )
  if (rows.length === 0) return null
  return rows[0]
}

function saveProcessedOp(txApp, owner, result) {
  txApp
    .db()
    .newQuery(
      "INSERT INTO pa_ops (owner, op_id, entity, entity_id, status, code, message," +
        " server_revision, server_seq, created_at)" +
        " VALUES ({:owner}, {:op_id}, {:entity}, {:entity_id}, {:status}, {:code}, {:message}," +
        " {:server_revision}, {:server_seq}, {:created_at})"
    )
    .bind({
      owner: owner,
      op_id: result.opId,
      entity: result.entity,
      entity_id: result.entityId,
      status: result.status,
      code: result.code || "",
      message: result.message || "",
      server_revision: result.serverRevision === undefined ? null : result.serverRevision,
      server_seq: result.serverSeq === undefined ? null : result.serverSeq,
      created_at: util.nowIso(),
    })
    .execute()
}

function maxSeqForOwner(app, owner) {
  const holder = arrayOf(new DynamicModel({ n: 0 }))
  app
    .db()
    .newQuery("SELECT COALESCE(MAX(seq), 0) AS n FROM pa_changes WHERE owner={:owner}")
    .bind({ owner: owner })
    .all(holder)
  if (holder.length === 0) return 0
  return holder[0].n
}

function globalMaxSeq(app) {
  const holder = arrayOf(new DynamicModel({ n: 0 }))
  app.db().newQuery("SELECT COALESCE(MAX(seq), 0) AS n FROM pa_changes").all(holder)
  if (holder.length === 0) return 0
  return holder[0].n
}

function readMeta(app, key, fallback) {
  const rows = rowsFrom(app, "SELECT json_object('v', value) AS data FROM pa_schema WHERE key={:key}", {
    key: key,
  })
  if (rows.length === 0) return fallback
  return rows[0].v
}

// ---------------------------------------------------------------------------
// 线上载荷（wire payload）
// ---------------------------------------------------------------------------
//
// 数据库里 task.priority 存 0-3、timeSlot 存 time_start/time_duration；
// 协议（docs/sync/DATA_CONTRACT.md §2）要求 priority 用
// low/normal/high/urgent、timeSlot 用对象。pull 输出前必须转换。
//
// 同时去掉本地/服务端管理字段（id/revision/updatedAt/deletedAt），
// 这些由外层 changes[] 提供，避免客户端误用服务端 revision。

const PRIORITY_NAMES = ["low", "normal", "high", "urgent"]
const PRIORITY_INDEX = { low: 0, normal: 1, high: 2, urgent: 3 }

function priorityName(level) {
  if (level === null || level === undefined) return "normal"
  const name = PRIORITY_NAMES[level]
  return name === undefined ? "normal" : name
}

function priorityIndex(name) {
  if (!util.isString(name)) return null
  const level = PRIORITY_INDEX[name]
  return level === undefined ? null : level
}

function wirePayload(entityName, snapshot) {
  if (!snapshot) return null
  const out = {
    createdAt: snapshot.createdAt,
  }
  if (entityName === "project") {
    out.name = snapshot.name
    out.description = snapshot.description
    out.color = snapshot.color
    out.status = snapshot.status
    out.sortOrder = snapshot.sortOrder
    return out
  }
  if (entityName === "span") {
    out.projectId = snapshot.projectId
    out.title = snapshot.title
    out.startDate = snapshot.startDate
    out.endDate = snapshot.endDate
    out.status = snapshot.status
    out.description = snapshot.description
    out.color = snapshot.color
    out.sortOrder = snapshot.sortOrder
    return out
  }
  if (entityName === "task") {
    out.projectId = snapshot.projectId
    out.spanId = snapshot.spanId
    out.title = snapshot.title
    out.notes = snapshot.notes
    out.scheduledDate = snapshot.scheduledDate
    out.timeSlot = snapshot.timeSlot === undefined ? null : snapshot.timeSlot
    out.priority = priorityName(snapshot.priority)
    out.status = snapshot.status
    out.completedAt = snapshot.completedAt
    out.sortOrder = snapshot.sortOrder
    return out
  }
  // note
  out.date = snapshot.date
  out.body = snapshot.body
  out.focusItems = snapshot.focusItems === undefined ? [] : snapshot.focusItems
  return out
}

function liveNoteForDate(app, owner, date, excludeId) {
  const rows = rowsFrom(
    app,
    "SELECT json_object('id', id) AS data FROM pa_notes" +
      " WHERE owner={:owner} AND date={:date} AND deleted_at IS NULL AND id != {:id} LIMIT 1",
    { owner: owner, date: date, id: excludeId || "" }
  )
  if (rows.length === 0) return null
  return selectEntity(app, "note", owner, rows[0].id)
}

// 读某项目下未删除的阶段/任务（级联删除用）。
function childrenOfProject(app, owner, projectId) {
  const spans = rowsFrom(
    app,
    "SELECT json_object('id', id) AS data FROM pa_spans" +
      " WHERE owner={:owner} AND project_id={:projectId} AND deleted_at IS NULL",
    { owner: owner, projectId: projectId }
  )
  const tasks = rowsFrom(
    app,
    "SELECT json_object('id', id) AS data FROM pa_tasks" +
      " WHERE owner={:owner} AND project_id={:projectId} AND deleted_at IS NULL",
    { owner: owner, projectId: projectId }
  )
  return { spans: spans, tasks: tasks }
}

// 读某阶段下未删除的任务（解绑用）。
function tasksOfSpan(app, owner, spanId) {
  return rowsFrom(
    app,
    "SELECT json_object('id', id) AS data FROM pa_tasks" +
      " WHERE owner={:owner} AND span_id={:spanId} AND deleted_at IS NULL",
    { owner: owner, spanId: spanId }
  )
}

module.exports = {
  PROTOCOL_VERSION: PROTOCOL_VERSION,
  SCHEMA_VERSION: SCHEMA_VERSION,
  ENTITIES: ENTITIES,
  PRIORITY_NAMES: PRIORITY_NAMES,
  priorityName: priorityName,
  priorityIndex: priorityIndex,
  rowsFrom: rowsFrom,
  selectEntity: selectEntity,
  countByOwner: countByOwner,
  insertEntity: insertEntity,
  updateEntity: updateEntity,
  appendChange: appendChange,
  findProcessedOp: findProcessedOp,
  saveProcessedOp: saveProcessedOp,
  maxSeqForOwner: maxSeqForOwner,
  globalMaxSeq: globalMaxSeq,
  readMeta: readMeta,
  wirePayload: wirePayload,
  liveNoteForDate: liveNoteForDate,
  childrenOfProject: childrenOfProject,
  tasksOfSpan: tasksOfSpan,
}
