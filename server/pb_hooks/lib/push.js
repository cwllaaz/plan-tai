// push 业务逻辑（CJS 模块）。
//
// 协议：docs/sync/API_CONTRACT.md §4（POST /api/planner/sync/push）。
// 要点：
//  - 整批 ops 在一个事务内处理；单条 conflict/rejected 不回滚已成功项；
//  - 以 opId 幂等，只缓存 applied 结果（冲突/拒绝重试时重新判定）；
//  - 响应 results 与请求 ops 一一对应、顺序相同；
//  - 级联删除（project→span/task、span 解绑 task）写入变更日志，供 pull 获取。

const util = require("./util.js")
const db = require("./db.js")
const validate = require("./validate.js")

const MAX_OPS = 100

function isSyncError(err) {
  return err !== null && err !== undefined && err.name === "SyncError" && util.isString(err.code)
}

// 游标是不透明字符串：c1_<16 位十进制序号>。客户端只比较/回传，不解析。
function cursorOf(seq) {
  if (seq === null || seq === undefined) return null
  return "c1_" + String(seq).padStart(16, "0")
}

function baseOf(env) {
  return { opId: env.opId, entityType: env.entity, entityId: env.entityId }
}

function rejected(env, code, message, retryable) {
  const result = baseOf(env)
  result.status = "rejected"
  result.error = {
    code: code,
    message: message,
    retryable: retryable === true,
  }
  return result
}

function applied(env, revision, seq, noOp, now) {
  const result = baseOf(env)
  result.status = "applied"
  result.noOp = noOp === true
  result.serverRevision = revision
  result.serverCursor = cursorOf(seq)
  result.appliedAt = now
  return result
}

function conflict(env, kind, current, now, extra) {
  const result = baseOf(env)
  result.status = "conflict"
  result.serverRevision = current ? current.revision : 0
  result.serverCursor = null
  const currentPayload =
    current && !current.deletedAt ? db.wirePayload(env.entity, current) : null
  result.conflict = {
    kind: kind,
    serverRevision: current ? current.revision : 0,
    serverDeleted: current ? !!current.deletedAt : false,
    serverPayload: currentPayload,
    serverUpdatedAt: current ? current.updatedAt : null,
    serverUpdatedByDevice: null,
    serverCursor: null,
  }
  if (extra) {
    for (const key in extra) result.conflict[key] = extra[key]
  }
  void now
  return result
}

// ---------------------------------------------------------------------------
// 请求/操作校验
// ---------------------------------------------------------------------------

function parseEnvelope(raw) {
  if (!util.isPlainObject(raw)) {
    util.fail("INVALID_ENVELOPE", "每个操作必须是 JSON 对象", "ops")
  }
  const opId = raw.opId
  if (!util.isString(opId) || !util.TOKEN_ID_RE.test(opId)) {
    util.fail("INVALID_ENVELOPE", "opId 必须是 1-64 位字母、数字或 . _ : -", "opId")
  }
  const entityType = raw.entityType
  if (!util.isString(entityType) || !db.ENTITIES[entityType]) {
    util.fail("INVALID_ENTITY_TYPE", "entityType 只能是 project / span / task / note", "entityType")
  }
  const entityId = raw.entityId
  if (!util.isUuidV7(entityId)) {
    util.fail("INVALID_ENVELOPE", "entityId 必须是 UUIDv7（小写）", "entityId")
  }
  const opType = raw.opType
  if (opType !== "create" && opType !== "update" && opType !== "delete") {
    util.fail("INVALID_OP_TYPE", "opType 只能是 create / update / delete", "opType")
  }
  const baseRevision = raw.baseRevision
  if (!util.isInt(baseRevision) || baseRevision < 0) {
    util.fail("INVALID_BASE_REVISION", "baseRevision 必须是 ≥ 0 的整数", "baseRevision")
  }
  if (opType === "create" && baseRevision !== 0) {
    util.fail("INVALID_BASE_REVISION", "create 的 baseRevision 必须为 0", "baseRevision")
  }
  if (opType !== "create" && baseRevision < 1) {
    util.fail("INVALID_BASE_REVISION", "update/delete 必须携带已知的 baseRevision（≥ 1）", "baseRevision")
  }

  let payload = raw.payload
  if (payload === undefined || payload === null) payload = {}
  if (!util.isPlainObject(payload)) {
    util.fail("INVALID_ENVELOPE", "payload 必须是 JSON 对象", "payload")
  }

  let clientUpdatedAt = null
  if (util.isIsoUtc(raw.clientUpdatedAt)) {
    clientUpdatedAt = new Date(Date.parse(raw.clientUpdatedAt))
      .toISOString()
      .replace(/\.\d+Z$/, "Z")
  }

  return {
    opId: opId,
    entity: entityType,
    entityId: entityId,
    opType: opType,
    baseRevision: baseRevision,
    payload: payload,
    clientUpdatedAt: clientUpdatedAt,
  }
}

