# 云账号与同步 UI 模块（数据层）

> 分支：`feature/cloud-account-ui`　基线：`baseline/cloud-sync-v2`（`8ef99ae`）
> 只依赖冻结接口 `lib/core/cloud/**`；不读写 SQLite、不发 HTTP、不 import `dart:io`。

## 1. 交付内容

| 文件 | 作用 |
|---|---|
| `cloud_account.dart` | 对外唯一入口（barrel） |
| `state/cloud_account_controller.dart` | 登录 / 恢复 / 退出 / 绑定 / 同步 / 冲突的状态编排 |
| `state/cloud_ui_preferences.dart` | 服务器地址普通配置接口（内存实现，持久化由 D 注入） |
| `ui/cloud_account_panel.dart` | 右侧抽屉面板（420 宽，未登录/已登录两态） |
| `ui/cloud_account_overlay.dart` | 抽屉浮层：打开/关闭、遮罩点击、Esc |
| `ui/sync_status_view.dart` | 状态→图标/色/文案映射 + 顶栏入口按钮 |
| `ui/binding_card.dart` | 首次绑定向导（5 种场景 + 备份提示 + 禁止上传分支） |
| `ui/conflict_page.dart` | 冲突处理页（字段差异 / 本机版本 / 云端版本 / 两种解决方式） |
| `ui/sign_in_view.dart` / `ui/connected_view.dart` / `ui/cloud_widgets.dart` | 登录表单、已连接视图、共享组件 |
| `util/*` | 地址校验、时间文案、错误文案、冲突载荷翻译（纯函数，有单元测试） |
| `demo/cloud_account_demo.dart` | 独立演示入口（真实 AppShell + Fake 服务，用于截图） |
| `test/features/cloud_account/**` | 61 个测试（widget + 纯函数） |

## 2. Agent D 接入（三步）

```dart
// 1) 应用启动：构造服务与控制器，恢复会话
final controller = CloudAccountController(
  services: CloudServices(account: accountService, sync: syncService),
  preferences: myPersistentPreferences, // 见 §5
);
await controller.initialize(); // 读配置 + restoreSession + inspectBinding

// 2) 顶栏：替换 V1 的云图标占位（同步状态 + 点击打开面板）
CloudSyncEntryButton(controller: controller)        // 窄窗口用 compact: true

// 3) AppShell 最外层 Stack：抽屉浮层（面板打开时覆盖右侧，不重排月历）
Stack(
  children: <Widget>[
    existingShell,
    CloudAccountOverlay(controller: controller),
  ],
)
```

退出应用时：`controller.dispose(); await services.close();`

可选接入点：

- `lib/app/settings_dialog.dart`：显示账号/服务器/自动同步开关，调用
  `controller.openPanel()` 或 `controller.signOut()`；
- 任何入口想直接打开面板：`controller.openPanel()`；
- 冲突数量提醒：`controller.conflictCount`（`SyncStatus.conflictCount` 的映射）。

## 3. 状态与文案

| 状态 | 顶栏/胶囊 | 面板说明 |
|---|---|---|
| 未登录 | 未登录 | 登录表单 + 「数据只保存在本机」 |
| 待确认关联 | 待确认关联 | 绑定向导；`立即同步` 禁用 |
| 已同步 | 已同步 | 最近成功同步时间、自动同步开关 |
| 正在同步 | 正在同步 | 显示 `SyncStatus.message`；按钮禁用 |
| 待同步 N 项 | 待同步 N 项 | 「本地保存：已保存到本机」+「待上传 N 项」+「最近上传」 |
| 离线 | 离线 | 「改动已保存在本机，恢复网络后自动上传」 |
| 同步失败 | 同步失败 | `lastError` + 「失败不会丢数据，可重试」 |
| 存在冲突 N | 存在冲突 N | 「处理冲突（N）」打开冲突页 |

关键语义：**「已保存到本机」不等于「已上传到云端」**，界面上分成两行，
不会把本地保存显示成云端成功。

## 4. 首次绑定的 5 种场景

`inspectBinding()` 返回的 `BindingSituation` 直接驱动 UI：

