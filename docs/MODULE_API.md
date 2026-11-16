# 计划台 · 模块接口约定（V1.0，已冻结）

> 模块 = 可替换的 Widget。本文固定它们的**构造参数、回调语义、数据来源与交互裁决**。
> 内部怎么画由 月历模块 / B 决定，**签名与语义不得改**，否则外壳与另一个模块会不兼容。
>
> 实现文件：
> - `lib/features/calendar/calendar_month_view.dart` → `CalendarMonthView`（月历模块）
> - `lib/features/day_detail/day_detail_panel.dart` → `DayDetailPanel`（每日面板模块）

## 1. 组装关系

```
PlannerApp
└─ AppScope(repository, shellState)          // 仓储 + UI 状态注入
   └─ MaterialApp(theme, zh_CN)
      └─ AppShell                            // 侧栏 224 / 顶栏 56 / 工作区
         ├─ CalendarMonthView   ← 剩余宽度
         └─ DayDetailPanel      ← 抽屉展开时宽 420（AnimatedContainer 200ms）
```

外壳负责：左侧导航、顶部工具栏、月份切换、今天、视图切换、搜索/同步/设置的占位提示、
新建任务入口（展开当日面板）、`Esc` 关闭抽屉、`T` 回到今天。

**模块不负责**：窗口边框、侧栏、顶栏、全局快捷键、跨模块状态容器。

## 2. CalendarMonthView（月历模块）

```dart
class CalendarMonthView extends StatelessWidget {
  const CalendarMonthView({
    super.key,
    required PlannerRepository repository,
    required LocalDate month,
    required LocalDate today,
    required LocalDate selectedDate,
    required ValueChanged<LocalDate> onSelectDate,
    required ValueChanged<LocalDate> onOpenDay,
  });

  final PlannerRepository repository;
  final LocalDate month;        // 可见月份，恒为 1 号（外壳传入 visibleMonth）
  final LocalDate today;        // 本机今天
  final LocalDate selectedDate; // 当前选中日
  final ValueChanged<LocalDate> onSelectDate;
  final ValueChanged<LocalDate> onOpenDay;
}
```

### 2.1 输入语义

- `month`：只保证是某月任意一天，外壳会传 1 号；**不要修改它**，翻月由外壳负责。
- `today`：渲染"今天"样式用；不要自己 `DateTime.now()`（测试需要固定日期）。
- `selectedDate`：可能不在 `month` 内（抽屉翻到相邻月时的短暂状态），此时不要崩溃。

### 2.2 回调语义

| 回调 | 触发 | 外壳行为 | 要求 |
|---|---|---|---|
| `onSelectDate(date)` | 单击格子空白 / 单击任务条目 / 单击阶段 | 设为选中；若跨月则切到该月 | 不要做"选中即打开抽屉" |
| `onOpenDay(date)` | **双击**格子空白 | 选中并展开右侧面板 | 必须是双击（280ms 内两次、位移 < 4px） |

- 单击任务条目 → `onSelectDate(task.scheduledDate!)`，再 `onOpenDay(同一天)`，让用户在面板里编辑；**月历不要自建任务编辑弹窗**（避免两套编辑器）。
- 单击跨天阶段 → `onSelectDate(span.startDate)`；V1 不弹阶段编辑框。
- 双击任务 / 阶段：不响应（防误触）。

### 2.3 数据来源（必须）

```dart
final range = LocalDateRange(month.firstDayOfMonth.startOfWeek(), month.lastDayOfMonth.endOfWeek());
StreamBuilder<List<PlannerTask>>(stream: repository.watchTasksInRange(range), ...)
StreamBuilder<List<PlanSpan>>(stream: repository.watchSpansInRange(range), ...)
StreamBuilder<List<Project>>(stream: repository.watchProjects(), ...)
```

- **禁止**用 `watchAllTasks()` 在月历里过滤范围。
- 流已按契约排序，不要重新定义排序（除阶段车道分配需要外）。
- 项目色通过 `ProjectColor.uiColor`（`core/theme/app_theme.dart` 扩展）转为 `Color`。

### 2.4 必须实现的视觉规则（详见 UI_SPEC §5）

1. 周一开头，补齐相邻月整周；今天 / 选中 / 非本月三档样式。
2. 跨天阶段车道：最多 2 条，超出折叠为 `+N 条安排`；跨周/跨月按周分段，
   仅真实首端左圆角、真实末端右圆角，中间段直角 + 延续指示。
3. 单日任务：最多 3 条，超出 `+N 项`；颜色用项目色小点/竖条，**不显示开始时间**。
4. hover 显示 tooltip（完整标题 / 项目 / 时间）。
5. 溢出 `+N` 点击展开"当日全部"浮层（V1 可简化为 `onOpenDay`）。
6. 格子最小高度 96 逻辑像素；1366×768 不横向滚动。

### 2.5 保留 Key

自动化测试依赖日期格子的 Key：

```dart
ValueKey<String>('day-${date.iso}')   // 例：day-2026-11-14
```

重写时请保留，否则 `test/app/shell_smoke_test.dart` 的双击用例会失效。

