# COMPATIBILITY · Linux 兼容性及问题清单（阶段 0）

> 对应分支：`feature/ubuntu-port`（基点 `0ee8a4c`）；Flutter 3.50.0 / Dart 3.14.0。
> 本文区分三种状态：**可直接复用**（零改动）、**需适配**（小改，保持 Windows 行为不变）、**需新增**（Windows 本来没有的能力）。
> 所有判定都基于真实源码；未在 Linux 实跑的部分标注“未验证”。

---

## 1. 总判定

本工程是“**桌面 UI 与业务层已平台无关，仅原生装配层耦合 Windows**”的形态：

| 判定 | 数量级 | 说明 |
|---|---|---|
| 可直接复用 | 约 85% 业务代码 | 月历、跨天条、日面板、任务/项目/备注、SQLite 数据层（Dart）、备份恢复、云同步协议与引擎、账号工作区、设备标识 |
| 需适配 | 约 3-5 个文件、< 500 行 | ① Linux 令牌存储（新增实现 + 工厂）；② `explorer.exe` → `xdg-open`；③ 窗口初始化容错；④ Linux runner 标题/图标等壳层细节 |
| 需新增 | 仅 Linux 壳层/打包类 | `.desktop`/PNG 图标、Linux 构建脚本；通知/托盘/快捷键等**不属于移植**（Windows 也没有） |
| 不适用 | — | Windows 专有 API 全部可替换；无“必须重构”的模块 |

**结论：Ubuntu 移植是小改，不需要第二套 UI、不需要重写日历、不需要改数据库 schema 或同步协议。**

---

## 2. 功能兼容矩阵

