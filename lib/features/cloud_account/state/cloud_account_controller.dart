import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/cloud/cloud.dart';
import '../util/cloud_texts.dart';
import '../util/server_address_input.dart';
import 'cloud_ui_preferences.dart';

enum _SyncUiKind { upload, download, both }

/// 首次登录时的数据归属阶段。
enum CloudBindingStage {
  /// 未登录，或还没开始检查。
  idle,

  /// 正在检查本机/云端数据归属（只读）。
  checking,

  /// 需要用户明确选择；界面必须展示绑定说明。
  needsChoice,

  /// 正在执行用户的选择（可能含整库备份，较慢）。
  applying,

  /// 已就绪，可以同步。
  ready,

  /// 用户选择「暂不关联」：保留本机数据，不上传也不下载。
  skipped,

  /// 绑定完成，但需要重启应用切换工作区。
  restartRequired,

  /// 检查失败（网络等原因），可以重试。
  failed,
}

/// 云账号面板的界面状态编排。
///
/// 职责边界（见 docs/sync/ARCHITECTURE.md）：
/// - 只依赖冻结的 [CloudAccountService] / [SyncService]，不碰 HTTP、SQLite、文件；
/// - 所有用户操作都通过冻结接口完成；
/// - 不保存密码；服务器地址交给 [CloudUiPreferences]（普通配置，不含密钥）。
class CloudAccountController extends ChangeNotifier {
  CloudAccountController({
    required this.services,
    CloudUiPreferences? preferences,
    DateTime Function()? clock,
    bool initialPanelOpen = false,
  }) : preferences = preferences ?? MemoryCloudUiPreferences(),
       _clock = clock ?? DateTime.now,
       _panelOpen = initialPanelOpen {
    _syncStatus = services.sync.status;
  }

  final CloudServices services;
  final CloudUiPreferences preferences;
  final DateTime Function() _clock;

  StreamSubscription<CloudAccount?>? _accountSubscription;
  StreamSubscription<SyncStatus>? _statusSubscription;

  CloudAccount? _account;
  ServerHandshake? _handshake;
  SyncStatus _syncStatus = SyncStatus.signedOut;
  BindingInspection? _inspection;
  CloudBindingStage _bindingStage = CloudBindingStage.idle;
  BindingResult? _bindingResult;

  List<SyncConflict> _conflicts = const <SyncConflict>[];
  bool _conflictsLoading = false;
  String? _conflictsError;
  String? _resolvingConflictId;

  bool _connecting = false;
  bool _loggingIn = false;
  bool _syncing = false;
  bool _applyingBinding = false;
  bool _refreshingBinding = false;
  bool _loggingOut = false;

  CloudException? _loginError;
  String? _notice;
  String? _banner;
  bool _bannerIsError = false;

  String _serverInput = '';
  String _accountInput = '';
  bool _rememberServer = true;
  String? _savedServerAddress;

  bool _panelOpen;
  bool _showingConflicts = false;
  bool _initialized = false;
  bool _disposed = false;
  DateTime? _lastInspectionRefreshAt;

  // --- 只读状态 -------------------------------------------------------------

  CloudAccount? get account => _account;

  bool get isSignedIn => _account != null;

  String get accountLabel => _account?.label ?? '';

  Uri? get serverUrl => _account?.serverUrl ?? _handshake?.baseUrl;

  bool get isSecureConnection => serverUrl?.scheme == 'https';

  bool get isLoopbackConnection => isLoopbackHost(serverUrl?.host ?? '');

  bool get rememberServer => _rememberServer;

  String get serverInput => _serverInput;

  String get accountInput => _accountInput;

  String? get savedServerAddress => _savedServerAddress;

  bool get isServerAddressSaved =>
      _savedServerAddress != null && _savedServerAddress!.isNotEmpty;

  DateTime get now => _clock();

  SyncStatus get syncStatus => _syncStatus;

  BindingInspection? get inspection => _inspection;

  CloudBindingStage get bindingStage => _bindingStage;

  BindingResult? get bindingResult => _bindingResult;

  /// 需要用户处理的数据归属问题（首次登录 / 换账号）。
  bool get needsBindingChoice => _bindingStage == CloudBindingStage.needsChoice;

  /// 用户已明确「暂不关联」。
  bool get bindingSkipped => _bindingStage == CloudBindingStage.skipped;

