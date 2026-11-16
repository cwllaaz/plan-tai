/// 云同步公共值对象（**已冻结**）。
///
/// 本文件是三端（Windows / Ubuntu / Android / 浏览器）、三个并行 Agent 与服务端
/// 共同遵守的客户端语义。只依赖 `dart:async` 与 `dart:core`，不依赖 Flutter，
/// 也不包含任何网络或数据库实现，方便 UI 用 Fake 独立开发。
///
/// 线上字段名与 [docs/sync/API_CONTRACT.md] 一一对应；修改本文件必须先改协议文档。
library;

/// 可同步的实体类型。Wire 名使用单数、小写，稳定不变。
enum CloudEntityType {
  project('project'),
  span('span'),
  task('task'),
  note('note');

  const CloudEntityType(this.wireName);

  /// JSON 里的 `entityType` 值。
  final String wireName;

  static CloudEntityType? tryParse(String value) {
    for (final type in CloudEntityType.values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

/// 同步阶段。UI 只依赖这个粗粒度状态，不感知 push/pull 的内部步骤。
enum SyncPhase {
  /// 未登录 / 已退出；不显示同步进度。
  signedOut,

  /// 已登录、空闲，没有正在进行的同步。
  idle,

  /// 正在 push 或 pull。
  syncing,

  /// 网络不可用，或上次失败可重试。
  offline,

  /// 需要用户处理：冲突、首次绑定、登录过期等。
  needsAttention,

  /// 不可恢复错误（协议不兼容、服务器数据异常）。
  error,
}

/// 单次 [SyncService.syncNow] 的结果分类。
enum SyncOutcome {
  success,
  noChanges,
  conflict,
  offline,
  authRequired,
  bindingRequired,
  error,
}

/// 冲突类型。Wire 名由服务端在 `conflict.kind` 返回。
enum ConflictKind {
  updateUpdate('UPDATE_UPDATE'),
  updateDelete('UPDATE_DELETE'),
  deleteUpdate('DELETE_UPDATE'),
  createExists('CREATE_EXISTS'),
  noteDateTaken('NOTE_DATE_TAKEN'),
  unknown('UNKNOWN');

  const ConflictKind(this.wireName);

  final String wireName;

  static ConflictKind fromWire(String value) {
    for (final kind in ConflictKind.values) {
      if (kind.wireName == value) return kind;
    }
    return ConflictKind.unknown;
  }
}

/// 用户对一条冲突的处理方式。
enum ConflictResolution {
  /// 以本地为准。服务端已删除时，本地内容会以**新 ID 副本**保留。
  keepLocal,

  /// 以服务端为准。本地未同步的修改被丢弃（会先提示）。
  keepServer,

  /// 使用调用方提供的合并结果；合并载荷必须符合实体 schema。
  manual,
}

/// 首次登录 / 换账号时的数据归属场景。
enum BindingSituation {
  /// 本机无数据，云端也无数据。
  freshInstallCloudEmpty,

  /// 本机无数据，云端有数据：直接建立账号工作区并全量拉取。
  freshInstallCloudHasData,

  /// 本机有数据，云端为空：可经用户确认后上传。
  localDataCloudEmpty,

  /// 本机与云端都有数据：禁止自动合并，必须让用户选择。
  bothHaveData,

  /// 当前本地库已绑定同一个账号。
  boundSameAccount,

  /// 当前本地库已绑定其他账号：禁止上传，必须换库或取消。
  boundOtherAccount,
}

/// 首次绑定 / 换账号时用户的选择。
enum BindingChoice {
  /// 把当前本地库的数据上传到当前账号（仅云端为空时允许）。
  uploadLocalToAccount,

  /// 以云端为准：先整库归档本地数据，再建立账号工作区并全量拉取。
  useCloudAndArchiveLocal,

  /// 保持本地数据不绑定，另建一个空的账号工作区。
  keepLocalUnbound,

  /// 放弃本次绑定 / 登录。
  cancel,
}

/// 客户端可展示的云端错误分类。
enum CloudErrorKind {
  network,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  rateLimited,
  server,
  protocol,
  cancelled,
  unknown,
}

/// 统一异常类型：实现层不得向上抛裸异常或 HTTP 细节。
final class CloudException implements Exception {
  const CloudException(
    this.kind,
    this.message, {
    this.retryable = false,
    this.statusCode,
    this.cause,
  });

  final CloudErrorKind kind;
  final String message;

  /// 是否适合自动重试（网络、超时、429、5xx）。
  final bool retryable;

  /// HTTP 状态码（若有）；仅供日志，UI 不应依赖。
  final int? statusCode;

  final Object? cause;

  @override
  String toString() => 'CloudException(${kind.name}, $statusCode): $message';
}

/// 云端账号。`ownerId` 是服务端用户记录 ID，也是数据隔离键。
final class CloudAccount {
  const CloudAccount({
    required this.ownerId,
    required this.email,
    required this.serverUrl,
    required this.authenticatedAt,
    this.displayName,
  }) : assert(ownerId != '', 'ownerId 不能为空');

  final String ownerId;
  final String email;
  final String? displayName;
  final Uri serverUrl;

  /// 本次认证成功时刻（UTC）。
  final DateTime authenticatedAt;

  /// UI 展示名：优先昵称，其次邮箱。
  String get label {
    final name = displayName?.trim() ?? '';
    return name.isEmpty ? email : name;
  }

  @override
  bool operator ==(Object other) =>
      other is CloudAccount &&
      ownerId == other.ownerId &&
      email == other.email &&
      displayName == other.displayName &&
      serverUrl == other.serverUrl &&
      authenticatedAt == other.authenticatedAt;

  @override
  int get hashCode =>
      Object.hash(ownerId, email, displayName, serverUrl, authenticatedAt);

  @override
  String toString() => 'CloudAccount($ownerId, $email, $serverUrl)';
}

/// `connectServer` 的握手结果：服务端能力与协议版本。
final class ServerHandshake {
  const ServerHandshake({
    required this.baseUrl,
    required this.serverVersion,
    required this.protocolVersion,
    required this.minSchemaVersion,
    required this.maxSchemaVersion,
    required this.serverTime,
    required this.features,
  });

  final Uri baseUrl;
  final String serverVersion;
  final int protocolVersion;
  final int minSchemaVersion;
  final int maxSchemaVersion;

  /// 服务端当前时间（UTC）。客户端只用于显示时钟偏差，绝不用于变更排序。
  final DateTime serverTime;

  /// 例如 `['sync.push', 'sync.pull']`。
  final List<String> features;

  bool get supportsSync =>
      features.contains('sync.push') && features.contains('sync.pull');

  @override
  String toString() =>
      'ServerHandshake($baseUrl, protocol=$protocolVersion, schema=$minSchemaVersion..$maxSchemaVersion)';
}

/// 同步状态快照。UI 通过 `observeSyncStatus()` 订阅它。
final class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.account,
    this.lastSyncedAt,
    this.lastUploadedAt,
    this.lastDownloadedAt,
    this.pendingOperations = 0,
    this.conflictCount = 0,
    this.autoUploadEnabled = false,
    this.autoDownloadEnabled = false,
    this.lastError,
    this.message,
  });