| 功能 | Windows 现状 | Linux 依赖 | 判定 | 备注 |
|---|---|---|---|---|
| 月历主页（周一起始、相邻月补齐、今天/选中/非本月） | 完整 | 纯 Flutter + Material | ✅ 直接复用 | `lib/features/calendar/`；无平台分支 |
| 跨日期项目横条（按周分段/车道/折叠） | 完整 | 纯 Flutter | ✅ 直接复用 | `month_grid.dart`、`span_bar.dart` |
| 双击日期 → 右侧任务面板 | 完整 | 纯 Flutter | ✅ 直接复用 | `day_cell.dart` 双击手势 + `day_detail_panel.dart` |
| 项目管理（增删改/颜色/归档/排序） | 完整 | 纯 Flutter | ✅ 直接复用 | `projects_page.dart` |
| 任务增删改 / 完成状态 / 时间轴 | 完整 | 纯 Flutter | ✅ 直接复用 | `features/day_detail/` |
| 每日备注 / 当日重点 | 完整 | 纯 Flutter | ✅ 直接复用 | `day_note_section.dart` |
| 本地 SQLite 建库/迁移/持久化 | 完整（`winsqlite3.dll`） | `package:sqlite3` 原生资产（Linux 预编译 `.so`） | ⚠️ Dart 可复用；**构建期需解决原生库获取** | 见 ISSUE-BUILD-03 |
| 数据目录规则 | `%APPDATA%\计划台\data` | `$XDG_DATA_HOME` / `~/.local/share` | ✅ 直接复用（代码已有 Linux 分支） | `planner_paths.dart:81-85` |
| 备份（JSON 导出） | 完整 | `dart:io` | ✅ 直接复用 | 固定目录 `<data>/backups`，无文件选择器 |
| 恢复（校验→快照→事务替换→回读） | 完整 | SQLite `VACUUM INTO` | ✅ 直接复用 | 快照本地库版本够新即可 |
| “打开数据/备份文件夹” | `explorer.exe` | `xdg-open` | ⚠️ 需适配（2 处） | 见 ISSUE-RUN-02 |
| 云登录（邮箱/用户名 + 密码） | 完整 | 令牌存储 | ⚠️ 需适配（缺令牌存储） | 见 ISSUE-RUN-01 |
| 云会话恢复/刷新/登出 | 完整 | 令牌存储 | ⚠️ 同上 | 存储不可用时安全失败（不落明文） |
| 云同步（push/pull/冲突/自动同步） | 完整 | 无平台依赖 | ✅ 直接复用 | 无平台分支；opId 幂等 + 版本冲突 |
| 账号绑定向导/账号工作区切换 | 完整 | 文件系统 + JSON | ✅ 直接复用 | 切换需重启（两端一致） |
| 设备标识 | `device.json`（UUIDv7） | 文件系统 | ✅ 直接复用 | Linux 记录 `platform: linux` |
| 原生窗口（标题/最小 1100×700/1440×900 居中） | `window_manager`（nativeapi） | `cnativeapi` Linux 后端（源码编译，依赖 GTK/X11/Xi） | ✅ 直接复用（调用面实现齐全，待真机验证） | 工程用到的 7 个窗口 API 在 Linux C++ 后端均有实现；见 ISSUE-BUILD-02 / ISSUE-RUN-03 |
| 中文字体渲染 | `Microsoft YaHei UI` 优先 | 系统 CJK 字体（Noto Sans CJK） | ⚠️ 需验证/微调 | 见 ISSUE-RUN-04 |
| 中文输入法（IBus/Fcitx） | Windows IME 已用 | GTK IM 上下文 | ❓ 未验证 | 见 ISSUE-RUN-05 |
| 应用内快捷键（Esc、T） | `CallbackShortcuts` | 纯 Flutter | ✅ 直接复用 | `app_shell.dart:52-56` 等 |
| 系统通知 / 托盘 / 全局快捷键 / 自启 | **未实现** | — | ➖ 不适用 | 不是移植缺口，若产品要新增属新功能 |
| 单实例 | **未实现** | — | ➖ 不适用（风险项） | Linux runner 默认 `G_APPLICATION_NON_UNIQUE`，见 ISSUE-RUN-07 |
| 文件选择器（任意位置导入/导出） | **未实现**（只能备份目录内选择） | — | ➖ 不适用 | 保持与 Windows 一致即可；若产品要“导入任意 JSON”需新增 |
| 自定义字体/图片资源 | 无（只有 `uses-material-design`） | Material Icons 内置 | ✅ 直接复用 | 降低 Linux 资源路径风险 |
| 应用图标/桌面菜单入口 | `.ico` + Windows 资源 | PNG + `.desktop`（发行阶段） | ⏭ 阶段 2（打包） | 本阶段不做安装包 |
| 开发脚本（截图/点击/启动） | PowerShell + `user32.dll` P/Invoke | 无 | ⏭ 非业务，Linux 需另写或弃用 | `scripts/` 13 个文件，不参与构建 |

---

## 3. 平台能力差异对照

| 能力 | Windows 实现 | Linux 对应方案 | 影响面 |
|---|---|---|---|
| 安全令牌存储 | `advapi32` Credential Manager（`Cred*` API，`WindowsCredentialStore`） | Secret Service：`libsecret`（GNOME Keyring）/ KWallet | 云登录唯一硬缺口 |
| SQLite 原生库 | 系统 `winsqlite3.dll`（`source: system`） | `sqlite3` 包预编译 `libsqlite3.x64.linux.so`（GitHub 下载）或系统 `libsqlite3.so` | 构建期与运行期各一次验证 |
| 原生窗口 | Win32 `CreateWindow` + `window_manager`/nativeapi | GTK3 `GtkApplication` + `window_manager`/nativeapi（X11/Xi） | 窗口行为需真机验证 |
| 打开文件夹 | `explorer.exe <path>` | `xdg-open <path>` | 2 个按钮 |
| 默认字体 | `Microsoft YaHei UI`（系统字体） | Noto Sans CJK（Ubuntu 通常预装） | 字形/行高观感差异 |
| 应用图标 | `.ico`（Windows 资源） | PNG + `.desktop` | 发行阶段 |
| 显示协议 | Win32（无 Wayland 概念） | X11 / Wayland（window_manager 走 X11，需要 XWayland） | Wayland 纯会话需实测 |
| 开机自启/单实例/通知 | 未实现 | — | 不新增 |
| 进程/文件锁 | 无 | 无（但 Linux 多开风险更高：GTK runner 允许多开） | 阶段 1 评估 |
| 开发/验收脚本 | PowerShell/VBS（P/Invoke `user32.dll`） | 需 bash 重写（非本阶段） | 不影响产品 |

