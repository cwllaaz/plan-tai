/// Android 账号 / 云同步 UI 模块（数据层）。
///
/// 归属：本目录 + `test/features/mobile_cloud_account/**` 由 数据层 维护；
/// `lib/features/cloud_account/**`（桌面抽屉）保持只读复用，不改动。
///
/// 接入方式（月历模块 预留入口、Agent D 统一接线）：
///
/// ```dart
/// import 'package:jihuatai/features/cloud_account/cloud_account.dart';
/// import 'package:jihuatai/features/mobile_cloud_account/mobile_cloud_account.dart';
///
/// // 1) 顶栏/设置页入口（控制器来自 CloudScope.controllerOf(context)）
/// MobileCloudEntryButton(controller: controller, showLabel: true)
///
/// // 2) 或直接打开页面
/// openMobileCloudAccount(context, controller);
/// ```
///
/// 本模块不创建控制器、不发 HTTP、不碰 SQLite：所有状态与操作都经由冻结的
/// `CloudAccountController` / `CloudServices` 契约完成。
library;

export 'ui/mobile_account_card.dart';
export 'ui/mobile_cloud_account_page.dart';
export 'ui/mobile_cloud_entry_button.dart';
export 'ui/mobile_cloud_keys.dart';
export 'ui/mobile_conflict_page.dart';
export 'ui/mobile_sign_in_view.dart';
export 'ui/mobile_sync_section.dart';