function resolveCreatedAt(rawPayload, now) {
  const v = rawPayload.createdAt
  if (!util.isIsoUtc(v)) return now
  const t = Date.parse(v)
  const nowMs = Date.parse(now)
  // 允许少量时钟偏差，但不接受未来时间，保证 createdAt ≤ updatedAt
  if (t > nowMs + 5 * 60 * 1000) return now
  return new Date(t).toISOString().replace(/\.\d+Z$/, "Z")
}

// ---------------------------------------------------------------------------
// 写库
// ---------------------------------------------------------------------------

function rememberApplied(txApp, owner, env, result) {
  db.saveProcessedOp(txApp, owner, {
    opId: env.opId,
    entity: env.entity,
    entityId: env.entityId,
    status: result.status,
    code: result.error ? result.error.code : "",
    message: result.error ? result.error.message : "",
    serverRevision: result.serverRevision,
    serverSeq: result.serverCursor
      ? parseInt(result.serverCursor.substring(3), 10)
      : null,
  })
}

function appendChangeFor(txApp, owner, entity, entityId, op, revision, snapshot, deviceId, clientUpdatedAt, now, opId) {
  return db.appendChange(txApp, {
    owner: owner,
    entity: entity,
    entityId: entityId,
    op: op,
    revision: revision,
    payload: snapshot,
    deviceId: deviceId,
    clientUpdatedAt: clientUpdatedAt,
    serverTime: now,
    opId: opId,
  })
}

function upsertEntity(txApp, owner, deviceId, env, current, now) {
  const ctx = { tx: txApp, owner: owner, now: now }
  const isCreate = env.opType === "create"

  if (isCreate) {
    if (current && !current.deletedAt) {
      return conflict(env, "CREATE_EXISTS", current, now)
    }
    // 已删除的实体不允许用 create 复活；恢复必须走 update 并解除墓碑。
    if (current && current.deletedAt) {
      return rejected(env, "ENTITY_DELETED", "该记录已在云端删除，不能重新创建", false)
    }
  } else {
    if (!current) {
      return rejected(env, "ENTITY_NOT_FOUND", "服务端没有该记录，无法更新", false)
    }
    if (current.deletedAt) {
      return conflict(env, "UPDATE_DELETE", current, now)
    }
    if (current.revision !== env.baseRevision) {
      return conflict(env, "UPDATE_UPDATE", current, now)
    }
  }

  let fields
  try {
    fields = validate.validateEntity(env.entity, env.payload, ctx)
  } catch (err) {
    if (!isSyncError(err)) throw err
    // 备注日期被占用是业务冲突，不是输入错误：交给用户解决。
    if (err.code === "note_date_taken") {
      const other = db.liveNoteForDate(txApp, owner, env.payload.date, env.entityId)
      return conflict(env, "NOTE_DATE_TAKEN", other, now)
    }
    return rejected(env, err.code.toUpperCase(), err.message, false)
  }

  if (env.entity === "note") {
    const other = db.liveNoteForDate(txApp, owner, fields.date, env.entityId)
    if (other) return conflict(env, "NOTE_DATE_TAKEN", other, now)
  }

  fields.id = env.entityId
  const createdAt = isCreate ? resolveCreatedAt(env.payload, now) : current.createdAt
  const revision = isCreate ? 1 : current.revision + 1
  const snapshot = Object.assign({}, fields, {
    createdAt: createdAt,
    updatedAt: now,
    revision: revision,
    deletedAt: null,
  })

  // update 且规范化后与当前完全相同：不新增版本、不追加游标。
  if (!isCreate) {
    const before = db.wirePayload(env.entity, current)
    const after = db.wirePayload(env.entity, snapshot)
    if (JSON.stringify(before) === JSON.stringify(after)) {
      const result = applied(env, current.revision, null, true, now)
      rememberApplied(txApp, owner, env, result)
      return result
    }
  }

  if (isCreate) {
    db.insertEntity(txApp, env.entity, owner, snapshot, revision, createdAt, now)
  } else {
    db.updateEntity(txApp, env.entity, owner, snapshot, revision, now)
  }
  const seq = appendChangeFor(
    txApp,
    owner,
    env.entity,
    env.entityId,
    "upsert",
    revision,
    snapshot,
    deviceId,
    env.clientUpdatedAt,
    now,
    env.opId
  )
  const result = applied(env, revision, seq, false, now)
  rememberApplied(txApp, owner, env, result)
  return result
}