---

## 4. 问题清单

编号规则：`ISSUE-<类别>-<序号>`；严重度 🔴阻塞 / 🟠高 / 🟡中 / 🟢低；“阶段”指计划在哪一阶段处理。

### 4.1 环境/构建类

| 编号 | 严重度 | 问题 | 证据 | 验证方法 | 处理方案 | 阶段 |
|---|---|---|---|---|---|---|
| ISSUE-ENV-01 | 🔴 | 本机没有 Ubuntu 目标环境，Flutter 拒绝在 Windows 上构建 Linux | `flutter build linux --release` → `"build linux" only supported on Linux hosts.`；WSL 可选功能 Disabled、无发行版、无 VM/Docker | 在目标 Ubuntu 上跑 `flutter doctor -v` + `tool/ubuntu/preflight_check.sh` | 阶段 1 前置：原生 Ubuntu 主机（推荐）或启用 WSL2（需重启） | P0 |
| ISSUE-ENV-02 | 🟠 | 目标机缺 Flutter Linux 工具链 | `linux_doctor.dart:127-139`（clang++≥3.4、cmake≥3.10、ninja≥1.8、pkg-config≥0.29、gtk+-3.0/glib-2.0/gio-2.0） | `flutter doctor -v` 的 Linux toolchain 一节 | 按 §5 的最小 apt 清单安装 | P0 |
| ISSUE-BUILD-01 | 🟢 | `jni` 作为 FFI 插件进入 Linux 构建（工程不使用 JNI）；无 JDK 时 CMake 探测失败即空操作，有 JDK 时多编一个从不加载的 `libdartjni.so` | `linux/flutter/generated_plugins.cmake` 的 `FLUTTER_FFI_PLUGIN_LIST = jni`；`jni-1.1.2/pubspec.yaml:43-53`；由 `path_provider_android 2.3.1` 硬依赖拖入（其 `pubspec.yaml:21-22`）；`jni-1.1.2/src/CMakeLists.txt:10-36`（`find_package(JNI)` 无 REQUIRED） | Linux 构建日志是否出现 `libdartjni.so`/JNI 链接错误 | **默认接受现状**（低风险）；若链接失败，临时去掉 `JAVA_HOME` 再构建；不建议改依赖树（会牵连 Android） | P1 |
| ISSUE-BUILD-02 | 🟡 | `window_manager` 的 Linux 后端 `cnativeapi` 需**从源码编译** C++17 库（无下载），依赖 GTK/X11/Xi 开发包 | `cnativeapi-0.6.1/hook/build.dart:77-89,143`（`pkg-config gtk+-3.0 x11 xi`）、`:173-185`（失败直接抛错） | Linux 构建日志中的 `cnativeapi` hook 输出；`pkg-config --exists gtk+-3.0 x11 xi` | 安装 `libgtk-3-dev libx11-dev libxi-dev` + clang/libstdc++ 头；工程用到的窗口 API（`getCurrent/title/minimumSize/setSize/center/show/focus`）在 Linux 后端**全部有实现**（`window_linux.cpp` / `window_manager_linux.cpp`） | P1 |
| ISSUE-BUILD-03 | 🟠 | `sqlite3` 在 Linux 构建期**从 GitHub Releases 下载预编译 `.so`**（sha256 校验），不本地编译；本机已复现同类下载超时 | `pubspec.yaml:49-57`（`default: sqlite3`）；`sqlite3-3.9.1/lib/src/hook/compile/description.dart:62-67`；URL 模板 `:352-353` | Linux 首次 `flutter build linux -v` 的 native assets 日志；`curl -I` 那个 releases URL | 三选一：① `url_pattern` 指向可访问镜像；② 预置下载缓存（sha256 见 `asset_hashes.dart:38`）；③ 把 Linux 也映射 `source: system`（Ubuntu 22.04+ libsqlite3 ≥3.37，满足 `VACUUM INTO`/窗口函数） | P1 |
| ISSUE-BUILD-04 | 🟢 | 预编译 SQLite 对 glibc 有下限（2.24）、版本 ≥3.54 | `sqlite3-3.9.1/CHANGELOG.md:42` | `ldd --version`、`sqlite3 --version` | 目标 Ubuntu 22.04/24.04 均满足；不使用 16.04 等老系统 | P1 |
| ISSUE-BUILD-05 | 🟢 | `flutter doctor` 只校验 CMake ≥3.10，但 Linux 工程模板实际要求 **3.13** | `linux_doctor.dart:128` vs `linux/CMakeLists.txt:2`、`linux/runner/CMakeLists.txt:1` | `cmake --version` | Ubuntu 22.04（3.22）/24.04（3.28）满足；不要用 3.10-3.12 | P1 |

