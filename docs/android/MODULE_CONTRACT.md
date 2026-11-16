# 计划台 Android · 公共接口契约（MODULE_CONTRACT，已冻结）

> 本文件是 月历模块 / B / C 与维护者之间的**唯一接口依据**。签名、语义、错误类型、
> 所有权全部冻结；任何改动必须先改本文件，并经维护者合并到 `android/base` 后，
> 三个 worktree 同步 rebase。
>
> 冻结基线：`android/base`（标签 `android-base`，精确 Hash 用 `git rev-parse android-base^{commit}`；
> 代码基线提交 `6e561c1`）。源码位置以 `lib/` 为准，
> 本文件与代码不一致时**以本文件为准并立即修正代码**。

---

## 0. 总原则

1. **只有一套领域模型与一套 Repository**。禁止新增 `MobileTask`、`AndroidRepository`、
   `TaskModel` 等并行模型；Android 直接复用 `PlannerTask` / `PlanSpan` / `Project` / `DailyNote`。
2. **UI 不碰 SQLite / HTTP / 文件**。UI 只依赖：
   - `PlannerRepository`（本地数据）
   - `CloudAccountService` / `SyncService`（云端）
   - `PlannerShellState`（界面状态）
   - `SecureTokenStore`（仅 B/C 内部使用）
3. **读用流、写用 Future**；所有写操作在 `try/catch` 中处理 `PlannerException`。
4. **日期无时区**：`LocalDate`（`YYYY-MM-DD`），范围闭区间。
5. **不得自行升级依赖**：`pubspec.yaml` 由维护者维护；缺依赖提需求。

---

## 1. 依赖注入：`AppScope` / `CloudScope`

```dart
// lib/app/app_scope.dart
class AppScope extends InheritedNotifier<PlannerShellState> {
  final PlannerRepository repository;
  PlannerShellState get shell;
  static AppScope of(BuildContext context); // 找不到会 assert
}

// lib/app/cloud_scope.dart
class CloudScope extends InheritedNotifier<CloudAccountController> {
  final CloudServices services;
  static CloudScope? maybeOf(BuildContext context);       // 离线时为 null
  static CloudAccountController? controllerOf(BuildContext context);
}
```

- Android 与 Windows 的 `AppScope` 用法完全相同：`AppScope.of(context).repository`。
- 云能力必须用 `maybeOf` / `controllerOf`：离线（Android 尚未接入令牌存储时）返回 null，
  界面要退化，不得崩溃或显示“云端为空”。

---

## 2. 项目列表（Android 页面如何拿项目）

```dart
Stream<List<Project>> watchProjects({bool includeArchived = false});
Future<Project?> findProject(String id);
```

- 默认排除 `archived`，**保留 `paused`**；排序：`sortOrder ↑ → createdAt ↑`。
- 侧栏/项目页用 `watchProjects()`；归档页用 `watchProjects(includeArchived: true)` 再自行过滤。
- 颜色：`Project.color` 是 `ProjectColor`（固定调色板）；新建时 `ProjectDraft.color == null`
  由仓储自动取色，UI 不要自己造颜色。

使用示例：

```dart
StreamBuilder<List<Project>>(
  stream: repository.watchProjects(),
  builder: (context, snapshot) {
    final projects = snapshot.data ?? const <Project>[];
    // 用 projects；不要在这里排序/过滤已删除（仓储已保证）
  },
);
```

---

## 3. 月历数据（一个月的任务与跨天安排）

```dart
Stream<List<PlannerTask>> watchTasksInRange(LocalDateRange range);
Future<List<PlannerTask>> tasksInRange(LocalDateRange range);
Stream<List<PlanSpan>> watchSpansInRange(LocalDateRange range);
```

**月历必须一次查整月网格范围**（含上下月补齐的 6 周），不要按天循环订阅：

```dart
final grid = MonthGrid.of(visibleMonth); // lib/features/calendar/month_layout.dart
final taskStream = repository.watchTasksInRange(grid.range);
final spanStream = repository.watchSpansInRange(grid.range);
final projectStream = repository.watchProjects();
```