  /// 只有 ready 才允许同步，避免"没确认就把本机数据传上去"。
  bool get canSync =>
      _account != null && _bindingStage == CloudBindingStage.ready;

  bool get isConnecting => _connecting;

  bool get isLoggingIn => _loggingIn;

  bool get isAuthenticating => _connecting || _loggingIn;

  bool get isSyncing => _syncing || _syncStatus.phase == SyncPhase.syncing;

  bool get isApplyingBinding => _applyingBinding;

  bool get isRefreshingBinding => _refreshingBinding;

  String? get resolvingConflictId => _resolvingConflictId;

  String? get loginErrorTitle =>
      _loginError == null ? null : cloudErrorTitle(_loginError!.kind);

  String? get loginErrorMessage =>
      _loginError == null ? null : cloudErrorMessage(_loginError!);

  String? get loginErrorHint =>
      _loginError == null ? null : cloudErrorHint(_loginError!.kind);

  String? get notice => _notice;

  String? get banner => _banner;

  bool get bannerIsError => _bannerIsError;

  List<SyncConflict> get conflicts => _conflicts;

  bool get conflictsLoading => _conflictsLoading;

  String? get conflictsError => _conflictsError;

  int get conflictCount => _syncStatus.conflictCount > 0
      ? _syncStatus.conflictCount
      : _conflicts.length;

  bool get showingConflicts => _showingConflicts;

  bool get isPanelOpen => _panelOpen;

  // --- 生命周期 -------------------------------------------------------------

