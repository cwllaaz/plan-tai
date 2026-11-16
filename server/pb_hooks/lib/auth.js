// 登录节流（CJS 模块）：按「登录标识」计数，5 分钟内最多 N 次尝试。
// 与 PocketBase 自带按 IP 速率限制叠加：这里防单账号被撞库，那里防单 IP 扫号。

const util = require("./util.js")
const db = require("./db.js")

const WINDOW_MS = 5 * 60 * 1000
const LOCK_MESSAGE = "登录尝试过于频繁，请 5 分钟后再试"

function maxAttempts() {
  let raw = ""
  try {
    raw = $os.getenv("PA_LOGIN_MAX_ATTEMPTS")
  } catch (err) {
    raw = ""
  }
  const n = parseInt(raw, 10)
  return isNaN(n) || n <= 0 ? 10 : n
}

function attemptKey(identity) {
  return "users:" + identity.trim().toLowerCase()
}

function throttle(e) {
  const app = e.app ? e.app : $app
  const identity = util.isString(e.identity) ? e.identity : ""
  if (identity.trim() === "") {
    return e.next()
  }

  const key = attemptKey(identity)
  const now = util.nowIso()
  const nowMs = Date.parse(now)
  const limit = maxAttempts()

  const rows = db.rowsFrom(
    app,
    "SELECT json_object('count', count, 'windowStart', window_start) AS data" +
      " FROM pa_login_attempts WHERE key={:key} LIMIT 1",
    { key: key }
  )

  let count = 0
  let windowStart = now
  if (rows.length > 0) {
    const winMs = Date.parse(rows[0].windowStart)
    if (!isNaN(winMs) && nowMs - winMs < WINDOW_MS) {
      count = rows[0].count
      windowStart = rows[0].windowStart
    }
  }

  if (count >= limit) {
    throw new BadRequestError(LOCK_MESSAGE)
  }

  app
    .db()
    .newQuery(
      "INSERT INTO pa_login_attempts (key, count, window_start) VALUES ({:key}, 1, {:start})" +
        " ON CONFLICT(key) DO UPDATE SET count={:count}, window_start={:start}"
    )
    .bind({ key: key, count: count + 1, start: windowStart })
    .execute()

  e.next()
}

function clearAttempts(e) {
  const app = e.app ? e.app : $app
  try {
    const record = e.record
    if (record && record.collection && record.collection().name === "users") {
      const email = util.isString(record.email()) ? record.email() : ""
      let username = ""
      try {
        username = record.getString("username")
      } catch (err) {
        username = ""
      }
      if (email !== "") {
        app.db().newQuery("DELETE FROM pa_login_attempts WHERE key={:key}").bind({ key: attemptKey(email) }).execute()
      }
      if (username !== "") {
        app
          .db()
          .newQuery("DELETE FROM pa_login_attempts WHERE key={:key}")
          .bind({ key: attemptKey(username) })
          .execute()
      }
    }
  } catch (err) {
    // 计数清理失败不影响登录本身；只记录，不打印任何凭据
    console.log("[pa-auth] reset attempts failed: " + err)
  }
  e.next()
}

module.exports = {
  throttle: throttle,
  clearAttempts: clearAttempts,
  LOCK_MESSAGE: LOCK_MESSAGE,
}
