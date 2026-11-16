# 计划台 Android 版 · 跨平台架构（ARCHITECTURE）

> 目标：在**不破坏 Windows 稳定工程**的前提下，增量支持 Android 手机/平板。
> 本文定义复用边界、平台适配层、启动组装与数据流；接口签名见 `MODULE_CONTRACT.md`，
> 平台差异与构建链见 `ARCHITECTURE.md` 与 `ANDROID_INSTALL.md`。

---

## 1. 设计约束（不可协商）

1. **增量优先**：已有业务模块直接复用；不得为 Android 重写领域模型、仓储、同步引擎。
2. **单入口、单业务层**：Android 与 Windows 共用 `lib/core`、`lib/data`、`lib/features`；
   差异只在「启动组装 + 平台适配 + 界面外壳」。
3. **本地优先 / 离线可用**：网络只影响云同步，不影响打开、浏览、编辑本地数据。
4. **数据安全**：永不自动删库/重建库；令牌只进系统安全存储；恢复/覆盖前先备份。
5. **一个应用身份**：`com.jihuatai.planner` 永久不变，保证覆盖升级。
6. **不做大规模重构**：Windows 外壳（`lib/app/**`）保持原样；移动端新目录承载新 UI。

---

## 2. 分层与依赖方向

```
┌──────────────────────────────────────────────────────────────────────┐
│ 平台外壳层                                                            │
│  lib/app/**（Windows 桌面外壳，保持不动）                              │
│  lib/mobile/**（Android 移动外壳，月历模块 新建）                       │
│  lib/bootstrap/android_bootstrap.dart（Android 组合根，维护者）     │
│  lib/main.dart（唯一入口，按 Platform 分流）                           │
├──────────────────────────────────────────────────────────────────────┤
│ 界面模块层（跨平台可复用）                                             │
│  lib/features/calendar/**      月历视图                                │
│  lib/features/day_detail/**    当日面板 + 任务编辑                      │
│  lib/features/cloud_account/** 云账号/同步/冲突 UI + 控制器             │
├──────────────────────────────────────────────────────────────────────┤
│ 契约层（纯 Dart，冻结）                                                │
│  lib/core/models            领域模型（Project/PlanSpan/PlannerTask/…）  │
│  lib/core/contracts         PlannerRepository                          │
│  lib/core/cloud             CloudAccountService/SyncService/值对象/Fake │
│  lib/core/theme|format      设计令牌与格式化                            │
├──────────────────────────────────────────────────────────────────────┤
│ 实现层                                                                │
│  lib/data/**                SQLite 仓储、备份、PocketBase 客户端、同步引擎 │
│  lib/data/cloud/secure_token_store.dart  安全存储契约（平台实现分离）    │
├──────────────────────────────────────────────────────────────────────┤
│ 平台适配层                                                            │
│  lib/platform/app_paths.dart           应用私有目录（Android: path_provider）│
│  lib/data/planner_paths.dart           路径规则 + 运行期注入            │
│  lib/data/cloud/windows_credential_store.dart  Windows 令牌存储         │
│  （待建）lib/data/cloud/android_secure_token_store.dart  Android 令牌存储 │
│  android/**                            Android 原生工程（Gradle/Manifest）│
│  windows/**                            Windows 原生工程（保持不动）      │
└──────────────────────────────────────────────────────────────────────┘
```

依赖只允许**自上而下**：`app/mobile → features → core`，`features → core` 与 `bootstrap → data → core`。
`data` 不得 import `app`/`features`（例外：`bootstrap` 组合根可同时 import 两者）。

---

## 3. 复用边界矩阵