- `watchTasksInRange`：只返回 `scheduledDate` 落在闭区间内的任务；顺序固定（日期 → 时间 → 优先级 → sortOrder → createdAt）。
- `watchSpansInRange`：返回与区间**有交集**的跨天阶段（`start <= range.end && end >= range.start`）；
  跨月阶段会同时出现在两个月，由视图自行分段（`layoutMonthSpans` 已实现）。
- 现有组件 `CalendarMonthView` 已封装上述三条流 + 网格计算，Android 可直接复用
  （构造参数见 §10）；如需新布局，也必须从这三条流取数。

---

## 4. 任务查询 / 创建 / 修改 / 删除

```dart
// 读
Stream<List<PlannerTask>> watchTasksInRange(LocalDateRange range);
Stream<List<PlannerTask>> watchUnscheduledTasks();          // 收件箱
Stream<List<PlannerTask>> watchTasksForProject(String id);
Stream<List<PlannerTask>> watchAllTasks();                  // 仅统计/小数据量，不要用于月历
Stream<PlannerTask?> watchTask(String id);
Future<PlannerTask?> findTask(String id);
Future<List<PlannerTask>> tasksInRange(LocalDateRange range);

// 写（返回写入后的新实体，revision 已 +1）
Future<PlannerTask> createTask(PlannerTaskDraft draft);
Future<PlannerTask> updateTask(PlannerTask task);
Future<void> deleteTask(String id);
```

规则（全部由仓储保证，UI 不要重复实现）：

| 行为 | 约定 |
|---|---|
| 完成/取消完成 | 直接 `updateTask(task.copyWith(status: TaskStatus.done))`；`completedAt` 由仓储维护 |
| 软删除 | `deleteTask` 只写 `deletedAt`；列表流会自动不再返回它 |
| 乐观并发 | `updateTask` 必须传最新 `revision`；冲突抛 `PlannerConflictException`，提示用户刷新后重试 |
| 移动到别的日期 | `copyWith(scheduledDate: ...)`；`null` 表示移入收件箱 |
| 固定时间 | `timeStartMinute` + `timeDurationMinutes` 必须同时为 null 或同时有值；越界抛 `PlannerValidationException` |
| 阶段归属 | 带 `spanId` 时，阶段必须存在且与任务同项目 |

Android 新建任务的默认值必须与桌面一致（见 `lib/features/day_detail/task_editor.dart` 的
`TaskEditorInput`）：默认 `priority = medium`、`status = todo`、无固定时间。

---

## 5. 跨天项目阶段（安排）

```dart
Stream<List<PlanSpan>> watchSpansInRange(LocalDateRange range);
Stream<List<PlanSpan>> watchSpansForProject(String projectId);
Stream<PlanSpan?> watchSpan(String id);
Future<PlanSpan?> findSpan(String id);

Future<PlanSpan> createSpan(PlanSpanDraft draft);
Future<PlanSpan> updateSpan(PlanSpan span);
Future<void> deleteSpan(String id);
```

- 阶段是**独立实体**，不是“任务区间”：任务通过 `spanId` 归属阶段（可为空）。
- 排序：`startDate ↑ → endDate ↓ → sortOrder ↑`；删除阶段只把任务的 `spanId` 置空，任务保留。
- 月历上“拖选一段日期”新建阶段：`onRangeSelected` 回调给出闭区间起止，外壳负责弹窗与写库
  （桌面实现见 `app_shell.dart` `_createSpanFromRange`；Android 可复用 `showSpanEditorDialog`，
  月历模块 决定用底部面板还是全屏页）。
- 「未归类」分组由 `ensureUnfiledProject(repository)` 按需创建，不要硬编码项目 ID。

---

## 6. 每日备注

```dart
Stream<DailyNote?> watchDailyNote(LocalDate date);  // 没有记录 = null（不等于空备注）
Future<DailyNote?> findDailyNote(LocalDate date);

Future<DailyNote> saveDailyNote(
  LocalDate date, {
  String body = '',
  List<String> focusItems = const <String>[],
});
```

- 同一天最多一条记录（`ux_notes_date_alive` 唯一索引）；保存是 upsert。
- `focusItems` 最多 3 条、单条 ≤ 60 字，超限抛 `PlannerValidationException`。
- **草稿不要直接每次按键都写库**：桌面端用 600ms 防抖 + 失焦/切日期强制落库
  （`day_detail_panel.dart` 的 `_saveNote`），Android 必须沿用同样策略，避免写放大。
