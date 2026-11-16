# 计划台 · 架构说明（V1.0）

> 本文说明代码如何分层、为什么这样分层、以及后续三个 Agent 的落点。
> 数据字段与接口签名分别见 [DATA_CONTRACT](DATA_CONTRACT.md) 与 [MODULE_API](MODULE_API.md)。

## 1. 分层

```
┌───────────────────────────────────────────────────────────────┐
│ 表现层  lib/app + lib/features                                │
│  AppShell / CalendarMonthView / DayDetailPanel / 主题与令牌     │
│  只依赖 contracts + models，不写 SQL、不碰文件系统              │
├───────────────────────────────────────────────────────────────┤
│ 契约层  lib/core/contracts                                    │
│  PlannerRepository（已冻结）：流式读 + 草稿式写 + 软删除         │
├───────────────────────────────────────────────────────────────┤
│ 领域层  lib/core/models                                       │
│  纯 Dart：LocalDate / LocalDateRange / TimeSlot / 四实体        │
│  零 Flutter 依赖，可被纯 Dart 单测直接覆盖                      │
├───────────────────────────────────────────────────────────────┤
│ 数据层  lib/data                                              │
│  数据层：SqlitePlannerRepository implements PlannerRepository │
│  唯一允许写 SQL 的地方；对外只暴露领域对象                      │
└───────────────────────────────────────────────────────────────┘

并行的开发期替身：lib/core/testing/InMemoryPlannerRepository
（完整语义、纯内存、不写磁盘，见 §6）
```

### 1.1 依赖规则（Code Review 必查）

| 允许 | 禁止 |
|---|---|
| `features/*` → `core/models`、`core/contracts`、`core/theme`、`core/format` | `core/*` 反向依赖 `features/*` |
| `app/*` → 全部 core + 两个 features 模块 | `features/*` 互相 import |
| `data/*` → `core/models`、`core/contracts` | `data/*` 依赖 `features/*` 或 `app/*` |
| `core/models` → 仅 `dart:*` | `core/models` import `package:flutter/*` |
| `core/testing` → `core/models`、`core/contracts` | 正式运行时把 `core/testing` 当数据源且不标注 |

> 月历的布局算法（周分段、车道分配、格子信息预算）必须写在 `calendar` 内部的纯函数/独立文件里，
> **不要写进 Widget 的 build**，这样 Android/Web 复用时可以直接搬。

## 2. 目录结构

```
jihuatai/
├─ lib/
│  ├─ main.dart                     入口：窗口配置、仓储装配、runApp
│  ├─ app/                          维护者维护
│  │  ├─ app.dart                   MaterialApp / 主题 / 中文本地化
│  │  ├─ app_scope.dart             InheritedNotifier 注入仓储 + UI 状态
│  │  ├─ app_shell.dart             侧栏 224 + 顶栏 56 + 月历 + 抽屉 420
│  │  └─ shell_state.dart           可见月份 / 选中日期 / 抽屉开关
│  ├─ core/
│  │  ├─ models/                    冻结：纯 Dart 领域模型
│  │  ├─ contracts/                 冻结：PlannerRepository
│  │  ├─ theme/                     冻结：tokens + ThemeData
│  │  ├─ format/                    冻结：日期/周数/时间文案
│  │  └─ testing/                   内存仓储 + 演示数据
│  ├─ features/
│  │  ├─ calendar/                  月历模块：CalendarMonthView
│  │  └─ day_detail/                每日面板模块：DayDetailPanel
│  └─ data/                         数据层：SQLite 仓储
├─ test/
│  ├─ core/                         领域/仓储/格式化单测（已存在）
│  └─ app/                          外壳冒烟测试（已存在）
├─ windows/                         Flutter Windows 平台工程
├─ docs/                            本文档集
├─ design/reference/                已确认效果图（当前缺失，见 UI_SPEC §0）
└─ scripts/                         环境/截图等工具脚本
```

## 3. 运行时数据流

```
用户操作（点日期 / 勾选 / 编辑）
  → 模块调用 PlannerRepository 的写方法（draft / 带 revision 的实体）
  → 内存实现：校验 → 写入 Map → 广播变更
     SQLite 实现：事务 → 写入表 + change_log → 通知监听
  → 所有 watch* 流重新计算查询结果并推送
  → StreamBuilder 重建对应区域
```

采用"流优先"而不是全局状态容器：
- 不需要手写"保存后刷新月历"，避免"改了任务但月历没变"这类最常见 bug；
- 范围查询由流参数表达，强制月历只订阅可见范围（性能约束）；
- 未来把内存实现换成 SQLite 实现，界面代码零改动。

