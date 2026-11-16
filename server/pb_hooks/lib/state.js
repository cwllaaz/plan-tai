// 状态与健康检查（CJS 模块）。
//
// health 是客户端 connectServer() 的握手依据，字段必须与
// docs/sync/API_CONTRACT.md §2 完全一致：
//   status / serverVersion / protocolVersion / minSchemaVersion /
//   maxSchemaVersion / serverTime / features / limits

const util = require("./util.js")
const db = require("./db.js")

function handleState(e) {
  const owner = e.auth.id
  return e.json(200, {
    userId: owner,
    maxSeq: db.maxSeqForOwner(e.app, owner),
    serverTime: util.nowIso(),
    protocolVersion: db.PROTOCOL_VERSION,
    schemaVersion: db.readMeta(e.app, "schema_version", db.SCHEMA_VERSION),
    counts: {
      projects: db.countByOwner(e.app, "pa_projects", owner),
      spans: db.countByOwner(e.app, "pa_spans", owner),
      tasks: db.countByOwner(e.app, "pa_tasks", owner),
      notes: db.countByOwner(e.app, "pa_notes", owner),
    },
  })
}

function handleHealth(e) {
  return e.json(200, {
    status: "ok",
    serverVersion: "pocketbase-0.23.12",
    protocolVersion: parseInt(db.PROTOCOL_VERSION, 10),
    minSchemaVersion: parseInt(db.SCHEMA_VERSION, 10),
    maxSchemaVersion: parseInt(db.SCHEMA_VERSION, 10),
    serverTime: util.nowIso(),
    features: ["sync.push", "sync.pull"],
    limits: { maxOpsPerPush: 100, maxPullLimit: 500 },
  })
}

module.exports = {
  handleState: handleState,
  handleHealth: handleHealth,
}