- 空 `body` 且无重点时，桌面端会删除该备注记录（保持“无记录 = null”语义）；Android 沿用。

---

## 7. 云端账号登录与会话恢复

```dart
// lib/core/cloud/cloud_services.dart（冻结）
abstract interface class CloudAccountService {
  Stream<CloudAccount?> observeAccount();     // 先推当前值
  CloudAccount? currentAccount();
  Future<ServerHandshake> connectServer(Uri baseUrl); // GET /api/planner/health
  Future<CloudAccount> login({required String username, required String password});
  Future<CloudAccount?> restoreSession();     // 无会话/过期返回 null
  Future<void> logout({bool revokeRemoteSession = true});
  Future<void> close();
}
```

- **服务器地址必须 https**；仅 localhost/127.0.0.1 允许 http（`CloudAccountService` 契约）。
- 登录成功**不会自动上传本地数据**；数据归属必须走绑定流程（§8）。
- 会话 token 只允许存 `SecureTokenStore`；禁止写入 SQLite、JSON、日志。
- 账号工作区：绑定“以云端为准”后会切到 `<data>/accounts/<ownerId>/app.db`；
  Android 组合根已按同一规则实现（`cloud_workspace.json` 指针）。

---

## 8. 绑定检查 / 手动同步 / 状态监听

```dart
abstract interface class SyncService {
  Stream<SyncStatus> observeSyncStatus();     // 先推当前值
  SyncStatus get status;
  Future<SyncResult> syncNow({SyncMode mode = SyncMode.incremental});
  Future<SyncResult> uploadNow();
  Future<SyncResult> downloadNow({SyncMode mode = SyncMode.incremental, bool overwriteLocal = false});
  Future<void> enableAutoUpload(bool enabled);
  Future<void> enableAutoDownload(bool enabled);
  Future<void> enableAutoSync(bool enabled);  // 兼容旧调用
  Future<List<SyncConflict>> listConflicts();
  Future<SyncResult> resolveConflict(String id, ConflictResolution resolution, {Map<String, Object?>? mergedPayload});
  Future<BindingInspection> inspectBinding(); // 只读，不得写入/上传
  Future<BindingResult> applyBinding(BindingChoice choice);
  Future<void> close();
}
```

UI 侧推荐直接用 `CloudAccountController`（已封装状态机与提示文案）：

```dart
controller.addListener(...);                 // ChangeNotifier
await controller.initialize();               // 恢复会话 + 检查绑定
controller.syncStatus;                       // SyncStatus（phase/outcome/message…）
await controller.syncNow();                  // 一键双向
await controller.uploadNow();                // 只上传
await controller.downloadNow();              // 只下载（有本地改动时 UI 需二次确认）
controller.bindingStage;                     // idle/checking/needsChoice/applying/ready/…
await controller.chooseBinding(choice);      // 绑定选择
controller.isSignedIn / canSync / isSyncing; // 顶栏状态
```

**语义红线**：

- `inspectBinding` 不得产生任何写入或上传；“不知道云端有多少”不得当成“云端为空”。
- `downloadNow(overwriteLocal: true)` 是破坏性操作，必须先整库备份并让用户二次确认
  （`CloudAccountController` 已实现确认文案与备份路径展示）。
- `syncNow` 同一时刻只允许一个在跑；重复调用复用/排队，不得并发写本地库。
- 断网返回 `SyncOutcome.offline`，不抛裸异常；未登录返回 `authRequired`。
- `logout` 不删除本地数据与账号工作区。

---

## 9. Android 本地数据库初始化与平台安全存储

### 9.1 目录解析（新增，平台适配层）

```dart
// lib/platform/app_paths.dart
abstract final class AppPaths {
  static Future<String> resolveBaseDirectory(); // Android: path_provider 私有目录；桌面: %APPDATA%\计划台
}

// lib/data/planner_paths.dart（新增运行期注入，桌面行为不变）
static bool useBaseDirectory(String? path);     // 必须在打开数据库前调用
static String? get baseDirectoryOverride;
```

顺序固定：

