// pull 业务逻辑（CJS 模块）。
//
// 协议：docs/sync/API_CONTRACT.md §5（POST /api/planner/sync/pull）。
// 游标为不透明字符串 c1_<16 位序号>；快照与增量共用同一变更日志，
// 因此 pull 天然只读、不会写游标/日志。

const util = require("./util.js")
const db = require("./db.js")

const MAX_LIMIT = 500
const DEFAULT_LIMIT = 200
const CURSOR_RE = /^c1_(\d{1,16})$/

function parseCursor(raw) {
  if (raw === undefined || raw === null) return 0
  if (!util.isString(raw) || !CURSOR_RE.test(raw)) return null
  const n = parseInt(CURSOR_RE.exec(raw)[1], 10)
  return isNaN(n) ? null : n
}

function cursorOf(seq) {
  return "c1_" + String(seq).padStart(16, "0")
}

function invalid(e, status, code, message) {
  return e.json(status, { code: code, message: message, retryable: false })
}

function parseRow(row) {
  const payload = util.parseJson(row.payload, null)
  return { row: row, payload: payload }
}

function handlePull(e) {
  const body = e.requestInfo().body
  if (!util.isPlainObject(body)) {
    return invalid(e, 400, "INVALID_JSON", "请求体必须是 JSON 对象")
  }
  const protocolVersion = body.protocolVersion
  if (protocolVersion !== undefined && protocolVersion !== null && protocolVersion !== 1) {
    return invalid(e, 400, "UNSUPPORTED_PROTOCOL", "不支持的 protocolVersion：" + protocolVersion)
  }
  const schemaVersion = body.schemaVersion
  if (
    schemaVersion !== undefined &&
    schemaVersion !== null &&
    (typeof schemaVersion !== "number" || schemaVersion > 1)
  ) {
    return invalid(e, 400, "SCHEMA_TOO_NEW", "schemaVersion 高于服务端支持（1）")
  }

  const mode = body.mode === undefined || body.mode === null ? "incremental" : body.mode
  if (mode !== "incremental" && mode !== "snapshot") {
    return invalid(e, 400, "INVALID_ENVELOPE", "mode 只能是 incremental / snapshot")
  }

  let limit = DEFAULT_LIMIT
  if (body.limit !== undefined && body.limit !== null) {
    if (!util.isInt(body.limit) || body.limit < 1 || body.limit > MAX_LIMIT) {
      return invalid(e, 400, "INVALID_ENVELOPE", "limit 必须在 1-" + MAX_LIMIT + " 之间")
    }
    limit = body.limit
  }

  const cursor = parseCursor(body.cursor)
  if (cursor === null) {
    return invalid(e, 409, "CURSOR_INVALID", "cursor 必须是 c1_<序号> 格式")
  }

  const owner = e.auth.id
  const maxSeq = db.maxSeqForOwner(e.app, owner)
  if (cursor > maxSeq) {
    return invalid(
      e,
      409,
      "CURSOR_INVALID",
      "cursor " + cursor + " 超出服务端最大序号 " + maxSeq + "，请重新做全量对账"
    )
  }

  let snapshotSeq = null
  if (mode === "snapshot") {
    if (body.snapshotSeq !== undefined && body.snapshotSeq !== null) {
      if (!util.isInt(body.snapshotSeq) || body.snapshotSeq < 0) {
        return invalid(e, 400, "INVALID_ENVELOPE", "snapshotSeq 必须是 ≥ 0 的整数")
      }
      snapshotSeq = body.snapshotSeq
      if (snapshotSeq > maxSeq) {
        return invalid(
          e,
          409,
          "CURSOR_INVALID",
          "snapshotSeq " + snapshotSeq + " 超出服务端最大序号 " + maxSeq
        )
      }
    } else {
      // 首次快照页：服务端确定快照边界。
      snapshotSeq = maxSeq
    }
  }

  const params = { owner: owner, cursor: cursor, take: limit + 1 }
  let sql =
    "SELECT json_object('seq', seq, 'entity', entity, 'entityId', entity_id, 'op', op," +
    " 'revision', revision, 'payload', payload, 'deviceId', device_id," +
    " 'serverTime', server_time, 'opId', op_id) AS data" +
    " FROM pa_changes WHERE owner={:owner} AND seq > {:cursor}"

  if (mode === "snapshot") {
    sql += " AND seq <= {:snapshotSeq}"
    params.snapshotSeq = snapshotSeq
  }

  sql += " ORDER BY seq ASC LIMIT {:take}"

  const rows = db.rowsFrom(e.app, sql, params)
  const hasMore = rows.length > limit
  const page = hasMore ? rows.slice(0, limit) : rows

  const changes = []
  for (let i = 0; i < page.length; i++) {
    const parsed = parseRow(page[i])
    const row = parsed.row
    const deleted = row.op === "delete"
    const rawPayload = parsed.payload
    changes.push({
      entityType: row.entity,
      entityId: row.entityId,
      schemaVersion: 1,
      ownerId: owner,
      serverRevision: row.revision,
      serverCursor: cursorOf(row.seq),
      deleted: deleted,
      deletedAt: deleted && rawPayload ? rawPayload.deletedAt : null,
      payload: deleted ? null : db.wirePayload(row.entity, rawPayload),
      serverUpdatedAt: row.serverTime,
      updatedByDevice: row.deviceId === "" ? null : row.deviceId,
      lastOpId: row.opId,
    })
  }

  const nextCursor =
    changes.length > 0 ? changes[changes.length - 1].serverCursor : cursorOf(cursor)

  return e.json(200, {
    protocolVersion: 1,
    schemaVersion: 1,
    ownerId: owner,
    serverTime: util.nowIso(),
    mode: mode,
    snapshot: mode === "snapshot",
    snapshotSeq: mode === "snapshot" ? snapshotSeq : null,
    changes: changes,
    nextCursor: nextCursor,
    hasMore: hasMore,
    resetRequired: false,
  })
}

module.exports = {
  MAX_LIMIT: MAX_LIMIT,
  handlePull: handlePull,
}
