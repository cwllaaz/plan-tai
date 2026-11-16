/// 账号工作区指针（`<data>/cloud_workspace.json`）。
///
/// 首次绑定「以云端为准 / 两边都有数据」时，同步引擎会在
/// `<data>/accounts/<ownerId>/app.db` 新建独立工作区，并返回
/// `requiresRestart = true`。重启后 `main` 需要知道该打开哪个库，
/// 因此由集成层记录一个**只含路径与归属**的指针文件：
///
/// ```json
/// {
///   "version": 1,
///   "ownerId": "abc123",
///   "databasePath": "accounts/abc123/app.db",
///   "updatedAt": "2026-11-15T08:00:00.000000Z"
/// }
/// ```
///
/// 该文件不含 token、密码或任何业务数据；删除它即可回到默认本地库。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class CloudWorkspaceStore {
  CloudWorkspaceStore(this.dataDirectory);

  final String dataDirectory;

  String get _path => p.join(dataDirectory, 'cloud_workspace.json');

  /// 当前应打开的账号工作区库；没有指针或文件不存在时返回 null。
  String? activeDatabasePath() {
    final raw = read();
    if (raw == null) return null;
    final databasePath = raw['databasePath'];
    if (databasePath is! String || databasePath.isEmpty) return null;
    final resolved = p.isAbsolute(databasePath)
        ? databasePath
        : p.join(dataDirectory, databasePath);
    if (!File(resolved).existsSync()) return null;
    return resolved;
  }

  String? activeOwnerId() {
    final raw = read();
    final owner = raw?['ownerId'];
    return owner is String && owner.isNotEmpty ? owner : null;
  }

  Map<String, Object?>? read() {
    final file = File(_path);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<Object?, Object?>) return null;
      return Map<String, Object?>.from(decoded);
    } on Object {
      return null;
    }
  }

  /// 记录账号工作区。路径尽量相对于数据目录保存，便于整体迁移。
  void remember(String ownerId, String databasePath) {
    final relative = p.isWithin(dataDirectory, databasePath)
        ? p.relative(databasePath, from: dataDirectory)
        : databasePath;
    _write(<String, Object?>{
      'version': 1,
      'ownerId': ownerId,
      'databasePath': relative,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void clear() {
    final file = File(_path);
    if (file.existsSync()) file.deleteSync();
  }

  void _write(Map<String, Object?> value) {
    final file = File(_path);
    Directory(p.dirname(_path)).createSync(recursive: true);
    final temp = File('$_path.tmp');
    temp.writeAsStringSync(jsonEncode(value), flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(_path);
  }
}