```dart
PlannerPaths.useBaseDirectory(await AppPaths.resolveBaseDirectory());
final dataDirectory = PlannerPaths.defaultDataDirectory();     // <base>/data
final databasePath  = PlannerPaths.defaultDatabasePath();       // <base>/data/app.db
final repository    = SqlitePlannerRepository.open(databasePath: databasePath);
```

Android 上若未注入就调用 `PlannerPaths.*`，会抛 `LocalDatabaseException`（**不会**退回临时目录）。
这条是硬约束：数据必须落在应用私有目录，卸载/备份行为可预期。

### 9.2 安全令牌存储（冻结接口，Android 待实现）

```dart
// lib/data/cloud/secure_token_store.dart
abstract interface class SecureTokenStore {
  bool get isAvailable;
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
```

- Windows 实现：`WindowsCredentialStore`（保持不动）。
- Android 实现：`AndroidSecureTokenStore`（数据层 写 Dart 侧），底层通过**冻结的平台通道**
  调用原生 Keystore（每日面板模块 写 Kotlin 侧）：

  ```
  MethodChannel('com.jihuatai.planner/secure_store')
    Future<String?> read(String key)     // 无值返回 null
    Future<void>   write(String key, String value)
    Future<void>   delete(String key)
    Future<bool>   isAvailable()
  ```

  - 原生侧：Android Keystore 生成 AES-256-GCM 密钥（`setUserAuthenticationRequired(false)`），
    密文与 IV 存 `SharedPreferences`（应用私有）；密钥不可导出。
  - 不引入 `flutter_secure_storage`：其 Windows 实现依赖 ATL（`atlstr.h`），会让本机 Windows
    构建失败；Android 只需要 Keystore，自己实现通道更可控。
  - 通道异常统一转 `CloudException`；**禁止**降级为明文文件/内存。
  - 通道实现归 B（`android/app/src/main/kotlin/.../SecureStoreChannel.kt`），Dart 客户端归 C；
    两侧的 key 命名（`JihuaTai/<key>`）、编码（UTF-8）、大小上限（≤ 8KB）必须一致。

### 9.3 Android 云端组装入口（冻结函数签名，数据层 实现）

```dart
// lib/data/cloud/android_cloud_bootstrap.dart
Future<CloudServices?> createAndroidCloudServices({
  required SqlitePlannerRepository repository,
  required String dataDirectory,
});
```

- 返回 null = 本轮不启用云（离线模式）。
- 返回值必须满足 §8 的所有语义；内部用 `AndroidSecureTokenStore` + 现有
  `PocketBaseAccountService` / `PlannerApi` / `SqliteCloudSyncService`，**不要新写同步引擎**。
- 组合根（`lib/bootstrap/android_bootstrap.dart`）已按此签名调用并把 `CloudServices` 包成
  `CloudAccountController`；实现方无需修改组合根。

### 9.4 数据库本身不需要 Android 专用实现

`PlannerDatabase` / `SqlitePlannerRepository` / `BackupService` 全部与平台无关，Android 直接复用。
唯一平台差异是 **SQLite 原生库来源**（pubspec hooks）：Android 使用 sqlite3 包自带的预编译库。

---

## 10. 导航 / 日期选中 / 任务编辑回调（UI 契约）

### 10.1 移动端根组件（月历模块 实现，签名冻结）

```dart
class MobileApp extends StatefulWidget {
  const MobileApp({
    super.key,
    required PlannerRepository repository,
    bool isDemoData = false,
    LocalDate? today,                 // 仅测试注入
    String? databasePath,             // 设置页展示
    CloudServices? cloudServices,     // 离线为 null
    CloudAccountController? cloudController,
    String? dataDirectory,
  });
}
```

- `MobileApp` 内部必须创建/持有 `PlannerShellState`，并提供 `AppScope`（以及有云时的 `CloudScope`）。
- 必须在 `initState` 调 `controller.initialize()`，在 `dispose` 释放 controller/services/repository
  ——与 `PlannerApp` 完全一致（可直接复制其生命周期逻辑）。
- `MainActivity` 启动后只 `runApp`，不要求 Android 侧做任何导航参数注入。

### 10.2 界面状态（复用，不改）