| 场景 | 主操作 | 禁止项 |
|---|---|---|
| 全新安装 + 云端有数据 | 创建本机工作区并下载 | 不提供「上传」 |
| 全新安装 + 云端为空 | 无需确认，直接可同步 | 不自动创建示例数据 |
| 本机有数据 + 云端为空 | 上传本机数据到该账号（带「先整库备份」提示） | 未点击前不调用 `applyBinding` |
| 两边都有数据 | 以云端为准（先备份并归档） | 不提供自动上传/自动合并 |
| 本机已绑定其他账号 | 为当前账号新建空工作区 / 取消登录 | 不上传旧账号数据 |

每个场景都写明「保留本地数据 / 合并方式 / 不直接覆盖 / 冲突会提示」；
`BindingResult.backupPath` 会显示在「本机数据 · 最近备份」行。

## 5. 服务器地址的保存

`CloudUiPreferences` 是注入接口（数据层 不允许 `dart:io`）：

```dart
abstract interface class CloudUiPreferences {
  Future<String?> readServerAddress();
  Future<void> writeServerAddress(String? address);
}
```

默认 `MemoryCloudUiPreferences` 只在进程内生效，用于测试与演示。
Agent D 接入时请注入持久化实现（例如写 `%APPDATA%\计划台\cloud_ui.json`
或复用数据层的配置文件），**只保存服务器地址，不要保存密码/token**。

## 6. 测试

```powershell
dart format lib/features/cloud_account test/features/cloud_account
flutter analyze                      # 零问题
flutter test test/features/cloud_account
```

覆盖：空地址、无效 HTTPS/非 https、错误账号、服务器不可达、登录成功、
Token 失效、离线、同步中、同步失败、待同步数量、冲突保留本机/取消、
退出账号、窗口 1100×700 / 1366×768 / 1440×900 缩放、密码遮挡切换；
另有 5 种绑定场景、备份路径、需要重启、入口 6 种状态、浮层打开/关闭/Esc。

## 7. 截图（真实运行）

```powershell
flutter build windows --debug -t lib/features/cloud_account/demo/cloud_account_demo.dart
build\windows\x64\runner\Debug\jihuatai.exe --scenario=binding
```

场景：`login` / `login-error` / `binding` / `both-have-data` / `connected` /
`pending` / `syncing` / `offline` / `failed` / `conflict`。
截图（1920×1080，150% 缩放下的物理像素）见 `docs/screenshots/cloud/`：

| 文件 | 内容 |
|---|---|
| `01-signin.png` | 未登录：服务器地址/账号/密码/记住地址/开发环境说明 |
| `02-signin-error.png` | 密码错误：失败标题 + 建议 |
| `03-binding.png` | 首次绑定：本机有数据、云端为空，四条说明 + 备份提示 + 两个选择 |
| `04-both-have-data.png` | 两边都有数据：禁止自动合并，只能以云端为准或保持本地 |
| `05-connected.png` | 已连接：账号/记录数/关联状态 + 云同步 + 自动同步 + 立即同步 |
| `06-pending.png` | 待同步 3 项；「本地保存」与「最近上传」分开显示 |
| `07-syncing.png` | 正在同步（按钮禁用，显示「正在上传 3/12」） |
| `08-offline.png` | 离线：改动保存在本机 |
| `09-failed.png` | 同步失败：原因 + 可重试 |
| `10-conflict.png` | 冲突页：字段差异表、本机/云端版本、三种处理方式 |

## 8. 已知限制 / 需要配合

1. `BindingInspection` 只有 `localLiveRecords` 总数，没有项目/阶段/任务/备注分项，
   面板只能显示总数（ACCOUNT_BINDING §5.3 要求分项，需维护者扩展契约）。
2. `SyncPhase` 没有 `needsReconcile`，恢复备份后的「需要重新同步」状态目前只能
   通过 `needsAttention + message` 表达。
3. 冲突的「手动合并」未实现（契约允许第一版只做保留本机/云端）。
4. 自动同步开关的初始值以 `SyncStatus.autoSyncEnabled` 为准；Fake 默认 false，
   真实实现默认应为 true。
5. 服务器地址持久化依赖 Agent D 注入实现（见 §5）。
6. 演示入口使用冻结的 `FakeSyncService`，其 `applyBinding` 返回的是占位文案
   （`Fake 绑定操作已记录`），真实文案由 每日面板模块 的实现提供。
