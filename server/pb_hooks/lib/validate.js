// 业务字段校验：把客户端 payload 规整成服务端存储形态。
// 所有长度/范围约束都对齐 docs/DATA_CONTRACT.md，超出即返回 invalid + 明确字段。

const util = require("./util.js")
const db = require("./db.js")

const PROJECT_STATUS = ["active", "paused", "archived"]
const SPAN_STATUS = ["planned", "doing", "done", "dropped"]
const TASK_STATUS = ["todo", "done"]

function readString(payload, field, opts) {
  opts = opts || {}
  let v = payload[field]
  if (v === undefined || v === null) {
    if (opts.required) util.fail("invalid_field", "缺少必填字段 " + field, field)
    return opts.default === undefined ? "" : opts.default
  }
  if (!util.isString(v)) util.fail("invalid_field", field + " 必须是字符串", field)
  if (opts.trim) v = v.trim()
  if (opts.min !== undefined && v.length < opts.min) {
    util.fail("invalid_field", field + " 长度不能小于 " + opts.min, field)
  }
  if (opts.max !== undefined && v.length > opts.max) {
    util.fail("invalid_field", field + " 长度不能超过 " + opts.max, field)
  }
  return v
}

function readNullableString(payload, field, opts) {
  opts = opts || {}
  const v = payload[field]
  if (v === undefined || v === null) return null
  if (!util.isString(v)) util.fail("invalid_field", field + " 必须是字符串或 null", field)
  if (opts.max !== undefined && v.length > opts.max) {
    util.fail("invalid_field", field + " 长度不能超过 " + opts.max, field)
  }
  return v
}

function readInt(payload, field, opts) {
  opts = opts || {}
  const v = payload[field]
  if (v === undefined || v === null) {
    if (opts.required) util.fail("invalid_field", "缺少必填字段 " + field, field)
    return opts.default === undefined ? 0 : opts.default
  }
  if (!util.isInt(v)) util.fail("invalid_field", field + " 必须是整数", field)
  if (opts.min !== undefined && v < opts.min) {
    util.fail("invalid_field", field + " 不能小于 " + opts.min, field)
  }
  if (opts.max !== undefined && v > opts.max) {
    util.fail("invalid_field", field + " 不能大于 " + opts.max, field)
  }
  return v
}

function readEnum(payload, field, allowed, def) {
  const v = payload[field]
  if (v === undefined || v === null) {
    if (def === undefined) util.fail("invalid_field", "缺少必填字段 " + field, field)
    return def
  }
  if (!util.isString(v) || allowed.indexOf(v) === -1) {
    util.fail("invalid_field", field + " 只能是 " + allowed.join(" / "), field)
  }
  return v
}

function readDate(payload, field, required) {
  const v = payload[field]
  if (v === undefined || v === null) {
    if (required) util.fail("invalid_field", "缺少日期字段 " + field, field)
    return null
  }
  if (!util.isDateStr(v)) {
    util.fail("invalid_field", field + " 必须是 YYYY-MM-DD", field)
  }
  return v
}

function readIso(payload, field, required) {
  const v = payload[field]
  if (v === undefined || v === null) {
    if (required) util.fail("invalid_field", "缺少时间字段 " + field, field)
    return null
  }
  if (!util.isIsoUtc(v)) {
    util.fail("invalid_field", field + " 必须是 UTC ISO8601（YYYY-MM-DDTHH:MM:SSZ）", field)
  }
  return new Date(Date.parse(v)).toISOString().replace(/\.\d+Z$/, "Z")
}

function readColor(payload, field, nullable) {
  const v = payload[field]
  if (v === undefined || v === null) {
    if (nullable) return null
    util.fail("invalid_field", "缺少颜色字段 " + field, field)
  }
  if (!util.isString(v) || !util.HEX_COLOR_RE.test(v.toUpperCase())) {
    util.fail("invalid_field", field + " 必须是 #RRGGBB", field)
  }
  return v.toUpperCase()
}

function readFocusItems(payload) {
  const v = payload.focusItems
  if (v === undefined || v === null) return []
  if (!Array.isArray(v)) util.fail("invalid_field", "focusItems 必须是字符串数组", "focusItems")
  const out = []
  for (let i = 0; i < v.length; i++) {
    if (!util.isString(v[i])) util.fail("invalid_field", "focusItems 只能包含字符串", "focusItems")
    const t = v[i].trim()
    if (t === "") continue
    if (t.length > 60) util.fail("invalid_field", "focusItems 单条不能超过 60 字", "focusItems")
    out.push(t)
  }
  if (out.length > 3) util.fail("invalid_field", "focusItems 最多 3 条", "focusItems")
  return out
}

function readTimeSlot(payload, scheduledDate) {
  const v = payload.timeSlot
  if (v === undefined || v === null) return null
  if (!util.isPlainObject(v)) util.fail("invalid_field", "timeSlot 必须是对象或 null", "timeSlot")
  const start = readInt(v, "startMinute", { required: true, min: 0, max: 1439 })
  const duration = readInt(v, "durationMinutes", { required: true, min: 1, max: 1440 })
  if (start + duration > 1440) {
    util.fail("invalid_field", "timeSlot 不能跨午夜（startMinute + durationMinutes ≤ 1440）", "timeSlot")
  }
  if (!scheduledDate) {
    util.fail("invalid_field", "timeSlot 必须配合 scheduledDate 使用", "timeSlot")
  }
  return { startMinute: start, durationMinutes: duration }
}