### 4.2 运行期功能类

| 编号 | 严重度 | 问题 | 证据 | 验证方法 | 处理方案 | 阶段 |
|---|---|---|---|---|---|---|
| ISSUE-RUN-01 | 🟠 | Linux 无安全令牌存储 → 云登录必失败、会话恢复静默失败 | `main.dart:86` 硬编码 `WindowsCredentialStore()`；`windows_credential_store.dart:99,110` 仅 Windows；`pocketbase_account_service.dart:192-197,373-378` 存储不可用即拒绝；`nativeapi` Linux SecureStorage 是空实现（`secure_storage_linux.cpp:5-105`） | Linux 运行 App → 点登录 | 新增 `LinuxCredentialStore implements SecureTokenStore`（dart:ffi + libsecret `secret_password_*_sync`）+ 平台工厂 + `main.dart` 改用工厂；无 keyring 时明确提示安装/解锁，**禁止明文兜底**（契约 `docs/sync/SECURITY.md:64`） | P2 |
| ISSUE-RUN-02 | 🟡 | “打开数据/备份文件夹”用 `explorer.exe`，Linux 无效 | `backup_dialog.dart:164`、`settings_dialog.dart:75`；且 `Process.run` 未 `await`，`try/catch` 捕不到异步失败 | Linux 运行点按钮看提示/控制台 | 改为 `Platform.isWindows ? 'explorer.exe' : 'xdg-open'`，并 `await`/`catchError` 处理失败；保持 Windows 行为不变 | P1 |
| ISSUE-RUN-03 | 🟡 | `_configureNativeWindow()` 无 try/catch，且 Linux 窗口后端是编译产物，失败会**在数据库 try 之外**直接终止启动 | `main.dart:34` 调用、`:114-125` 实现（无异常保护）；`:45` 才开始数据库 try | Linux 上故意破坏窗口库/无显示环境启动 | 把窗口配置包裹 try/catch（失败仅降级为默认窗口，不影响本地日历），不改 Windows 成功路径 | P1 |
| ISSUE-RUN-04 | 🟡 | 字体首选 `Microsoft YaHei UI`，Linux 不存在；回退到 Noto Sans SC/CJK 后字形与行高可能变化 | `lib/core/theme/tokens.dart:94-102`；`app_theme.dart:33` | Linux 真机对比截图 | 不改字体链（回退链已含 Noto Sans SC）；若观感差异明显，阶段 1 在 Linux 分支注入字体或调整行高（需产品确认） | P2 |
| ISSUE-RUN-05 | 🟡 | 中文输入法（IBus/Fcitx）在 Flutter Linux 上的行为未验证 | 无自定义输入法代码（依赖引擎默认） | Linux 真机输入中文（任务标题/备注/项目名） | 验证为主；异常时按 Flutter Linux IME 已知问题处理（升级 SDK/调整 GTK 依赖） | P2 |
| ISSUE-RUN-06 | 🟢 | Wayland 会话下 window_manager 基于 X11/Xi，可能受限 | `cnativeapi` Linux pkg-config 依赖 `x11 xi` | 分别在 X11、Wayland+XWayland 下运行 | 优先在 X11/XWayland 验证并记录限制；不阻塞 | P2 |
| ISSUE-RUN-07 | 🟢 | 无单实例锁；GTK runner 使用 `G_APPLICATION_NON_UNIQUE` 允许多开，多实例共享同一 DB/指针文件 | `linux/runner/my_application.cc:126-128`（模板）；全仓库无 `FileLock`/flock | 双开并同时操作 | Windows 也无锁；若产品要求单实例，再统一加 Dart 侧锁（需产品确认，本阶段不做） | P3 |
| ISSUE-RUN-08 | 🟢 | Linux 数据目录未校验 `XDG_DATA_HOME` 绝对路径、未收紧权限到 0700 | `planner_paths.dart:81-85`；无 chmod | 设相对 `XDG_DATA_HOME` 观察落点；`stat -c %a` 看权限 | 阶段 1 在 Linux 分支加绝对路径校验 + 数据目录 `chmod 700`（不影响 Windows 分支） | P3 |
| ISSUE-RUN-09 | 🟢 | Linux runner 窗口标题是英文 `"jihuatai"`，Dart 初始化前会闪一下 | `linux/runner/my_application.cc:36` | Linux 启动观察标题 | 阶段 1 改为 `计划台`（与产品名一致）；同时可对齐首帧背景色/窗口默认尺寸 | P2 |
| ISSUE-RUN-10 | 🟢 | 无任意位置导入/导出文件选择器（外部 JSON 备份需手工放入备份目录） | `backup_dialog.dart:64-79,229-257`；`pubspec` 无 file_selector | 现状核对 | **保持与 Windows 一致，不新增**；若产品要求再单独评估（nativeapi 已含 file_dialog） | — |
| ISSUE-RUN-11 | 🟢 | 应用图标/桌面快捷方式/`.desktop` 文件缺失 | 只有 `windows/runner/resources/app_icon.ico` | 发行时检查 | 阶段 2（打包）处理；本阶段不做安装包 | P3 |

