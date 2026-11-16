# 计划台 Android 1.0.0 · 已知问题与限制

> 按「已确认问题 / 环境限制 / 待后续版本」分类。发布前请通读。

---

## 一、必须让用户知道的产品限制

1. **只提供 arm64-v8a 正式包（本次）**：2016 年后的主流手机均为 arm64；armeabi-v7a 旧机需要额外构建（见第 3 节）。universal 包本次因构建机无法下载 `armeabi-v7a` 的 sqlite3 预编译库而未能产出——已提供 arm64 正式包与 x86_64 模拟器验收包，不影响真实手机安装。
2. **Debug 包与正式包不能互相覆盖安装**：签名不同是 Android 安全约束。Debug 包仅用于排障，不对外发布。
3. **卸载会删数据**：Android 机制；卸载前必须「导出备份到文件」或确认云端已同步。
4. **换账号需按提示处理数据归属**：本机已绑定账号 A 时登录账号 B，会提示 `boundOtherAccount` 并禁止把 A 的数据上传到 B；这是防串号设计，不是故障。
5. **首版自动同步只在前台**：应用被彻底关闭后不会实时同步；下次打开会补传。没有 WorkManager/常驻前台服务。
6. **账号页「退出账号」= 清除令牌 + 停止同步**：不会解除云端绑定记录，也不删除本地数据；重新登录原账号可继续同步。
7. **恢复备份是整体覆盖**：不是合并；两设备同步请用「登录 + 同步」，不要用备份互相覆盖。

---

## 二、未验证 / 需真机复核（发布后优先补测）

1. **物理手机/平板未接入**：全部运行期验收在 Android 15 (API 35) x86_64 模拟器完成；以下需真机：
   - 真实触摸手感、软键盘交互、厂商 ROM 的后台/省电策略；
   - Android Keystore 在个别厂商 ROM 上的可用性（不可用时应用会安全降级为纯离线，不写明文）；
   - 锁屏、来电、分屏、画中画打断；
   - 换机迁移：应用已关闭系统自动备份，跨设备请使用自建云端同步或应用内 JSON 备份/恢复；
   - arm64 真机性能与内存（模拟器为软件 GPU，启动耗时不可作为真机指标）。
2. **未在生产 PocketBase 上做任何写操作**：联调服务器为本机独立测试数据目录；生产部署（HTTPS/Caddy/systemd/备份）按 `docs/DEPLOYMENT.md` 执行。
3. **16KB 页对齐**：APK 内 `libsqlite3.so` 已验证 16KB 对齐；其它 `.so` 由 Flutter 引擎提供，需在 Android 15 真机复核。
4. **未上架应用商店**：侧载 APK；未配置代码混淆/加固（Flutter release 默认 AOT，Dart 代码以 AOT 机器码分发）。
5. **数据库查询仍在 UI isolate**：月历一次查整月且索引齐全，百级数据无感；万级数据+低端机可能掉帧，后续可迁移到 Isolate。

---

## 三、已知技术问题（不影响本次交付使用）

1. **构建机网络限制导致 universal 包失败**：`sqlite3` 3.9.1 的 native assets hook 用 Dart HttpClient 从 GitHub Releases 下载对应 ABI 的 `libsqlite3.so`，不走系统代理；本机缺 `armeabi-v7a` 缓存时下载超时。解决方法（在有代理的机器上）：
   ```powershell
   # 方式 A：先联网构建一次带 arm 目标的包，让 hook 缓存 .so
   flutter build apk --release --target-platform android-arm --no-pub
   # 方式 B：手动下载 https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.9.1/libsqlite3.arm.so
   #         放到 .dart_tool/hooks_runner/shared/sqlite3/build/ 对应缓存目录后重试
   ```
   arm64 / x86_64 库本机已缓存，因此 arm64 正式包与 x86_64 验收包均构建成功。
2. **dev 依赖 `integration_test` 与 release 构建**：Flutter 3.50 会把 dev 插件 `IntegrationTestPlugin` 也写进 `GeneratedPluginRegistrant.java`，release 编译会引用 release classpath 不存在的测试插件而失败；若直接删除该生成文件，release 包又会漏注册 `path_provider`，真机启动即失败。`scripts/android/build_apk.ps1` 已改为：release 构建期间临时从 `pubspec.yaml` 移除 `integration_test` → `flutter pub get` → 构建 → **恢复 pubspec/lock 并重新 pub get**（源码不变）。手工构建 release 请使用该脚本，不要直接 `flutter build apk --release`。
3. **切换 `--target-platform` 的「虚胖 APK」**：Flutter 已知现象，切换 ABI 后增量 debug APK 会偏大；交付前应 `Remove-Item -Recurse build\app` 后重建（`scripts/android/build_apk.ps1` 不自动清理，必要时手工清）。
4. **`window_manager` / `cnativeapi` 仍会被编进 Android 包**：它是桌面窗口管理依赖，Android 代码路径不会调用；`cnativeapi` 的 native assets 构建在 Android 上是多余负担，也是本机构建偶发卡死的来源（并发构建时更明显）。后续建议做成平台隔离（移除 Android 侧该依赖），属数据/架构改动，需单独排期。
5. **模拟器 `adb shell input tap` 无法驱动 Flutter**（基线 APK 同样复现）：本仓库的设备 UI 验收统一用 Flutter `integration_test`（VM Service 驱动），不依赖 adb 注入；真机手工验收不受影响。\n6. **`path_provider_android` 版本固定**：2.3.x 经 `jni/jni_flutter` 在 Flutter 3.50 Android release(AOT) 下启动即崩溃（JNI 过早初始化），debug 正常；已用 `dependency_overrides: path_provider_android: 2.2.23` 固定到 MethodChannel 实现。后续升级该包时必须先在 **release** 包上验证启动，再解除固定。

---

## 四、本次交付的验证边界（如实声明）

- 已通过：本地完整流程（模拟器、真实 SQLite）、真实 PocketBase 双客户端 10/10、真实云端跨端/离线/冲突 14/14、正式签名 release APK 构建 + 28 项内容检查、同签名 versionCode 1→2 覆盖安装且数据保留、Windows 回归（见测试报告第 6 节）。
- 未通过/未执行：物理真机、生产服务器、应用商店、arm64 真机性能、系统自动备份实际行为。
