/// 云端账号与同步 UI 模块的公共入口。
///
/// Agent D 只需要 import 这个文件，然后：
/// 1. 创建并 `initialize()` 一个 [CloudAccountController]；
/// 2. 顶栏放 [CloudSyncEntryButton]（窄窗口用 `compact: true`）；
/// 3. 在 AppShell 的最外层 Stack 里放 [CloudAccountOverlay]；
/// 4. 应用退出时调用 `controller.dispose()` 与 `services.close()`。
///
/// 详细接入说明见 `lib/features/cloud_account/README.md`。
library;

export '../../core/cloud/cloud.dart';
export 'state/cloud_account_controller.dart';
export 'state/cloud_ui_preferences.dart';
export 'ui/cloud_account_overlay.dart';
export 'ui/cloud_account_panel.dart';
export 'ui/conflict_page.dart';
export 'ui/sync_status_view.dart';
export 'util/cloud_time_text.dart';
export 'util/conflict_presenter.dart';
