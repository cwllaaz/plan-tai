/// 工作区布局与账号绑定旁路文件（`*.binding.json`）。
///
/// 依据 docs/sync/ARCHITECTURE.md §3.1：
/// ```
/// data\
/// ├─ app.db                   既有本地库（local-default）
/// ├─ app.db.binding.json      绑定记录
/// ├─ device.json              安装级设备 ID
/// ├─ accounts\<ownerId>\app.db       新账号工作区
/// ├─ accounts\<ownerId>\binding.json
/// └─ backups\
/// ```
/// 绑定记录放数据库**外面**：把数据库备份拷到另一台机器不会继承账号归属，
/// 避免"A 的库被当成 B 上传"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/cloud/cloud_types.dart';
import '../planner_paths.dart';

/// 账号绑定的来源：既有本地库 or 账号专属工作区。
enum WorkspaceKind {
  local('local'),
  account('account');

  const WorkspaceKind(this.wire);

  final String wire;

  static WorkspaceKind fromWire(String? value) =>
      value == 'account' ? WorkspaceKind.account : WorkspaceKind.local;
}

/// 绑定状态机（docs/sync/ACCOUNT_BINDING.md §4）。
enum BindingState {
  unbound('unbound'),
  pending('pending'),
  bound('bound'),
  needsReconcile('needs_reconcile');

  const BindingState(this.wire);

  final String wire;

  static BindingState fromWire(String? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return BindingState.bound;
  }
}

final class WorkspaceBinding {
  const WorkspaceBinding({
    required this.ownerId,
    required this.email,
    required this.serverUrl,
    required this.boundAt,
    this.displayName,
    this.kind = WorkspaceKind.local,
    this.state = BindingState.bound,
    this.lastVerifiedAt,
    this.lastServerRevision,
    this.note,
  });

  final String ownerId;
  final String email;
  final String? displayName;
  final String serverUrl;
  final DateTime boundAt;
  final WorkspaceKind kind;
  final BindingState state;
  final DateTime? lastVerifiedAt;
  final int? lastServerRevision;
  final String? note;

  String get workspaceId =>
      kind == WorkspaceKind.account ? 'account-$ownerId' : 'local-default';

  bool matches(CloudAccount account) =>
      ownerId == account.ownerId &&
      _normalize(serverUrl) == _normalize(account.serverUrl.toString());

  WorkspaceBinding copyWith({
    BindingState? state,
    DateTime? lastVerifiedAt,
    int? lastServerRevision,
    String? note,
  }) => WorkspaceBinding(
    ownerId: ownerId,
    email: email,
    displayName: displayName,
    serverUrl: serverUrl,
    boundAt: boundAt,
    kind: kind,
    state: state ?? this.state,
    lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
    lastServerRevision: lastServerRevision ?? this.lastServerRevision,
    note: note ?? this.note,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'bindingVersion': 1,
    'workspaceId': workspaceId,
    'ownerId': ownerId,
    'email': email,
    'displayName': displayName,
    'serverUrl': serverUrl,
    'state': state.wire,
    'boundAt': boundAt.toUtc().toIso8601String(),
    'lastVerifiedAt': lastVerifiedAt?.toUtc().toIso8601String(),
    'lastServerRevision': lastServerRevision,
    'note': note,
    'workspace': kind.wire,
  };

  factory WorkspaceBinding.fromJson(Map<String, Object?> json) =>
      WorkspaceBinding(
        ownerId: json['ownerId']! as String,
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String?,
        serverUrl: json['serverUrl'] as String? ?? '',
        boundAt:
            DateTime.tryParse(json['boundAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        kind: WorkspaceKind.fromWire(json['workspace'] as String?),
        state: BindingState.fromWire(json['state'] as String?),
        lastVerifiedAt: DateTime.tryParse(
          json['lastVerifiedAt'] as String? ?? '',
        )?.toUtc(),
        lastServerRevision: (json['lastServerRevision'] as num?)?.toInt(),
        note: json['note'] as String?,
      );

  static String _normalize(String url) {
    final trimmed = url.trim();
    final withoutSlash = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    return withoutSlash.toLowerCase();
  }
}

/// 绑定旁路文件的读写。
final class AccountBindingStore {
  AccountBindingStore(this.bindingPath);

  final String bindingPath;

  WorkspaceBinding? read() {
    final file = File(bindingPath);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<Object?, Object?>) return null;
      return WorkspaceBinding.fromJson(
        Map<String, Object?>.from(decoded),
      );
    } on Object {
      return null;
    }
  }

  void write(WorkspaceBinding binding) {
    final file = File(bindingPath);
    Directory(p.dirname(bindingPath)).createSync(recursive: true);
    final temp = File('$bindingPath.tmp');
    temp.writeAsStringSync(jsonEncode(binding.toJson()), flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(bindingPath);
  }

  void clear() {
    final file = File(bindingPath);
    if (file.existsSync()) file.deleteSync();
  }
}

/// 数据目录布局。
final class WorkspaceLayout {
  WorkspaceLayout(this.dataDirectory);

  final String dataDirectory;

  static WorkspaceLayout defaultLayout({Map<String, String>? environment}) =>
      WorkspaceLayout(
        PlannerPaths.defaultDataDirectory(environment: environment),
      );

  String get localDatabasePath =>
      p.join(dataDirectory, PlannerPaths.databaseFileName);

  String get localBindingPath => bindingPathForDatabase(localDatabasePath);

  String accountDirectory(String ownerId) =>
      p.join(dataDirectory, 'accounts', sanitize(ownerId));

  String accountDatabasePath(String ownerId) =>
      p.join(accountDirectory(ownerId), PlannerPaths.databaseFileName);

  String accountBindingPath(String ownerId) =>
      p.join(accountDirectory(ownerId), 'binding.json');

  String get backupsDirectory =>
      p.join(dataDirectory, PlannerPaths.backupsFolder);

  /// 既有本地库的绑定文件：`app.db.binding.json`；
  /// 账号工作区用同目录的 `binding.json`（由调用方传入 accountWorkspace）。
  static String bindingPathForDatabase(
    String databasePath, {
    bool accountWorkspace = false,
  }) {
    if (accountWorkspace) {
      return p.join(p.dirname(databasePath), 'binding.json');
    }
    return '$databasePath.binding.json';
  }

  /// 只保留安全字符，防止 ownerId 影响文件系统路径。
  static String sanitize(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final isSafe =
          (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5a) ||
          (rune >= 0x61 && rune <= 0x7a) ||
          rune == 0x2d ||
          rune == 0x5f;
      buffer.write(isSafe ? String.fromCharCode(rune) : '_');
    }
    final text = buffer.toString();
    return text.isEmpty ? 'account' : text;
  }
}
