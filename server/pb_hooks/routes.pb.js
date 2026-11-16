// 自定义路由注册。
// 注意：handler 会被 PocketBase 序列化到独立上下文执行，因此业务逻辑都放在
// lib/*.js 里，这里只做 require + 调用。
//
// 路径与响应严格对齐 docs/sync/API_CONTRACT.md §9（前缀 /api/planner）。

routerAdd(
  "POST",
  "/api/planner/sync/push",
  (e) => {
    return require(__hooks + "/lib/push.js").handlePush(e)
  },
  $apis.requireAuth("users"),
  $apis.bodyLimit(1024 * 1024)
)

routerAdd(
  "POST",
  "/api/planner/sync/pull",
  (e) => {
    return require(__hooks + "/lib/pull.js").handlePull(e)
  },
  $apis.requireAuth("users"),
  $apis.bodyLimit(64 * 1024)
)

// 诊断端点：账号、记录数与最大游标。不属于同步协议主链路，但便于运维排查。
routerAdd(
  "GET",
  "/api/planner/sync/state",
  (e) => {
    return require(__hooks + "/lib/state.js").handleState(e)
  },
  $apis.requireAuth("users")
)

// 公开健康检查（握手）：不要求登录，但必须与客户端 PlannerApi.health 对齐。
routerAdd("GET", "/api/planner/health", (e) => {
  return require(__hooks + "/lib/state.js").handleHealth(e)
})
