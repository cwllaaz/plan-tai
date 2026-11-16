// 通用工具：时间、字符串、JSON、错误构造。
// 该文件不是 .pb.js，因此不会被 PocketBase 当作 handler 加载，只能被 require。

const UUID_V7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/
// 协议时间：UTC、Z。允许 1-6 位小数（客户端 encodeInstant 输出 6 位微秒，
// 早期服务端只接受毫秒会误拒绝合法的 completedAt/createdAt）。
const ISO_UTC_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/
const HEX_COLOR_RE = /^#[0-9A-F]{6}$/
const TOKEN_ID_RE = /^[A-Za-z0-9._:-]{1,64}$/

function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, "Z")
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

function isString(v) {
  return typeof v === "string"
}

function isInt(v) {
  return typeof v === "number" && isFinite(v) && Math.floor(v) === v
}

function isUuidV7(v) {
  return isString(v) && UUID_V7_RE.test(v)
}

function isDateStr(v) {
  if (!isString(v)) return false
  const m = DATE_RE.exec(v)
  if (!m) return false
  const y = parseInt(m[1], 10)
  const mo = parseInt(m[2], 10)
  const d = parseInt(m[3], 10)
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return false
  const dt = new Date(Date.UTC(y, mo - 1, d))
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d
}

function isIsoUtc(v) {
  if (!isString(v) || !ISO_UTC_RE.test(v)) return false
  const t = Date.parse(v)
  return !isNaN(t)
}

function daysBetween(startDate, endDate) {
  const a = Date.parse(startDate + "T00:00:00Z")
  const b = Date.parse(endDate + "T00:00:00Z")
  return Math.floor((b - a) / 86400000) + 1
}

function parseJson(text, fallback) {
  try {
    return JSON.parse(text)
  } catch (err) {
    return fallback
  }
}

// 业务校验错误：只影响当前 op，不中断整个 push 请求。
function SyncError(code, message, field) {
  this.name = "SyncError"
  this.code = code
  this.message = message
  this.field = field || ""
  this.stack = new Error(message).stack
}
SyncError.prototype = Object.create(Error.prototype)
SyncError.prototype.constructor = SyncError

function fail(code, message, field) {
  throw new SyncError(code, message, field)
}

// 只打印审计需要的最小信息：绝不打印 payload、令牌、密码。
function audit(event, fields) {
  const parts = [event]
  if (fields) {
    for (const k in fields) {
      parts.push(k + "=" + fields[k])
    }
  }
  console.log("[pa-sync] " + parts.join(" "))
}

module.exports = {
  UUID_V7_RE: UUID_V7_RE,
  DATE_RE: DATE_RE,
  ISO_UTC_RE: ISO_UTC_RE,
  HEX_COLOR_RE: HEX_COLOR_RE,
  TOKEN_ID_RE: TOKEN_ID_RE,
  nowIso: nowIso,
  isPlainObject: isPlainObject,
  isString: isString,
  isInt: isInt,
  isUuidV7: isUuidV7,
  isDateStr: isDateStr,
  isIsoUtc: isIsoUtc,
  daysBetween: daysBetween,
  parseJson: parseJson,
  SyncError: SyncError,
  fail: fail,
  audit: audit,
}