function tombstone(txApp, owner, deviceId, entityName, current, now, opId) {
  const revision = current.revision + 1
  const snapshot = Object.assign({}, current, {
    revision: revision,
    updatedAt: now,
    deletedAt: now,
  })
  db.updateEntity(txApp, entityName, owner, snapshot, revision, now)
  return appendChangeFor(
    txApp,
    owner,
    entityName,
    current.id,
    "delete",
    revision,
    snapshot,
    deviceId,
    null,
    now,
    opId
  )
}

function applyDelete(txApp, owner, deviceId, env, current, now) {
  if (!current) {
    const result = applied(env, 0, null, true, now)
    rememberApplied(txApp, owner, env, result)
    return result
  }
  if (current.deletedAt) {
    const result = applied(env, current.revision, null, true, now)
    rememberApplied(txApp, owner, env, result)
    return result
  }
  if (current.revision !== env.baseRevision) {
    return conflict(env, "DELETE_UPDATE", current, now)
  }

  const seq = tombstone(txApp, owner, deviceId, env.entity, current, now, env.opId)

  // 级联：project 删除 span/task；span 删除时解绑 task（task 保留）。
  if (env.entity === "project") {
    const children = db.childrenOfProject(txApp, owner, env.entityId)
    for (let i = 0; i < children.spans.length; i++) {
      const span = db.selectEntity(txApp, "span", owner, children.spans[i].id)
      if (span && !span.deletedAt) {
        tombstone(txApp, owner, deviceId, "span", span, now, env.opId)
      }
    }
    for (let i = 0; i < children.tasks.length; i++) {
      const task = db.selectEntity(txApp, "task", owner, children.tasks[i].id)
      if (task && !task.deletedAt) {
        tombstone(txApp, owner, deviceId, "task", task, now, env.opId)
      }
    }
  } else if (env.entity === "span") {
    const tasks = db.tasksOfSpan(txApp, owner, env.entityId)
    for (let i = 0; i < tasks.length; i++) {
      const task = db.selectEntity(txApp, "task", owner, tasks[i].id)
      if (!task || task.deletedAt || task.spanId === null) continue
      const revision = task.revision + 1
      const next = Object.assign({}, task, {
        spanId: null,
        revision: revision,
        updatedAt: now,
      })
      db.updateEntity(txApp, "task", owner, next, revision, now)
      appendChangeFor(
        txApp,
        owner,
        "task",
        task.id,
        "upsert",
        revision,
        next,
        deviceId,
        null,
        now,
        env.opId
      )
    }
  }

  const result = applied(env, current.revision + 1, seq, false, now)
  rememberApplied(txApp, owner, env, result)
  return result
}