  /// 已退出登录时的初始状态。
  static const SyncStatus signedOut = SyncStatus(phase: SyncPhase.signedOut);

  final SyncPhase phase;
  final CloudAccount? account;

  /// 最后一次成功同步完成时刻（UTC）。
  final DateTime? lastSyncedAt;

  /// 最后一次成功上传完成时刻（UTC）。
  final DateTime? lastUploadedAt;

  /// 最后一次成功从云端更新完成时刻（UTC）。
  final DateTime? lastDownloadedAt;

  /// 本地尚未成功上传的操作数（含待重试）。
  final int pendingOperations;

  /// 未解决的冲突数。
  final int conflictCount;

  /// 自动上传：本机改动在后台自动推送到云端。
  final bool autoUploadEnabled;

  /// 自动下载：定时从云端拉取更新。
  final bool autoDownloadEnabled;

  /// 兼容旧调用：任一自动方向开启即视为“自动同步开启”。
  bool get autoSyncEnabled => autoUploadEnabled || autoDownloadEnabled;

  /// 最近一次失败的可读原因；成功后应清空。
  final String? lastError;

  /// 当前阶段的可选说明（例如“正在上传 3/12”）。
  final String? message;

  SyncStatus copyWith({
    SyncPhase? phase,
    Object? account = _unset,
    Object? lastSyncedAt = _unset,
    Object? lastUploadedAt = _unset,
    Object? lastDownloadedAt = _unset,
    int? pendingOperations,
    int? conflictCount,
    bool? autoUploadEnabled,
    bool? autoDownloadEnabled,
    Object? lastError = _unset,
    Object? message = _unset,
  }) => SyncStatus(
    phase: phase ?? this.phase,
    account: identical(account, _unset)
        ? this.account
        : account as CloudAccount?,
    lastSyncedAt: identical(lastSyncedAt, _unset)
        ? this.lastSyncedAt
        : lastSyncedAt as DateTime?,
    lastUploadedAt: identical(lastUploadedAt, _unset)
        ? this.lastUploadedAt
        : lastUploadedAt as DateTime?,
    lastDownloadedAt: identical(lastDownloadedAt, _unset)
        ? this.lastDownloadedAt
        : lastDownloadedAt as DateTime?,
    pendingOperations: pendingOperations ?? this.pendingOperations,
    conflictCount: conflictCount ?? this.conflictCount,
    autoUploadEnabled: autoUploadEnabled ?? this.autoUploadEnabled,
    autoDownloadEnabled: autoDownloadEnabled ?? this.autoDownloadEnabled,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as String?,
    message: identical(message, _unset) ? this.message : message as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      phase == other.phase &&
      account == other.account &&
      lastSyncedAt == other.lastSyncedAt &&
      lastUploadedAt == other.lastUploadedAt &&
      lastDownloadedAt == other.lastDownloadedAt &&
      pendingOperations == other.pendingOperations &&
      conflictCount == other.conflictCount &&
      autoUploadEnabled == other.autoUploadEnabled &&
      autoDownloadEnabled == other.autoDownloadEnabled &&
      lastError == other.lastError &&
      message == other.message;

  @override
  int get hashCode => Object.hash(
    phase,
    account,
    lastSyncedAt,
    lastUploadedAt,
    lastDownloadedAt,
    pendingOperations,
    conflictCount,
    autoUploadEnabled,
    autoDownloadEnabled,
    lastError,
    message,
  );

  @override
  String toString() =>
      'SyncStatus(${phase.name}, pending=$pendingOperations, conflicts=$conflictCount, '
      'autoUpload=$autoUploadEnabled, autoDownload=$autoDownloadEnabled)';
}

/// 一条未解决的冲突。载荷使用协议 JSON（见 DATA_CONTRACT.md）。
final class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.baseRevision,
    required this.serverRevision,
    required this.kind,
    required this.detectedAt,
    this.localPayload,
    this.serverPayload,
    this.serverDeleted = false,
  });

  /// 本地冲突记录 ID（不是实体 ID）。
  final String id;

  final CloudEntityType entityType;
  final String entityId;

  /// 本次修改所基于的服务端版本。
  final int baseRevision;

  /// 冲突发生时服务端最新版本。
  final int serverRevision;

  final ConflictKind kind;

  /// 本地想写入的载荷；删除意图时为 null。
  final Map<String, Object?>? localPayload;

  /// 服务端当前载荷；已删除时为 null。
  final Map<String, Object?>? serverPayload;

  final bool serverDeleted;

  final DateTime detectedAt;

  @override
  String toString() =>
      'SyncConflict($id, ${entityType.wireName}/$entityId, ${kind.wireName})';
}

