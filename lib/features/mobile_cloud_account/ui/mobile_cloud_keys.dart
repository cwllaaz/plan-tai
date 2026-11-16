/// Android 账号 / 同步页面的稳定测试与集成键名。
///
/// 全部用 `ValueKey<String>`：月历模块 预留入口、Agent D 统一接线、本模块的
/// widget 测试都依赖这些键，避免靠中文文案定位控件。
library;

import 'package:material_ui/material_ui.dart';

abstract final class MobileCloudKeys {
  /// 页面根容器。
  static const ValueKey<String> page = ValueKey<String>('mobile-cloud-page');

  /// 顶栏/页面内的同步入口按钮。
  static const ValueKey<String> entryButton = ValueKey<String>(
    'mobile-cloud-entry-button',
  );

  // --- 登录 ---
  static const ValueKey<String> serverField = ValueKey<String>(
    'mobile-cloud-server-field',
  );
  static const ValueKey<String> accountField = ValueKey<String>(
    'mobile-cloud-account-field',
  );
  static const ValueKey<String> passwordField = ValueKey<String>(
    'mobile-cloud-password-field',
  );
  static const ValueKey<String> signInSubmit = ValueKey<String>(
    'mobile-cloud-signin-submit',
  );
  static const ValueKey<String> rememberServer = ValueKey<String>(
    'mobile-cloud-remember-server',
  );

  // --- 顶部提示 ---
  static const ValueKey<String> loginError = ValueKey<String>(
    'mobile-cloud-login-error',
  );
  static const ValueKey<String> actionBanner = ValueKey<String>(
    'mobile-cloud-action-banner',
  );
  static const ValueKey<String> noticeBanner = ValueKey<String>(
    'mobile-cloud-notice-banner',
  );

  // --- 账号 ---
  static const ValueKey<String> serverValue = ValueKey<String>(
    'mobile-cloud-server-value',
  );
  static const ValueKey<String> accountValue = ValueKey<String>(
    'mobile-cloud-account-value',
  );
  static const ValueKey<String> protocolValue = ValueKey<String>(
    'mobile-cloud-protocol-value',
  );
  static const ValueKey<String> recordCounts = ValueKey<String>(
    'mobile-cloud-record-counts',
  );
  static const ValueKey<String> bindingState = ValueKey<String>(
    'mobile-cloud-binding-state',
  );
  static const ValueKey<String> relogin = ValueKey<String>(
    'mobile-cloud-relogin',
  );
  static const ValueKey<String> signOut = ValueKey<String>(
    'mobile-cloud-signout',
  );
  static const ValueKey<String> signOutConfirm = ValueKey<String>(
    'mobile-cloud-signout-confirm',
  );

  // --- 同步 ---
  static const ValueKey<String> syncStatusPill = ValueKey<String>(
    'mobile-cloud-sync-status',
  );
  static const ValueKey<String> pendingCount = ValueKey<String>(
    'mobile-cloud-pending-count',
  );
  static const ValueKey<String> lastSync = ValueKey<String>(
    'mobile-cloud-last-sync',
  );
  static const ValueKey<String> errorBanner = ValueKey<String>(
    'mobile-cloud-error-banner',
  );
  static const ValueKey<String> syncNow = ValueKey<String>(
    'mobile-cloud-sync-now',
  );
  static const ValueKey<String> uploadNow = ValueKey<String>(
    'mobile-cloud-upload-now',
  );
  static const ValueKey<String> downloadNow = ValueKey<String>(
    'mobile-cloud-download-now',
  );
  static const ValueKey<String> autoSync = ValueKey<String>(
    'mobile-cloud-auto-sync',
  );
  static const ValueKey<String> openConflicts = ValueKey<String>(
    'mobile-cloud-open-conflicts',
  );
  static const ValueKey<String> downloadPreserve = ValueKey<String>(
    'mobile-cloud-download-preserve',
  );
  static const ValueKey<String> downloadForce = ValueKey<String>(
    'mobile-cloud-download-force',
  );

  // --- 冲突 ---
  static const ValueKey<String> conflictPage = ValueKey<String>(
    'mobile-cloud-conflict-page',
  );
  static const ValueKey<String> conflictClose = ValueKey<String>(
    'mobile-cloud-conflict-close',
  );

  static ValueKey<String> conflictItem(String id) =>
      ValueKey<String>('mobile-cloud-conflict-item-$id');
  static ValueKey<String> conflictKeepLocal(String id) =>
      ValueKey<String>('mobile-cloud-conflict-keep-local-$id');
  static ValueKey<String> conflictUseServer(String id) =>
      ValueKey<String>('mobile-cloud-conflict-use-server-$id');
  static ValueKey<String> conflictLocalValue(String id) =>
      ValueKey<String>('mobile-cloud-conflict-local-$id');
  static ValueKey<String> conflictServerValue(String id) =>
      ValueKey<String>('mobile-cloud-conflict-server-$id');
}