function applyOp(txApp, owner, deviceId, env, now) {
  const prior = db.findProcessedOp(txApp, owner, env.opId)
  if (prior) {
    const result = baseOf(env)
    result.status = "duplicate"
    result.noOp = true
    result.serverRevision = prior.serverRevision === null ? 0 : prior.serverRevision
    result.serverCursor = cursorOf(prior.serverSeq)
    result.duplicateOf = env.opId
    return result
  }

  const current = db.selectEntity(txApp, env.entity, owner, env.entityId)
  if (env.opType === "delete") {
    return applyDelete(txApp, owner, deviceId, env, current, now)
  }
  return upsertEntity(txApp, owner, deviceId, env, current, now)
}

function processOne(txApp, owner, deviceId, raw, now) {
  let env = null
  try {
    env = parseEnvelope(raw)
  } catch (err) {
    if (isSyncError(err)) {
      const result = baseOf({ opId: util.isPlainObject(raw) && util.isString(raw.opId) ? raw.opId : "", entity: "", entityId: "" })
      result.status = "rejected"
      result.error = { code: err.code, message: err.message, retryable: false }
      return result
    }
    throw err
  }
  try {
    return applyOp(txApp, owner, deviceId, env, now)
  } catch (err) {
    if (isSyncError(err)) {
      return rejected(env, err.code.toUpperCase(), err.message, false)
    }
    throw err
  }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

function handlePush(e) {
  const body = e.requestInfo().body
  const now = util.nowIso()

  if (!util.isPlainObject(body)) {
    return e.json(400, { code: "INVALID_JSON", message: "请求体必须是 JSON 对象", retryable: false })
  }
  const protocolVersion = body.protocolVersion
  if (protocolVersion !== undefined && protocolVersion !== null && protocolVersion !== 1) {
    return e.json(400, {
      code: "UNSUPPORTED_PROTOCOL",
      message: "不支持的 protocolVersion：" + protocolVersion + "（客户端需为 1）",
      retryable: false,
    })
  }
  const schemaVersion = body.schemaVersion
  if (schemaVersion !== undefined && schemaVersion !== null && (typeof schemaVersion !== "number" || schemaVersion > 1)) {
    return e.json(400, {
      code: "SCHEMA_TOO_NEW",
      message: "schemaVersion 高于服务端支持（1）",
      retryable: false,
    })
  }

  const deviceId = body.deviceId
  if (!util.isString(deviceId) || !util.TOKEN_ID_RE.test(deviceId)) {
    return e.json(400, {
      code: "INVALID_ENVELOPE",
      message: "deviceId 必须是 1-64 位字母、数字或 . _ : -",
      retryable: false,
    })
  }
  const owner = e.auth.id
  if (util.isString(body.ownerId) && body.ownerId !== owner) {
    return e.json(403, {
      code: "OWNER_MISMATCH",
      message: "请求体 ownerId 与登录账号不一致",
      retryable: false,
    })
  }

  const ops = body.ops
  if (!Array.isArray(ops)) {
    return e.json(400, { code: "INVALID_ENVELOPE", message: "ops 必须是数组", retryable: false })
  }
  if (ops.length === 0) {
    return e.json(400, { code: "INVALID_ENVELOPE", message: "ops 不能为空", retryable: false })
  }
  if (ops.length > MAX_OPS) {
    return e.json(400, {
      code: "TOO_MANY_OPS",
      message: "单次 push 最多 " + MAX_OPS + " 条操作，请分批提交",
      retryable: false,
    })
  }

  const results = []
  e.app.runInTransaction((txApp) => {
    for (let i = 0; i < ops.length; i++) {
      results.push(processOne(txApp, owner, deviceId, ops[i], now))
    }
  })

  return e.json(200, {
    protocolVersion: 1,
    schemaVersion: 1,
    ownerId: owner,
    serverTime: util.nowIso(),
    results: results,
  })
}

module.exports = {
  MAX_OPS: MAX_OPS,
  handlePush: handlePush,
}