function ensureProject(txApp, owner, projectId) {
  if (!util.isUuidV7(projectId)) {
    util.fail("invalid_field", "projectId 必须是 UUIDv7", "projectId")
  }
  const project = db.selectEntity(txApp, "project", owner, projectId)
  if (!project || project.deletedAt) {
    util.fail("project_not_found", "项目不存在或无权访问", "projectId")
  }
  return project
}

function projectFrom(payload, ctx) {
  if (!util.isPlainObject(payload)) util.fail("invalid_payload", "payload 必须是 JSON 对象", "payload")
  return {
    name: readString(payload, "name", { required: true, trim: true, min: 1, max: 80 }),
    description: readString(payload, "description", { max: 2000 }),
    color: readColor(payload, "color", false),
    status: readEnum(payload, "status", PROJECT_STATUS, "active"),
    sortOrder: readInt(payload, "sortOrder", { default: 0 }),
  }
}

function spanFrom(payload, ctx) {
  if (!util.isPlainObject(payload)) util.fail("invalid_payload", "payload 必须是 JSON 对象", "payload")
  const projectId = readString(payload, "projectId", { required: true, max: 64 })
  ensureProject(ctx.tx, ctx.owner, projectId)

  const startDate = readDate(payload, "startDate", true)
  const endDate = readDate(payload, "endDate", true)
  if (endDate < startDate) util.fail("invalid_field", "endDate 不能早于 startDate", "endDate")
  if (util.daysBetween(startDate, endDate) > 366) {
    util.fail("invalid_field", "阶段最长 366 天", "endDate")
  }

  return {
    projectId: projectId,
    title: readString(payload, "title", { required: true, trim: true, min: 1, max: 120 }),
    startDate: startDate,
    endDate: endDate,
    status: readEnum(payload, "status", SPAN_STATUS, "planned"),
    description: readString(payload, "description", { max: 2000 }),
    color: readColor(payload, "color", true),
    sortOrder: readInt(payload, "sortOrder", { default: 0 }),
  }
}

function taskFrom(payload, ctx) {
  if (!util.isPlainObject(payload)) util.fail("invalid_payload", "payload 必须是 JSON 对象", "payload")

  let projectId = readNullableString(payload, "projectId", { max: 64 })
  let spanId = readNullableString(payload, "spanId", { max: 64 })

  if (projectId !== null) {
    ensureProject(ctx.tx, ctx.owner, projectId)
  }

  if (spanId !== null) {
    if (!util.isUuidV7(spanId)) util.fail("invalid_field", "spanId 必须是 UUIDv7", "spanId")
    if (!projectId) util.fail("invalid_field", "spanId 必须同时提供 projectId", "spanId")
    const span = db.selectEntity(ctx.tx, "span", ctx.owner, spanId)
    if (!span || span.deletedAt) {
      util.fail("span_not_found", "阶段不存在或无权访问", "spanId")
    }
    if (span.projectId !== projectId) {
      util.fail("invalid_field", "spanId 不属于指定项目", "spanId")
    }
  }

  const scheduledDate = readDate(payload, "scheduledDate", false)
  const timeSlot = readTimeSlot(payload, scheduledDate)

  const status = readEnum(payload, "status", TASK_STATUS, "todo")
  let completedAt = readIso(payload, "completedAt", false)
  if (status === "done") {
    if (!completedAt) completedAt = util.nowIso()
  } else {
    completedAt = null
  }

  return {
    projectId: projectId,
    spanId: spanId,
    title: readString(payload, "title", { required: true, trim: true, min: 1, max: 200 }),
    notes: readString(payload, "notes", { max: 5000 }),
    scheduledDate: scheduledDate,
    timeSlot: timeSlot,
    priority: readPriority(payload),
    status: status,
    completedAt: completedAt,
    sortOrder: readInt(payload, "sortOrder", { default: 0 }),
  }
}

// 协议里 priority 是 low/normal/high/urgent；兼容早期整数写法。
function readPriority(payload) {
  const v = payload.priority
  if (v === undefined || v === null) return db.priorityIndex("normal")
  if (util.isInt(v)) {
    if (v < 0 || v > 3) util.fail("invalid_field", "priority 只能是 low/normal/high/urgent", "priority")
    return v
  }
  const index = db.priorityIndex(v)
  if (index === null) {
    util.fail("invalid_field", "priority 只能是 low/normal/high/urgent", "priority")
  }
  return index
}

function noteFrom(payload, ctx) {
  if (!util.isPlainObject(payload)) util.fail("invalid_payload", "payload 必须是 JSON 对象", "payload")
  const date = readDate(payload, "date", true)
  return {
    date: date,
    body: readString(payload, "body", { max: 10000 }),
    focusItems: readFocusItems(payload),
  }
}

const VALIDATORS = {
  project: projectFrom,
  span: spanFrom,
  task: taskFrom,
  note: noteFrom,
}

function validateEntity(entityName, payload, ctx) {
  const fn = VALIDATORS[entityName]
  if (!fn) util.fail("invalid_entity", "不支持的实体类型: " + entityName, "entity")
  return fn(payload, ctx)
}

// 同一用户同一天只能有一条未删除备注。
function ensureNoteDateFree(txApp, owner, noteId, date) {
  const rows = db.rowsFrom(
    txApp,
    "SELECT json_object('id', id) AS data FROM pa_notes" +
      " WHERE owner={:owner} AND date={:date} AND deleted_at IS NULL AND id != {:id} LIMIT 1",
    { owner: owner, date: date, id: noteId }
  )
  if (rows.length > 0) {
    util.fail("note_date_taken", "该日期已有备注（id=" + rows[0].id + "），请先拉取再用同一 id 更新", "date")
  }
}

module.exports = {
  validateEntity: validateEntity,
  ensureNoteDateFree: ensureNoteDateFree,
  readFocusItems: readFocusItems,
}