```dart
class PlannerShellState extends ChangeNotifier {
  LocalDate get today;
  LocalDate get selectedDate;
  LocalDate get visibleMonth;   // 始终是 1 号
  AppSection get section;       // calendar/projects/tasks/completed/archive
  bool get isDrawerOpen;

  void selectDate(LocalDate date);   // 单击：只改选中
  void openDay(LocalDate date);      // 双击/点任务：选中 + 展开当日
  void toggleDay(LocalDate date);
  void closeDrawer();
  void shiftDay(int delta);
  void shiftMonth(int delta);
  void showMonthOf(LocalDate date);
  void goToToday();
  void showSection(AppSection section);
  void openProject(String projectId);
}
```

### 10.3 月历组件（可直接复用）

```dart
const CalendarMonthView({
  required PlannerRepository repository,
  required LocalDate month,          // 传 shell.visibleMonth
  required LocalDate today,          // 传 shell.today
  required LocalDate selectedDate,   // 传 shell.selectedDate
  required ValueChanged<LocalDate> onSelectDate,
  required ValueChanged<LocalDate> onOpenDay,
  void Function(LocalDate start, LocalDate end)? onRangeSelected, // 可选：拖选建安排
  ValueChanged<PlanSpan>? onOpenSpan,                             // 可选：编辑安排
});
```

- 组件内部不读系统时钟、不碰数据库；日期只从参数来。
- 触屏上 `onOpenDay` 建议由单击或双击触发（由外壳决定），组件本身不假设鼠标。

### 10.4 当日面板（可直接复用）

```dart
const DayDetailPanel({
  required PlannerRepository repository,
  required LocalDate date,
  required LocalDate today,
  required VoidCallback onClose,
  required ValueChanged<LocalDate> onDateChange,
});
```

- 面板内部完成：任务列表、完成勾选、内联新建/编辑/删除、每日备注防抖保存。
- 手机端建议放在 `showModalBottomSheet(isScrollControlled: true)`（当前骨架即此做法）；
  平板端可复用桌面右侧抽屉的语义。
- 面板切日期用 `onDateChange`（外壳负责 `shell.openDay(date)` 并保持展开）。

### 10.5 任务编辑回调

- 复用 `TaskEditor` / `TaskEditorInput`（`lib/features/day_detail/task_editor.dart`）：
  `onSubmit` 返回错误文案（null 表示成功），由调用方决定关闭还是留在编辑器。
- 编辑中的草稿只存在于组件内部；写库仍走 `repository.createTask/updateTask`。
- 移动端如果改用全屏编辑页，必须保留同样的字段校验与错误文案（见 `UI_SPEC.md` §7）。

---

## 11. UI 开发用的 Fake（月历模块 必须用它独立开发）

```dart
// 内存仓储：与 SqlitePlannerRepository 语义一致（软删除/并发/级联/排序）
final repository = InMemoryPlannerRepository();
await seedDemoData(repository);                 // 演示数据（项目/任务/安排/备注）

// 云 Fake：登录、绑定、同步、冲突、失败注入
final cloud = FakeCloudServices();              // 见 lib/core/cloud/fake_cloud_services.dart
await cloud.account.login(...);                 // 或直接注入已登录账号
final controller = CloudAccountController(services: cloud, preferences: MemoryCloudUiPreferences());
```

- `InMemoryPlannerRepository` 已通过 `repository_parity_test.dart` 与 SQLite 版本对齐；
  UI 用 Fake 开发不需要数据库、不需要网络。
- `FakeSyncService` 可注入离线/冲突/失败，验证移动端状态展示。
- **禁止**在 UI 代码里直接 `new SqlitePlannerRepository` 或 `PlannerApi`。

---

## 12. 变更流程

1. 任何签名/语义变更：先改本文件 → 维护者评审 → 合并到 `android/base` →
   三个 worktree `git rebase android/base`。
2. 新增公共依赖：只由维护者改 `pubspec.yaml`/`pubspec.lock`，并在本文件登记。
3. 发现现有接口不够用：优先在现有接口上做**向后兼容**扩展（可选参数/新方法），
   不要复制一套。例：`downloadNow` 的 `overwriteLocal` 就是向后兼容扩展的范式。