/// 同步模式。
enum SyncMode {
  /// 先 push 未上传操作，再按游标增量 pull。
  incremental,

  /// 忽略本地游标，做服务端快照拉取（用于首次绑定 / 修复）。
  full,
}

/// 单次同步结果。
final class SyncResult {
  const SyncResult({
    required this.outcome,
    required this.finishedAt,
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.cursor,
    this.message,
  });

  final SyncOutcome outcome;
  final DateTime finishedAt;

  /// 服务端确认成功的操作数。
  final int pushed;

  /// 应用到本地的变更条数。
  final int pulled;

  /// 本次新产生的冲突数。
  final int conflicts;

  /// 同步后的服务端游标（不透明字符串）。
  final String? cursor;

  final String? message;

  bool get isSuccess =>
      outcome == SyncOutcome.success || outcome == SyncOutcome.noChanges;

  @override
  String toString() =>
      'SyncResult(${outcome.name}, pushed=$pushed, pulled=$pulled, conflicts=$conflicts)';
}

/// 首次绑定 / 换账号的检查结果。此方法**只读**，不得上传或覆盖任何数据。
final class BindingInspection {
  const BindingInspection({
    required this.situation,
    required this.canUpload,
    required this.requiresBackup,
    required this.recommendedChoice,
    required this.message,
    this.boundOwnerId,
    this.localLiveRecords = 0,
    this.cloudRecords,
  });

  final BindingSituation situation;

  /// 是否允许把本地数据上传到当前账号（仅云端为空且本地未绑定他号时为 true）。
  final bool canUpload;

  /// 执行选择前是否必须先完成整库备份。
  final bool requiresBackup;

  /// 推荐选项；UI 可以把它高亮，但不得代替用户确认。
  final BindingChoice recommendedChoice;

  /// 给用户看的说明，必须包含数据量/账号信息。
  final String message;

  /// 当前本地库已绑定的账号 ID（若有）。
  final String? boundOwnerId;

  /// 本地未删除记录数。
  final int localLiveRecords;

  /// 云端记录数；无法连接时为 null。**不得因为 null 就推断云端为空。**
  final int? cloudRecords;

  @override
  String toString() =>
      'BindingInspection(${situation.name}, canUpload=$canUpload, local=$localLiveRecords, cloud=$cloudRecords)';
}

/// 绑定操作结果。
final class BindingResult {
  const BindingResult({
    required this.changed,
    required this.requiresRestart,
    required this.message,
    this.backupPath,
  });

  final bool changed;

  /// 绑定 / 换库后是否需要重启应用以切换 Repository。
  final bool requiresRestart;

  final String message;

  /// 本次操作生成的整库备份路径（若做了备份）。
  final String? backupPath;
}

/// `copyWith` 的“未传参”哨兵，避免无法把字段显式置 null。
const Object _unset = Object();