## 3. DayDetailPanel（每日面板模块）

```dart
class DayDetailPanel extends StatelessWidget {
  const DayDetailPanel({
    super.key,
    required PlannerRepository repository,
    required LocalDate date,
    required LocalDate today,
    required VoidCallback onClose,
    required ValueChanged<LocalDate> onDateChange,
  });

  final PlannerRepository repository;
  final LocalDate date;
  final LocalDate today;
  final VoidCallback onClose;
  final ValueChanged<LocalDate> onDateChange;
}
```

### 3.1 回调语义

| 回调 | 触发 | 外壳行为 |
|---|---|---|
| `onClose()` | 右上角关闭 / 面板内取消 | 收起抽屉（200ms 动画），保留选中日 |
| `onDateChange(newDate)` | 头部前一天 / 后一天 | 设为选中并定位月份，**抽屉保持展开** |

**任务的一切写操作都在面板内部完成**，直接调用 `repository`：

```dart
await repository.createTask(PlannerTaskDraft(...));
await repository.updateTask(task.copyWith(...));
await repository.deleteTask(task.id);
await repository.saveDailyNote(date, body: ..., focusItems: ...);
```

不要在面板里改 `AppShell` 的状态或自己实现"关闭后刷新"——流会自动刷新。

### 3.2 数据来源（必须）

```dart
final dayRange = LocalDateRange.singleDay(date);
repository.watchTasksInRange(dayRange)     // 当日任务
repository.watchSpansInRange(dayRange)     // 跨到当天的阶段（用于顶部阶段胶囊）
repository.watchDailyNote(date)            // 当日备注
repository.watchProjects()                 // 项目名与颜色
```

### 3.3 必须实现的行为

1. 头部：日期大标 + 星期 + `完成 x/y · 百分比` + 前一天/后一天/关闭。
2. 时间轴：按时间升序；无时刻任务沉到「未安排时间」分组（虚线分隔）。
3. 任务条目：勾选框、时间、项目色点、标题、项目名/优先级；hover 出现编辑/删除。
4. 新建任务：默认落在当前 `date`；可只填标题，不强制填时间。
5. 编辑任务：标题、项目、优先级、时间、备注；允许清空时间（改回"只排到日"）。
6. 重叠提示：不阻止保存，条目标橙色角标 + tooltip「与你 14:00–15:00 的安排重叠」。
7. 当日备注：失焦自动保存（防抖），显示「已保存」；「当日重点」最多 3 条。
8. 空态：居中「今天还没有安排」+ 主按钮。
9. 所有写操作失败（`PlannerException`）必须以可读中文提示，不得静默失败。

### 3.4 不做什么

- 不做项目 CRUD（V1 归项目页，后续版本）。
- 不做跨天阶段编辑（只展示）。
- 不做统计、计时、提醒。

## 4. 跨模块共同规则

1. **单一编辑入口**：任务编辑只在日面板；月历只负责展示与导航。
2. **数据只经仓储**：模块不共享可变对象，不互相持有引用。
3. **日期只从参数来**：模块内不要读系统时钟，统一用传入的 `today` / `date`。
4. **颜色只从令牌来**：不写死十六进制；项目色用 `ProjectColor`。
5. **错误文案中文**，不暴露异常堆栈。
6. **不要修改 `lib/app/`**：需要外壳配合（例如额外回调）先提给维护者。
7. **不要修改主题令牌**：需要新字号/色值先提需求。
8. **测试放在自己的目录**：A → `test/features/calendar/`，B → `test/features/day_detail/`，
   C → `test/data/`。共享的 `test/core`、`test/app` 只读。

## 5. 交互裁决表（两个模块共同遵守）

| 用户动作 | 落点 | 结果 |
|---|---|---|
| 单击 | 日期格子空白 | 选中该日，布局不变 |
| 双击 | 日期格子空白 | 选中 + 展开右侧面板 |
| 单击 | 单日任务 | 打开该日面板（`onSelectDate` + `onOpenDay`） |
| 单击 | 跨天阶段 | 选中阶段起始日（V1 不弹编辑） |
| 双击 | 任务 / 阶段 | 不响应 |
| 右键 / 长按 | 任意 | V1 不做上下文菜单（预留） |
| 拖拽 | 任务 / 阶段 | V1.5 |
| Esc | 全局 | 收起面板 |
| T | 全局 | 回到今天（外壳） |

## 6. 接口冻结与变更

- 上述两个构造函数与回调签名、`ValueKey('day-...')`、仓储方法名均已冻结。
- 新增内部 Widget / 私有 helper 不受限制。
- 确需新增参数（例如"聚焦某个任务"）：向维护者提交最小变更方案，
  由其在主干同时改外壳、两个模块与本文，再同步三个工作区。
- 模块文件内可以自由拆分：A 可在 `features/calendar/` 下新建
  `month_grid.dart`、`span_lane.dart`、`month_layout.dart`；B 可新建
  `task_tile.dart`、`task_editor.dart`、`note_editor.dart`。**目录归属不变**。