| 模块 | 处置 | 说明 |
|---|---|---|
| `core/models/**` | **直接复用** | 纯 Dart，无平台 API；日期用 `LocalDate`，时刻用整数分钟 |
| `core/contracts/planner_repository.dart` | **直接复用（冻结）** | UI 唯一数据入口 |
| `core/cloud/**` | **直接复用（冻结）** | `CloudAccountService`/`SyncService` 与平台无关；Fake 供 UI 开发 |
| `core/theme|format` | **直接复用 + 移动端扩展令牌** | 颜色/字号可复用；触摸尺寸、布局断点由 `UI_SPEC.md` 追加 |
| `data/planner_database.dart`、`sql_schema.dart` | **直接复用** | 事务/迁移/完整性检查与平台无关 |
| `data/sqlite_planner_repository.dart` | **直接复用** | 软删除/乐观并发/排序/outbox 同事务 |
| `data/backup_service.dart` | **直接复用** | JSON 备份/快照/恢复；Android 文件导出方式待 B 适配（SAF/分享） |
| `data/cloud/**`（HTTP/认证/同步引擎） | **直接复用** | 只依赖 `dart:io HttpClient` 与文件系统 |
| `data/cloud/windows_credential_store.dart` | **Windows 保留** | advapi32/DPAPI，Android 不可用；不修改 |
| `data/cloud/secure_token_store.dart` | **接口复用** | Android 新增实现（数据层） |
| `core/testing/**` | **直接复用** | `InMemoryPlannerRepository` + `seedDemoData` + Fake 云服务 |
| `features/calendar/**` | **复用，允许包装** | 桌面版按鼠标设计（双击、右键拖选）；移动端可复用组件或在其上做触摸包装，数据流不变 |
| `features/day_detail/**` | **复用，允许包装** | 面板内部逻辑完整；手机端放进底部面板/全屏页即可 |
| `features/cloud_account/**` | **状态复用，UI 需移动化** | `CloudAccountController` 与文案复用；`CloudAccountPanel` 是 420 宽的桌面抽屉，手机端需新布局（月历模块/C 协作，C 负责语义、A 负责外观） |
| `app/**`（Windows 外壳） | **保留不动** | 侧栏、顶栏、窗口、快捷键、对话框 |
| `mobile/**` | **新建** | Android 触屏外壳（月历模块） |
| `bootstrap/android_bootstrap.dart` | **新建（组合根）** | 目录 → DB → 云 → UI 的装配 |
| `platform/app_paths.dart` | **新建** | 平台私有目录解析 |
| `android/**` | **新建** | Gradle 工程、Manifest、签名、图标、启动主题（每日面板模块） |
| `windows/**` | **保留不动** | 除自动生成的 plugin registrant 外不改 |

**明确“不新建”的东西**：第二套 Repository、第二套任务/项目模型、第二套同步引擎、第二套主题体系、
第二套备份格式。

---

## 4. 平台差异清单

| 能力 | Windows | Android | 处理 |
|---|---|---|---|
| 窗口管理 | `window_manager`：1440×900、最小 1100×700 | 无窗口概念 | `main.dart` 在 Android 分支提前返回；`_configureNativeWindow` 再判平台 |
| 数据目录 | `%APPDATA%\计划台`（或 `JIHUATAI_DATA_DIR`） | `getApplicationSupportDirectory()`（应用私有） | 新增 `AppPaths.resolveBaseDirectory()` + `PlannerPaths.useBaseDirectory()` |
| SQLite 原生库 | 系统 `winsqlite3.dll`（hooks `source: system`） | 随包预编译 `libsqlite3.so`（避免 API 24 系统库过旧） | `pubspec.yaml` hooks 按 OS 分支 |
| 令牌存储 | 凭据管理器（advapi32/DPAPI） | Android Keystore（平台通道 `com.jihuatai.planner/secure_store`） | `SecureTokenStore` 接口 + 平台实现 |
| 文件选择/导出 | 原生文件对话框（桌面 `File` 读写） | 无用户可见文件系统 | B 评估 SAF/分享；本阶段不实现 |
| 输入 | 鼠标 + 键盘快捷键（Esc/T） | 触摸手势、系统返回键 | 移动外壳自行处理（`PopScope`）；桌面快捷键保留 |
| 字体 | `Microsoft YaHei UI` 优先 | 系统 CJK 字体 | 现有 `fontFamilyFallback` 已含 `Noto Sans SC`；A 可评估内置字体 |
| 生命周期 | 关窗退出 | 后台/被杀 | B 在 `AppLifecycleState.paused` 做 checkpoint；数据层已 WAL |
| 升级 | exe 覆盖安装 | APK 覆盖升级（applicationId + versionCode 单调） | `com.jihuatai.planner` 已冻结；签名与版本策略由 B 落地 |
| 云端协议 | PocketBase REST（自研客户端） | **完全相同** | 直接复用 |