**V1 不引入 Riverpod。** 外壳只有 4 个 UI 状态，用 `ChangeNotifier + InheritedNotifier`
足够；少一个依赖、少一层学习成本。若 V1.5 状态复杂化再评估。

## 4. 技术选型与理由

| 项 | 选择 | 理由 |
|---|---|---|
| 框架 | Flutter 3.50 stable / Dart 3.14 | 本机已验证可 AOT 编译 Windows exe |
| Material 组件 | `package:material_ui/material_ui.dart` | Flutter 3.47+ 起 `flutter/material.dart` 已弃用；新代码必须用独立包（否则 analyze 报 deprecated） |
| 窗口 | `window_manager ^0.7.0`（nativeapi 新 API） | 最小尺寸 1100×700、居中、标题；旧 `legacy.dart` 已标记将移除 |
| 本地库 | `package:sqlite3` + 系统 `winsqlite3.dll` | 本机无法从 GitHub 下载预编译库；用系统 DLL 的 hooks 已验证可构建。**不引入 Drift**：避免 build_runner 代码生成链，SQL 与迁移由 数据层 手写（表少、可控） |
| 日期 | 自写 `LocalDate` 值对象 | 日历日 ≠ 时间戳；避免时区漂移。不引 intl 全量包 |
| 状态 | `Stream` + `ChangeNotifier` | 见 §3 |
| 测试 | flutter_test（含 widget test） | 领域层是纯 Dart，可直接覆盖；内存仓储驱动 UI 测试 |
| 图标 | Material 内置线性图标 | 不额外引 `lucide_icons`，减少依赖；风格在 UI_SPEC 中约定 |

`pubspec.yaml` 是共享的依赖清单；新增依赖前请先在 Issue 中讨论其平台影响。

## 5. 应用生命周期

1. `main()`：`WidgetsFlutterBinding.ensureInitialized()`。
2. 原生窗口：取当前 `Window`，设置标题、最小尺寸、初始 1440×900、居中、显示。
3. 构造仓储。当前为 `InMemoryPlannerRepository()` + `seedDemoData()`，并以
   `isDemoData: true` 在侧栏标注；数据层 完成后替换为 SQLite 实现。
4. `runApp(PlannerApp(...))`；`PlannerApp` 在 `dispose` 时关闭仓储。
5. 窗口关闭即退出（V1 不做托盘/最小化到后台）。

## 6. 内存仓储（并行开发的替身）

`lib/core/testing/in_memory_planner_repository.dart` 完整实现 `PlannerRepository`：

- 校验、软删除、级联、乐观并发（revision）、排序规则与正式实现一致；
- 写入后通过 broadcast 流推送，`watch*` 先推当前值；
- 可注入 `clock` / `idGenerator`，测试可确定性复现；
- **明确非正式数据**：`isDemoData` 让 UI 显示「演示数据 · 未接入本地库」。

`seedDemoData()` 提供覆盖边界的演示数据：跨月阶段、同周多条阶段、有/无时刻任务、
已完成任务、未排期收件箱、两天的每日备注。详见 UI_SPEC §7。

## 7. 错误模型

- 仓储只抛三种异常：`PlannerValidationException`（输入非法）、
  `PlannerNotFoundException`（目标不存在/已删除）、`PlannerConflictException`（revision 过期）。
- 界面捕获后在模块内展示（表单错误 / SnackBar / 行内提示），**不吞异常、不弹裸 stack**。
- 数据层崩溃（磁盘占用、库损坏）属 数据层 范围：必须给出可恢复路径，禁止静默重建库。

## 8. 性能约束

- 月历只订阅"可见月份 ± 补齐的相邻周"：`watchTasksInRange(monthRange)`。
- 跨天阶段用区间重叠查询，禁止全表取回再在 Dart 里过滤。
- 全量 `watchAllTasks()` 只允许侧栏计数这类小规模用途，不得用于月历渲染。
- 索引要求见 DATA_CONTRACT §7；查询计划由 数据层 落实。

## 9. 未来同步预留（V1 不实现）

- 所有主键 UUIDv7；实体带 `createdAt / updatedAt / revision / deletedAt`。
- SQLite 层预留 `change_log`（数据层 建表，V1 只写不读）。
- 不实现 `SyncAdapter`；V2 再加，不改上层模型。

## 10. 已知技术债（有意接受）

1. 演示数据模式默认开启，正式数据要等 数据层。
2. 周/日视图、搜索、项目页、任务页、设置均为禁用占位（明确标注"即将"），避免虚假反馈。
3. 字体依赖系统 `Microsoft YaHei UI`；打包 Inter/Noto Sans SC 是 V1.5 项。
4. 月历占位实现没有做溢出计数与车道分配——正是 月历模块 的工作。