### 4.3 测试类

| 编号 | 严重度 | 问题 | 证据 | 处理方案 | 阶段 |
|---|---|---|---|---|---|
| ISSUE-TEST-01 | 🟡 | `windows_credential_store_test.dart` 在 Linux 上“空跑通过”（不计 skip），会掩盖未覆盖 | `test/data/cloud/windows_credential_store_test.dart:8-10,26-27` | 新增 `linux_credential_store_test.dart`（无 keyring 抛错/不落盘/文案），并在原用例改用 `skip:` 明确标注平台 | P2 |
| ISSUE-TEST-02 | 🟡 | `seed_exe_session_test.dart` 依赖 Windows exe + 凭据，Linux 上若开 E2E 会失败 | `test/integration/seed_exe_session_test.dart:1-3,28,40-42` | 在 Linux 上保持默认 skip；明确文档说明 | P1 |
| ISSUE-TEST-03 | 🟡 | 缺少 Linux 专属回归（XDG 路径、xdg-open、窗口初始化降级） | 无对应测试 | 阶段 1 补 3 个小用例 | P2 |

---

## 5. 目标 Ubuntu 最小依赖清单

```bash
# 构建必需（Flutter Linux 工具链 + 本工程插件）
sudo apt-get update
sudo apt-get install -y \
    clang cmake ninja-build pkg-config \
    libgtk-3-dev libx11-dev libxi-dev liblzma-dev libstdc++-12-dev

# 仅当采用“系统 SQLite”方案时
sudo apt-get install -y libsqlite3-dev

# 实现 Linux 令牌存储 / 云端登录时
sudo apt-get install -y libsecret-1-dev gnome-keyring

# 无显示器做 GUI 冒烟时
sudo apt-get install -y xvfb
```

