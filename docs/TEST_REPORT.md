# 计划台 V1.0 · 测试与验证报告

测试环境：Windows 11 x64 · Flutter 3.50.0 stable / Dart 3.14.0 · 150% 系统缩放。

## 1. 静态检查

```
flutter analyze
→ No issues found! (ran in 2.6s)
```

## 2. 自动化测试

```
flutter test
→ All tests passed!
```

| 范围 | 内容 |
|---|---|
| `test/core/` | LocalDate / LocalDateRange / TimeSlot / 模型不变量 / 文案格式 / 内存仓储行为基准 |
| `test/data/` | SQLite CRUD、软删除、级联、乐观并发、范围查询与排序、日期不漂移、迁移、持久化、备份导出/校验/恢复/回滚、行为对等 |
| `test/features/calendar/` | 整周网格、今天/选中/非本月、跨天阶段分周分段与车道、溢出折叠、单双击语义、右键拖选区间、无障碍标签 |
| `test/features/day_detail/` | 时间轴排序、未安排分组、任务增删改、清空时间、重叠提示、备注防抖/关闭落库、失败提示、最小高度滚动 |
| `test/app/` | 外壳冒烟、双击开面板/Esc、项目管理（新建→阶段→归档）、任务勾选完成流转、侧栏视图入口、侧栏悬停与选中态、右键拖选新建跨天安排（颜色/未归类/双击归类）、SQLite 重启持久化、备份→删除→恢复一致性 |

最终结果：**237 个用例全部通过**（`flutter test` 退出码 0）。

## 3. 合并门禁（按 C → A → B 顺序）

| 步骤 | analyze | test |
|---|---|---|
| 合并 数据层 | ✅ | ✅ 134 |
| 合并 月历模块 | ✅ | ✅ 178 |
| 合并 每日面板模块 | ✅ | ✅ 216（修复共享冒烟测试的占位断言） |
| 接通 SQLite + 核心入口 | ✅ | ✅ 221 |

冲突情况：三次合并均无代码冲突（各自目录边界清晰）；仅 `lib/core/testing` 无改动，
`test/app` 的占位面板断言由集成方更新为新契约（`day-detail-<date>` Key）。

## 4. Windows 构建

```
flutter build windows --release
→ √ Built build\windows\x64\runner\Release\jihuatai.exe   (109.7s)
```

发行产物包含：`jihuatai.exe`、`flutter_windows.dll`、`cnativeapi.dll`、`dartjni.dll`、
`data\`（Flutter 资源与图标）。**单独复制 exe 不可运行**。

## 5. 真实运行验证

启动方式：在干净 `%APPDATA%\计划台` 下运行发行版 exe。

| 项 | 结果 | 证据 |
|---|---|---|
| 首次启动自动建库 | ✅ 生成 `app.db` + WAL | `docs/screenshots/v1-first-run.png` |
| 月历 + 3 项目 + 6 任务 + 2 跨天阶段 | ✅ 正常渲染、跨周分段与延续箭头 | `docs/screenshots/v1-home-data.png` |
| 当日面板（最小窗口 1100×700） | ✅ 时间轴/未安排/进度/备注/新建任务 | `docs/screenshots/v1-day-panel.png` |
| 关闭 → 重新打开数据完整 | ✅ 项目数、任务、阶段一致 | `docs/screenshots/v1-restart-persistence.png` |
| 1100×700 布局 | ✅ 7 列不横向滚动、文本省略、抽屉不挤压崩坏 | 同上 |

## 6. 验收流程对照（A–H）

| 流程 | 状态 | 说明 |
|---|---|---|
| A 创建项目和跨天安排 | ✅ 自动化 | `integration_flow_test`（新建项目→新建阶段→归档）；`test/data` 阶段 CRUD |
| B 双击日期创建五条每日任务 | ✅ 自动化 | 双击语义 `shell_smoke_test`；面板新建/校验 `day_detail_panel_test`（逐条创建，非一次性五条） |
| C 修改任务并勾选完成 | ✅ 自动化 | `day_detail_panel_test` 编辑/清空时间/完成；`integration_flow_test` 勾选后移入已完成 |
| D 跨月显示多个项目 | ✅ 自动化 | `month_layout_test` 跨月阶段、`calendar_month_view_test` 两月显示；真实截图含 3 项目 2 阶段 |
| E 关闭重启数据完整 | ✅ 真实运行 + 自动化 | exe 重启截图；`backup_persistence_test` 关闭重开断言 |
| F 备份数据库并从备份恢复 | ✅ 自动化（服务层） | `backup_persistence_test`：导出→删除→恢复→逐项一致；UI 入口已接通（鼠标端到端未执行） |
| G 断网完成基础操作 | ✅ 设计保证 | 应用无任何网络请求；依赖离线解析；运行期不联网 |
| H 多项目关联与显示 | ✅ 真实运行 + 自动化 | 3 项目/任务/阶段计数与颜色正确；`repository_crud_test` 级联与关联 |

## 7. 未覆盖 / 限制

- `design/reference/approved-home.png` 缺失，无法做像素级效果图对照（见 KNOWN_ISSUES）。
- 备份恢复的对话框未做真实鼠标端到端（服务层测试完整覆盖，UI 已接线）。
- 项目页真实截图未采集（GUI 自动化坐标在沙箱下不稳定）；页面由 widget 测试覆盖。
- 验证机为 150% 缩放；1366×768 物理分辨率未单独设置，等价验证为 1100×700 逻辑窗口。
- 未制作 Inno Setup 安装包，提供便携发行目录 + zip。
