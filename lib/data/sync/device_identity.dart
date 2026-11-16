/// 安装级设备身份（`device.json`）。
///
/// 按 docs/sync/ACCOUNT_BINDING.md §3.3：设备 ID 不放进数据库，也不随备份复制。
/// 默认位置 `%APPDATA%\计划台\data\device.json`；测试用数据库所在目录，
/// 避免读到真实用户目录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/models.dart';
import '../entity_codec.dart';

final class DeviceIdentityStore {
  DeviceIdentityStore._(this.directory);

  /// 数据目录；为 null 时只使用进程内临时 ID（内存数据库测试）。
  final String? directory;

  static final Map<String, DeviceIdentityStore> _cache =
      <String, DeviceIdentityStore>{};

  static const String fileName = 'device.json';

  static DeviceIdentityStore forDirectory(String? directory) {
    if (directory == null) return DeviceIdentityStore._(null);
    final normalized = p.normalize(directory);
    return _cache.putIfAbsent(
      normalized,
      () => DeviceIdentityStore._(normalized),
    );
  }

  static DeviceIdentityStore forDatabase(String? databasePath) {
    if (databasePath == null) return DeviceIdentityStore._(null);
    return forDirectory(p.dirname(databasePath));
  }

  String? _deviceId;

  String get deviceId {
    final cached = _deviceId;
    if (cached != null) return cached;
    final loaded = directory == null
        ? Ids.newId()
        : _loadOrCreate(directory!);
    _deviceId = loaded;
    return loaded;
  }

  String _loadOrCreate(String dir) {
    final file = File(p.join(dir, fileName));
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, Object?>) {
          final value = decoded['deviceId'];
          if (value is String && Ids.isValidAnyVersion(value)) return value;
        }
      } on FormatException {
        // 文件损坏：重新生成（不影响业务数据）。
      }
    }
    final created = Ids.newId();
    try {
      Directory(dir).createSync(recursive: true);
      _writeAtomically(file, <String, Object?>{
        'deviceId': created,
        'createdAt': encodeInstant(DateTime.now().toUtc()),
        'platform': Platform.operatingSystem,
      });
    } on FileSystemException {
      // 落盘失败时本次会话仍可用。
    }
    return created;
  }

  static void _writeAtomically(File target, Map<String, Object?> json) {
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(jsonEncode(json), flush: true);
    if (target.existsSync()) target.deleteSync();
    temp.renameSync(target.path);
  }
}