  /// 恢复上次会话、读取已保存的服务器地址、订阅账号与同步流。
  ///
  /// 可重复调用；只会真正执行一次。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _accountSubscription = services.account.observeAccount().listen(
      _onAccountChanged,
      onError: (Object error) {
        _banner = '账号状态异常：$error';
        _bannerIsError = true;
        _notify();
      },
    );
    _statusSubscription = services.sync.observeSyncStatus().listen(
      _onSyncChanged,
      onError: (Object error) {
        _banner = '同步状态异常：$error';
        _bannerIsError = true;
        _notify();
      },
    );

    final saved = await preferences.readServerAddress();
    if (saved != null && saved.isNotEmpty) {
      _savedServerAddress = saved;
      if (_serverInput.isEmpty) _serverInput = saved;
    }

    try {
      await services.account.restoreSession();
    } on CloudException catch (error) {
      // 没有可恢复的会话是正常情况；只有真正的网络错误才需要提示。
      if (error.kind == CloudErrorKind.network ||
          error.kind == CloudErrorKind.timeout) {
        _notice = '恢复上次登录失败：${cloudErrorMessage(error)}';
      }
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_accountSubscription?.cancel() ?? Future<void>.value());
    unawaited(_statusSubscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  // --- 面板开关 -------------------------------------------------------------

  void openPanel() {
    if (_panelOpen) return;
    _panelOpen = true;
    // 打开面板时顺便刷新一次归属/记录数（用户主动查看，值得一次网络往返）。
    if (_account != null && !_refreshingBinding) _maybeRefreshInspection();
    _notify();
  }

  void closePanel() {
    if (!_panelOpen) return;
    _panelOpen = false;
    _showingConflicts = false;
    _notify();
  }

  void togglePanel() => _panelOpen ? closePanel() : openPanel();

  // --- 登录 ---------------------------------------------------------------

  /// 连接服务器并登录。
  ///
  /// 本地先做一次格式校验（给即时反馈），真正的 HTTPS 策略由
  /// [CloudAccountService.connectServer] 强制。
  Future<void> signIn({
    required String server,
    required String account,
    required String password,
    bool rememberServer = true,
  }) async {
    if (_connecting || _loggingIn) return;
    _loginError = null;
    _notice = null;
    _banner = null;
    _bannerIsError = false;
    _rememberServer = rememberServer;

    final parsed = parseServerAddressInput(server);
    if (!parsed.ok) {
      _loginError = CloudException(CloudErrorKind.protocol, parsed.error!);
      _notify();
      return;
    }
    final accountText = account.trim();
    if (accountText.isEmpty) {
      _loginError = const CloudException(CloudErrorKind.protocol, '请填写账号或邮箱');
      _notify();
      return;
    }
    if (password.isEmpty) {
      _loginError = const CloudException(CloudErrorKind.protocol, '请填写密码');
      _notify();
      return;
    }

    final baseUrl = parsed.uri!;
    _connecting = true;
    _notify();
    try {
      final handshake = await services.account.connectServer(baseUrl);
      _handshake = handshake;
      _connecting = false;
      _loggingIn = true;
      _notify();

      final signedIn = await services.account.login(
        username: accountText,
        password: password,
      );
      _account = signedIn;
      _accountInput = signedIn.email;
      _notice = null;
      if (rememberServer) {
        final display = baseUrl.toString();
        await preferences.writeServerAddress(display);
        _savedServerAddress = display;
        _serverInput = display;
      } else {
        _serverInput = baseUrl.toString();
      }
      _notify();

      // 账号流通常已经触发数据归属检查；这里兜底避免 Fake/实现差异。
      if (_bindingStage == CloudBindingStage.idle) {
        _bindingStage = CloudBindingStage.checking;
        _notify();
        await _refreshBinding();
      }
    } on CloudException catch (error) {
      _loginError = error;
      _account = null;
    } on Object catch (error) {
      _loginError = CloudException(CloudErrorKind.unknown, '登录失败：$error');
      _account = null;
    } finally {
      _connecting = false;
      _loggingIn = false;
      _notify();
    }
  }

  /// 退出登录（断开云端绑定）。
  ///
  /// **不会**删除本地数据，也不会删除账号工作区。
  Future<void> signOut({String? notice}) async {
    if (_loggingOut) return;
    _loggingOut = true;
    try {
      await services.account.logout();
    } on CloudException catch (error) {
      _banner = '已在本地退出，但未能通知服务器撤销会话：${cloudErrorMessage(error)}';
      _bannerIsError = true;
    } on Object catch (error) {
      _banner = '已在本地退出，但未能通知服务器撤销会话：$error';
      _bannerIsError = true;
    } finally {
      _loggingOut = false;
      _resetSessionState();
      _notice = notice ?? '已断开云端绑定；本机数据没有被删除，仍完整保留在本机。';
      _notify();
    }
  }

  /// 重新登录：先退出（不撤销服务端会话），保留服务器地址与账号，验证密码后继续。
  Future<void> reauthenticate() async {
    final current = _account;
    if (current == null) return;
    _serverInput = current.serverUrl.toString();
    _accountInput = current.email;
    _loggingOut = true;
    try {
      await services.account.logout(revokeRemoteSession: false);
    } on Object {
      // 重新登录以本地清理为准，服务端会话由后续登录覆盖。
    } finally {
      _loggingOut = false;
      _resetSessionState();
      _notice = '请重新登录以继续同步；本机数据不会受影响。';
      _notify();
    }
  }

  // --- 首次绑定 -------------------------------------------------------------

  /// 用户在绑定卡片上做出选择。
  Future<void> chooseBinding(BindingChoice choice) async {
    if (_applyingBinding || _account == null) return;
    if (choice == BindingChoice.cancel) {
      await signOut(notice: '已取消本次登录；本机数据未做任何改动。');
      return;
    }
    _applyingBinding = true;
    _bindingStage = CloudBindingStage.applying;
    _banner = null;
    _bannerIsError = false;
    _notify();
    try {
      final result = await services.sync.applyBinding(choice);
      _bindingResult = result;
      if (choice == BindingChoice.keepLocalUnbound) {
        _bindingStage = CloudBindingStage.skipped;
        _banner = result.message.isEmpty
            ? '已保留本机数据，本次不上传也不下载任何内容。'
            : result.message;
      } else if (result.requiresRestart) {
        _bindingStage = CloudBindingStage.restartRequired;
        _banner = result.message.isEmpty
            ? '数据关联完成，需要重启应用后生效。'
            : '${result.message}（需要重启应用后生效）';
      } else {
        _bindingStage = CloudBindingStage.ready;
        _banner = result.message.isEmpty ? '本机数据已关联到当前账号。' : result.message;
        if (result.backupPath != null && result.backupPath!.isNotEmpty) {
          _banner = '$_banner 本机数据已备份：${result.backupPath}';
        }
      }
      _bannerIsError = false;
    } on CloudException catch (error) {
      _bindingStage = CloudBindingStage.needsChoice;
      _banner = '关联失败：${cloudErrorMessage(error)}';
      _bannerIsError = true;
    } on Object catch (error) {
      _bindingStage = CloudBindingStage.needsChoice;
      _banner = '关联失败：$error';
      _bannerIsError = true;
    } finally {
      _applyingBinding = false;
      _notify();
    }
    if (_bindingStage == CloudBindingStage.ready) {
      unawaited(syncNow(silent: true));
    }
  }

  /// 绑定检查失败后的重试。
  Future<void> retryBindingInspection() async {
    if (_account == null || _refreshingBinding) return;
    _bindingStage = CloudBindingStage.checking;
    _banner = null;
    _notify();
    await _refreshBinding();
  }

  // --- 同步 ---------------------------------------------------------------

  /// 立即双向同步（保留给首次绑定/兼容入口）。
  Future<void> syncNow({bool silent = false}) => _performSync(
    services.sync.syncNow,
    silent: silent,
    label: '同步',
    kind: _SyncUiKind.both,
  );

  /// 只上传本机改动到云端。
  Future<void> uploadNow({bool silent = false}) => _performSync(
    services.sync.uploadNow,
    silent: silent,
    label: '上传',
    kind: _SyncUiKind.upload,
  );

  /// 只从云端下载更新。
  ///
  /// [overwriteLocal] 由用户在二次确认后显式开启：先整库备份，再丢弃本机
  /// 未上传操作，用云端快照覆盖本机。
  Future<void> downloadNow({
    bool silent = false,
    bool overwriteLocal = false,
  }) => _performSync(
    () => services.sync.downloadNow(overwriteLocal: overwriteLocal),
    silent: silent,
    label: overwriteLocal ? '覆盖更新' : '下载',
    kind: _SyncUiKind.download,
    overwriteLocal: overwriteLocal,
  );

  Future<void> _performSync(
    Future<SyncResult> Function() action, {
    required bool silent,
    required String label,
    required _SyncUiKind kind,
    bool overwriteLocal = false,
  }) async {
    if (_syncing) return;
    if (_account == null) {
      _banner = '请先登录云端账号。';
      _bannerIsError = true;
      _notify();
      return;
    }
    if (!canSync) {
      if (bindingSkipped) {
        _banner = '本机数据未关联账号，暂不上传；如需同步，请先关联本地数据。';
      } else if (_bindingStage == CloudBindingStage.restartRequired) {
        _banner = '需要重启应用完成工作区切换后再同步。';
      } else {
        _banner = '请先确认本地数据如何关联到云端账号。';
      }
      _bannerIsError = true;
      _notify();
      return;
    }
    _syncing = true;
    if (!silent) {
      _banner = null;
      _bannerIsError = false;
    }
    _notify();
    try {
      final result = await action();
      switch (result.outcome) {
        case SyncOutcome.success || SyncOutcome.noChanges:
          _banner = overwriteLocal && result.message != null
              ? result.message!
              : switch (kind) {
                  _SyncUiKind.upload =>
                    result.pushed > 0
                        ? '已上传 ${result.pushed} 项到云端。'
                        : '没有待上传的改动。',
                  _SyncUiKind.download =>
                    result.pulled > 0
                        ? '已从云端更新 ${result.pulled} 项。'
                        : '云端没有新数据。',
                  _SyncUiKind.both =>
                    result.pushed > 0 || result.pulled > 0
                        ? '同步完成：上传 ${result.pushed} 项，下载 ${result.pulled} 项。'
                        : '已是最新，没有需要同步的改动。',
                };
          _bannerIsError = false;
        case SyncOutcome.conflict:
          _banner = '发现 ${result.conflicts} 条冲突，已保存到冲突列表，请处理后再同步。';
          _bannerIsError = false;
        case SyncOutcome.offline:
          _banner = '当前离线：改动已保存在本机，联网后可重试。';
          _bannerIsError = false;
        case SyncOutcome.authRequired:
          _notice = '登录已过期，请重新登录。本机数据与待同步操作不会丢失。';
          _account = null;
          _bindingStage = CloudBindingStage.idle;
          _loginError = null;
        case SyncOutcome.bindingRequired:
          _banner = '云端要求先确认本机数据归属。';
          _bannerIsError = true;
          await _refreshBinding();
        case SyncOutcome.error:
          _banner = result.message == null || result.message!.isEmpty
              ? '$label失败，请稍后重试。'
              : '$label失败：${result.message}';
          _bannerIsError = true;
      }
    } on CloudException catch (error) {
      _banner = '$label失败：${cloudErrorMessage(error)}';
      _bannerIsError = true;
    } on Object catch (error) {
      _banner = '$label失败：$error';
      _bannerIsError = true;
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// 自动上传开关：本机改动后台推送。
  Future<void> setAutoUpload(bool enabled) =>
      _setAutoFlag(() => services.sync.enableAutoUpload(enabled), '自动上传');

  /// 自动下载开关：定时从云端拉取更新。
  Future<void> setAutoDownload(bool enabled) =>
      _setAutoFlag(() => services.sync.enableAutoDownload(enabled), '自动下载');

  /// 兼容旧入口：同时切换两个自动方向。
  Future<void> setAutoSync(bool enabled) =>
      _setAutoFlag(() => services.sync.enableAutoSync(enabled), '自动同步');

  Future<void> _setAutoFlag(
    Future<void> Function() action,
    String label,
  ) async {
    try {
      await action();
    } on CloudException catch (error) {
      _banner = '无法切换$label：${cloudErrorMessage(error)}';
      _bannerIsError = true;
    } on Object catch (error) {
      _banner = '无法切换$label：$error';
      _bannerIsError = true;
    }
    _notify();
  }

  // --- 冲突 ---------------------------------------------------------------

  /// 打开冲突处理页并拉取未解决冲突。
  Future<void> openConflicts() async {
    if (_showingConflicts && !_conflictsLoading) return;
    _showingConflicts = true;
    _conflictsLoading = true;
    _conflictsError = null;
    _notify();
    try {
      final list = await services.sync.listConflicts();
      _conflicts = list;
    } on CloudException catch (error) {
      _conflictsError = '读取冲突失败：${cloudErrorMessage(error)}';
    } on Object catch (error) {
      _conflictsError = '读取冲突失败：$error';
    } finally {
      _conflictsLoading = false;
      _notify();
    }
  }

  void closeConflicts() {
    if (!_showingConflicts) return;
    _showingConflicts = false;
    _notify();
  }

  /// 解决一条冲突。选择前**不会**删除任何版本。
  Future<void> resolveConflict(
    String conflictId,
    ConflictResolution resolution,
  ) async {
    if (_resolvingConflictId != null) return;
    _resolvingConflictId = conflictId;
    _conflictsError = null;
    _notify();
    try {
      await services.sync.resolveConflict(conflictId, resolution);
      _conflicts = _conflicts
          .where((conflict) => conflict.id != conflictId)
          .toList(growable: false);
      _banner = '已${conflictResolutionLabel(resolution)}，这条冲突已处理。';
      _bannerIsError = false;
      if (_conflicts.isEmpty) _showingConflicts = false;
    } on CloudException catch (error) {
      _conflictsError = '处理冲突失败：${cloudErrorMessage(error)}';
      _bannerIsError = true;
    } on Object catch (error) {
      _conflictsError = '处理冲突失败：$error';
    } finally {
      _resolvingConflictId = null;
      _notify();
    }
  }

  // --- 杂项 ---------------------------------------------------------------

  void dismissBanner() {
    if (_banner == null) return;
    _banner = null;
    _notify();
  }

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  void setServerInput(String value) {
    if (_serverInput == value) return;
    _serverInput = value;
    _notify();
  }

  void setAccountInput(String value) {
    if (_accountInput == value) return;
    _accountInput = value;
    _notify();
  }

  void setRememberServer(bool value) {
    if (_rememberServer == value) return;
    _rememberServer = value;
    _notify();
  }

  // --- 内部 ---------------------------------------------------------------

  Future<void> _refreshBinding() async {
    if (_refreshingBinding || _account == null) return;
    _refreshingBinding = true;
    _notify();
    try {
      final inspection = await services.sync.inspectBinding();
      final wasReady = _bindingStage == CloudBindingStage.ready;
      _inspection = inspection;
      // 已确认关联后只刷新记录数，不因为一次刷新把用户退回“待确认”；
      // 唯一例外是本地库被换成别的账号（必须重新选择归属）。
      if (wasReady &&
          inspection.situation != BindingSituation.boundOtherAccount) {
        _bindingStage = CloudBindingStage.ready;
      } else {
        _bindingStage = _stageFor(inspection);
      }
      _banner = null;
      _bannerIsError = false;
    } on CloudException catch (error) {
      if (error.kind == CloudErrorKind.network ||
          error.kind == CloudErrorKind.timeout) {
        // 断网时不要把用户退回“需要检查数据”：本地数据仍完整可用，
        // 同步状态由 SyncService 的 offline 态表达。
        if (_bindingStage == CloudBindingStage.idle ||
            _bindingStage == CloudBindingStage.checking) {
          _bindingStage = CloudBindingStage.ready;
        }
        _banner = '网络不可用，暂时无法核对云端数据；本地功能与数据不受影响。';
        _bannerIsError = false;
      } else {
        _bindingStage = CloudBindingStage.failed;
        _banner = '无法检查数据归属：${cloudErrorMessage(error)}';
        _bannerIsError = true;
      }
    } on Object catch (error) {
      _bindingStage = CloudBindingStage.failed;
      _banner = '无法检查数据归属：$error';
      _bannerIsError = true;
    } finally {
      _refreshingBinding = false;
      _notify();
    }
  }

  CloudBindingStage _stageFor(BindingInspection inspection) {
    return switch (inspection.situation) {
      BindingSituation.boundSameAccount => CloudBindingStage.ready,
      BindingSituation.freshInstallCloudEmpty => CloudBindingStage.ready,
      BindingSituation.freshInstallCloudHasData ||
      BindingSituation.localDataCloudEmpty ||
      BindingSituation.bothHaveData ||
      BindingSituation.boundOtherAccount => CloudBindingStage.needsChoice,
    };
  }

  void _onAccountChanged(CloudAccount? next) {
    if (next == null) {
      if (_account == null) return;
      if (_loggingOut) return;
      // 会话被服务端置为无效（token 过期/被撤销）：保留本地数据与待同步队列。
      _account = null;
      _handshake = null;
      _inspection = null;
      _bindingStage = CloudBindingStage.idle;
      _conflicts = const <SyncConflict>[];
      _showingConflicts = false;
      _loginError = null;
      _notice = '登录已过期，请重新登录。本机数据与待同步操作不会丢失。';
      _notify();
      return;
    }
    if (_account?.ownerId == next.ownerId && _account?.email == next.email) {
      return;
    }
    _account = next;
    _notice = null;
    _loginError = null;
    _inspection = null;
    _bindingStage = CloudBindingStage.checking;
    _notify();
    unawaited(_refreshBinding());
  }

  void _onSyncChanged(SyncStatus status) {
    final conflictCount = status.conflictCount;
    final previous = _syncStatus;
    _syncStatus = status;
    if (conflictCount > previous.conflictCount && !_showingConflicts) {
      _banner = '发现 $conflictCount 条冲突，请处理后再同步。';
      _bannerIsError = false;
    }
    // 同步成功且落盘后，本机/云端记录数会变化；刷新一次归属信息，
    // 避免面板一直显示同步前的旧数字（D 集成时补充）。
    final completedSuccessfully =
        status.phase == SyncPhase.idle &&
        status.lastSyncedAt != null &&
        status.lastSyncedAt != previous.lastSyncedAt;
    if (completedSuccessfully) _maybeRefreshInspection();
    _notify();
  }

  /// 刷新数据归属信息（带 5 秒节流，避免每次状态变化都发网络请求）。
  void _maybeRefreshInspection() {
    if (_account == null || _refreshingBinding || _applyingBinding) return;
    // 只在「已确认关联」后刷新：首次绑定尚未落定阶段时刷新会与绑定结果竞争。
    if (_bindingStage != CloudBindingStage.ready) return;
    final now = _clock();
    final last = _lastInspectionRefreshAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastInspectionRefreshAt = now;
    unawaited(_refreshBinding());
  }

  void _resetSessionState() {
    _account = null;
    _handshake = null;
    _inspection = null;
    _bindingResult = null;
    _bindingStage = CloudBindingStage.idle;
    _conflicts = const <SyncConflict>[];
    _conflictsError = null;
    _showingConflicts = false;
    _loginError = null;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
