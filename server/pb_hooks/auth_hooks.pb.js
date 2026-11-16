// 登录相关 hook 注册（逻辑在 lib/auth.js）。

onRecordAuthWithPasswordRequest((e) => {
  require(__hooks + "/lib/auth.js").throttle(e)
}, "users")

onRecordAuthRequest((e) => {
  require(__hooks + "/lib/auth.js").clearAttempts(e)
}, "users")