---

## 5. Android 启动流程

```
main()                                   lib/main.dart
 ├─ WidgetsFlutterBinding.ensureInitialized()
 ├─ if (Platform.isAndroid) → runAndroidApp()
 │    ├─ AppPaths.resolveBaseDirectory()             // path_provider（异步）
 │    ├─ PlannerPaths.useBaseDirectory(base)         // 注入，之后所有路径规则生效
 │    ├─ dataDirectory = <base>/data
 │    ├─ workspace = CloudWorkspaceStore(data)
 │    ├─ databasePath = workspace.activeDatabasePath() ?? <data>/app.db
 │    ├─ repository = SqlitePlannerRepository.open(...)  // 建库/迁移/完整性检查
 │    ├─ services = await createAndroidCloudServices(...) // 未实现时返回 null → 离线
 │    ├─ controller = CloudAccountController(services, FileCloudUiPreferences)
 │    └─ runApp(MobileApp(repository, cloud…))
 │         ├─ PlannerShellState(today)
 │         ├─ AppScope(repository, shell)
 │         ├─ CloudScope?(services, controller) → controller.initialize()
 │         └─ MaterialApp(theme, zh_CN) → 移动外壳
 └─ else（桌面）：窗口配置 → 数据目录 → DB → 云 → PlannerApp（逻辑与 V2 相同）
```

失败路径：

| 失败点 | 行为 |
|---|---|
| 目录解析失败 | `StartupFailureApp`（可读原因 + 数据位置），不退出、不建库 |
| 数据库打不开/版本过新/完整性失败 | `StartupFailureApp`，**绝不重建库** |
| 云初始化失败 | 捕获 → `services = null` → 纯离线可用（不阻塞启动） |
| SQLite 原生库缺失 | 打开数据库时抛 `LocalDatabaseException` → `StartupFailureApp` |

---

## 6. 数据流

### 6.1 本地读写（Android 与 Windows 完全一致）

```
Widget (StreamBuilder)
   │ watchXxx() / findXxx()
   ▼
PlannerRepository（唯一接口）
   ▼
SqlitePlannerRepository ──事务──► PlannerDatabase ──► SQLite 文件（WAL）
   │                                   │
   │ 写操作同事务写 sync_outbox         └─ changes 广播 → 所有 watch 流刷新
   └─ 写入完成 notifyChanged()
```

- 所有写操作都是 `BEGIN IMMEDIATE`：级联软删除、outbox 入队、`revision+1` 要么全成要么全不成。
- UI 不缓存业务数据；仓储流负责刷新。跨页共享的只有 `PlannerShellState`（选中日期/月份/分区）。

### 6.2 云端同步

```
UI → CloudAccountController → SyncService（SqliteCloudSyncService）
                                ├─ outbox push（本地改动）
                                ├─ pull（游标/快照）→ RemoteApplier → 同一 SQLite
                                ├─ 冲突表 sync_conflicts ←→ UI 冲突页
                                └─ SyncStatus 流 → 顶栏/移动端状态
```

- 同步引擎只依赖 `PlannerRepository` 暴露的库句柄与 `PlannerApi`，与界面/平台无关。
- Android 与 Windows 使用**同一个云端账号体系与同一套协议**；差异仅在 token 存储。

---

## 7. 关键技术决策与理由

