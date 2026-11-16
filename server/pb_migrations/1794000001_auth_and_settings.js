// 计划台 V2.0 云端同步 · 账号策略与运行配置
//
// 1. users 增加 username 字段，允许「用户名或邮箱」登录（passwordAuth.identityFields）。
// 2. 关闭公共注册与自助注销：createRule / deleteRule 置 null（PocketBase 中 null = 锁定），
//    账号由管理员在 Dashboard 或 create-user 脚本中创建。
// 3. 登录令牌有效期 14 天；客户端用 /api/collections/users/auth-refresh 恢复登录态。
// 4. 打开 PocketBase 全局速率限制（按 IP），覆盖登录暴力破解。
// 5. 管理员（_superusers）与普通用户（users）是两套独立集合，业务路由只接受 users 令牌。

// 速率限制阈值允许用环境变量覆盖（测试环境需要放宽，生产用默认值）。
function readEnvInt(name, fallback) {
  let raw = ""
  try {
    raw = $os.getenv(name)
  } catch (err) {
    raw = ""
  }
  if (!raw) return fallback
  const n = parseInt(raw, 10)
  return isNaN(n) || n <= 0 ? fallback : n
}

migrate((app) => {
  const users = app.findCollectionByNameOrId("users")

  // ---- 用户名：3-32 位，字母数字与 _ . - ----
  users.fields.add(
    new TextField({
      name: "username",
      required: false,
      min: 3,
      max: 32,
      pattern: "^[a-zA-Z0-9_.-]{3,32}$",
    })
  )

  // 用户名或邮箱都能登录
  users.passwordAuth.identityFields = ["email", "username"]
  // 令牌 14 天（客户端只用 refresh 接口续期，不长期保存密码）
  users.authToken.duration = 1209600

  // 默认关闭公共注册；管理员在 Dashboard 建号后交给用户
  users.createRule = null
  users.deleteRule = null
  // 普通用户只能看/改自己
  users.listRule = "id = @request.auth.id"
  users.viewRule = "id = @request.auth.id"
  users.updateRule = "id = @request.auth.id"

  users.indexes = [
    "CREATE UNIQUE INDEX `idx_tokenKey__pb_users_auth_` ON `users` (`tokenKey`)",
    "CREATE UNIQUE INDEX `idx_email__pb_users_auth_` ON `users` (`email`) WHERE `email` != ''",
    "CREATE UNIQUE INDEX `idx_users_username` ON `users` (`username`) WHERE `username` != ''",
  ]

  app.save(users)

  // ---- 登录尝试计数（按“账号标识”限流，防单账号被暴力破解）----
  app
    .db()
    .newQuery(
      "CREATE TABLE IF NOT EXISTS pa_login_attempts (" +
        " key TEXT PRIMARY KEY," +
        " count INTEGER NOT NULL DEFAULT 0," +
        " window_start TEXT NOT NULL)"
    )
    .execute()

  // ---- 运行配置 ----
  const authRateMax = readEnvInt("PA_RATE_LIMIT_AUTH", 20)
  const syncRateMax = readEnvInt("PA_RATE_LIMIT_SYNC", 120)
  const settings = app.settings()
  settings.meta.appName = "计划台"
  settings.logs.maxDays = 14
  // 记录认证主体 id 便于审计，但不记录任何令牌/密码（PocketBase 本身不会记录请求体）
  settings.logs.logAuthId = true
  settings.logs.logIP = true

  settings.rateLimits.enabled = true
  settings.rateLimits.rules = [
    // 登录/刷新等认证接口：单 IP 每分钟 20 次（失败尝试也计数）
    { label: "*:auth", audience: "", duration: 60, maxRequests: authRateMax },
    // 同步接口：单 IP 每 10 秒 120 次
    { label: "/api/planner/", audience: "", duration: 10, maxRequests: syncRateMax },
    // 其余 API 保持默认量级
    { label: "/api/", audience: "", duration: 10, maxRequests: 300 },
  ]

  app.save(settings)
}, (app) => {
  const users = app.findCollectionByNameOrId("users")
  users.passwordAuth.identityFields = ["email"]
  users.createRule = ""
  users.deleteRule = "id = @request.auth.id"
  users.indexes = [
    "CREATE UNIQUE INDEX `idx_tokenKey__pb_users_auth_` ON `users` (`tokenKey`)",
    "CREATE UNIQUE INDEX `idx_email__pb_users_auth_` ON `users` (`email`) WHERE `email` != ''",
  ]
  app.save(users)

  const settings = app.settings()
  settings.rateLimits.enabled = false
  app.save(settings)

  app.db().newQuery("DROP TABLE IF EXISTS pa_login_attempts").execute()
})