判定依据：`linux_doctor.dart:127-139`（Flutter 官方要求）、`cnativeapi-0.6.1/hook/build.dart:143`（本工程插件额外要求 `x11`/`xi`）、`docs/sync/SECURITY.md:64`（libsecret）。
“只装缺的”：先跑 `tool/ubuntu/preflight_check.sh`，按 FAIL 项安装，不整机升级。

---

## 6. 明确“不需要做”的事

1. **不重写日历/任务/项目/备注 UI**：这些模块零平台分支，直接复用。
2. **不创建第二套工程**：仍在现有 Flutter 工程内加 `linux/` 平台目录。
3. **不改数据库 schema、不改云同步协议**：Dart 数据层与同步引擎平台无关。
4. **不为通知/托盘/全局快捷键做“Linux 兼容层”**：Windows 版没有这些功能，保持功能对等即可。
5. **不新增文件选择器**：Windows 备份也只从固定目录选；保持行为一致，避免扩大改动面。
6. **不升级 Flutter SDK / 不重装系统软件包**：当前 SDK 3.50.0 与目标平台匹配。
7. **不动 `master`、`integration/*`、`server/`、`dist/`、真实用户数据库**。

---

## 7. 待验证清单（按优先级）

| 优先级 | 项 | 验证方式 |
|---|---|---|
| P0 | Ubuntu 主机与工具链 | `tool/ubuntu/preflight_check.sh` + `flutter doctor -v` |
| P0 | `flutter build linux --release` 首次通过 | 构建日志（重点看 cnativeapi hook、sqlite3 下载、jni） |
| P1 | Linux 启动与窗口行为（尺寸/最小/居中/标题） | 真机启动 + 截图对比 Windows |
| P1 | 本地数据落点与重启持久化 | 启动建库 → 建项目/任务 → 重启；`~/.local/share/计划台/data` 检查 |
| P1 | 备份/恢复 | 导出 JSON → 恢复 → 回读一致；“打开文件夹”按钮 |
| P1 | 无 keyring 时的云安全降级 | 无 keyring 环境点登录，确认提示且不落明文 |
| P2 | 中文输入法 | IBus/Fcitx 输入任务标题/备注 |
| P2 | 字体观感与 DPI 缩放 | 100%/125%/150% 截图 |
| P2 | Wayland 会话 | Wayland + XWayland 启动与窗口控制 |
| P2 | Linux 令牌存储实现 | 新增实现 + 测试 + 真实登录（本地 PocketBase） |
| P3 | 单实例/多开风险 | 双开操作 |
| P3 | 发行打包（`.desktop`/图标/deb/AppImage） | 阶段 2 |

---

## 8. 对 Windows 的潜在影响（约束）

本阶段**未改任何业务代码**，Windows 行为零变化。后续阶段的所有适配必须满足：

1. 平台差异用**运行期分支**（`Platform.isLinux` / 工厂），不改 Windows 既有路径；
2. 新增文件隔离（如 `linux_credential_store.dart`），Windows 不 import；
3. 若必须改公共装配点（`lib/main.dart` 的令牌工厂），Windows 分支行为必须与现状逐字节一致（同一实现类、同一参数）；
4. 若改 `pubspec.yaml`（如 sqlite3 的 `source` 映射），必须保持 `windows: system / winsqlite3` 不变；
5. 任何公共依赖变更都要在提交说明里写“对 Windows 影响”一节，并在 Windows 上复跑 `flutter analyze` + `flutter test`（基线：358 passed / 11 skipped）。