| 决策 | 理由 | 备选与否决原因 |
|---|---|---|
| 复用现有 `sqlite3` 手写 SQL，不引入 Drift/ORM | 迁移链、事务、outbox 已稳定且有 356 项测试；换 ORM = 重写数据层 | Drift 需代码生成 + 迁移工具，风险高、收益低 |
| Android 使用 sqlite3 包预编译库 | API 24 系统 SQLite 3.9 不支持 `VACUUM INTO`/窗口函数；应用无法稳定 dlopen 系统库 | 用系统库会导致备份与查询在旧设备上失败 |
| 不新增路由框架 | 现有结构是分区切换 + 对话框/面板，Android 也只需底部导航 + 模态页 | go_router 等会引入第二套导航语义，且桌面外壳不需要 |
| 不加状态管理框架 | `ChangeNotifier + InheritedNotifier + StreamBuilder` 已覆盖；引入 Provider/Riverpod 会与现有 Scope 重复 | 迁移成本大、无功能收益 |
| Android 令牌存储用「MethodChannel + Keystore」而非 `flutter_secure_storage` | 该包的 Windows 实现 `#include <atlstr.h>`（需 VS ATL），会让本机 Windows 构建失败；Flutter 无法按平台裁剪依赖 | 直接引入第三方包：已验证会破坏 Windows 回归；自写 Keystore 通道约 120 行，边界清晰（B 写原生、C 写 Dart） |
| 单一 `main.dart` + 平台分支 | 保持唯一入口，避免两套启动逻辑漂移 | 多入口会让「Windows 行为不变」难以验证 |
| Android 应用身份 `com.jihuatai.planner` | 覆盖升级要求 applicationId 永不改变 | 用模板默认 `com.jihuatai.jihuatai` 语义混乱；发布后再改会变成新应用 |

---

## 8. 数据兼容与升级

| 项 | 策略 |
|---|---|
| 数据库 schema | 保持 v2；Android 与 Windows 共用同一迁移链。新迁移只能“加表/加列/加索引” |
| 数据目录 | Windows `<base>/data`；Android `<private>/data`；结构同构（`app.db`、`backups/`、`accounts/<ownerId>/`、`cloud_workspace.json`、`cloud_ui.json`） |
| 跨设备迁移 | 通过云端同步（不是拷文件）；同一账号在新设备登录后走绑定流程下载 |
| 备份格式 | 不变（JSON + 快照）；Android 的导出通道另行适配 |
| 版本号 | `pubspec.yaml version: 2.0.0+5` 同时决定 Android `versionName/versionCode`；升级必须递增 `+N` |
| 签名 | release 必须用固定 keystore（不入库）；debug 签名仅供开发安装 |

---

## 9. 模块边界

| 目录 | 所有者 |
|---|---|
| `lib/core/**`、`lib/data/**`（除新增 Android 云实现）、`lib/app/**`、`lib/main.dart`、`pubspec.*`、`docs/**` | 维护者 |
| `lib/mobile/**`、`test/mobile/**` | 月历模块 |
| `android/**`、`lib/platform/**`、`lib/bootstrap/android_bootstrap.dart`、`test/platform/**` | 每日面板模块 |
| `lib/data/cloud/android_secure_token_store.dart`、`lib/data/cloud/android_cloud_bootstrap.dart`、对应测试 | 数据层 |
| `lib/features/cloud_account/**` | 维护者（C 通过新文件扩展，A 只读） |

---

## 10. 反模式（出现即拒绝合并）

1. 在 `lib/mobile/**` 里直接 `SqlitePlannerRepository.open()` 或 `PlannerApi()`。
2. 复制 `PlannerTask`/`Project` 到移动端模型，或另建 `MobileRepository`。
3. 在 UI 里手写 SQL、直接读文件、直接发 HTTP。
4. 为 Android 修改 `lib/app/**` 的桌面布局/快捷键。
5. 把 token 写进 SQLite/JSON/日志；用内存存储代替安全存储还标成“已实现”。
6. 在 Android 上调用 `window_manager`、`Platform.environment` 或依赖 `%APPDATA%`。
7. 修改 `pubspec.yaml` 依赖版本（由维护者统一处理）。
8. 删除/重建用户数据库来“修复”问题。
