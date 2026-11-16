/// `sync_state` 单行表的读写：游标、上次同步时间、自动同步开关、错误与对账标记。
library;

import 'package:sqlite3/sqlite3.dart';

import '../entity_codec.dart';
import '../planner_database.dart';

final class SyncStateStore {
  SyncStateStore(this.database);

  final PlannerDatabase database;

  Database get _handle => database.handle;

  String? get cursor => _string('cursor');

  void setCursor(String? value) => _set('cursor', value);

  DateTime? get lastSyncAt {
    final raw = _string('last_sync_at');
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  void setLastSyncAt(DateTime value) =>
      _set('last_sync_at', encodeInstant(value));

  bool get autoSync => _int('auto_sync') != 0;

  void setAutoSync(bool value) {
    setAutoUpload(value);
    setAutoDownload(value);
  }

  /// 自动上传：优先读 settings 里的独立键；老库没有该键时继承旧的单一开关。
  bool get autoUpload => _boolSetting(_autoUploadKey, fallback: autoSync);

  void setAutoUpload(bool value) {
    _setSetting(_autoUploadKey, value ? '1' : '0');
    _setInt('auto_sync', (value || autoDownload) ? 1 : 0);
  }

  /// 自动下载：优先读 settings 里的独立键；老库没有该键时继承旧的单一开关。
  bool get autoDownload => _boolSetting(_autoDownloadKey, fallback: autoSync);

  void setAutoDownload(bool value) {
    _setSetting(_autoDownloadKey, value ? '1' : '0');
    _setInt('auto_sync', (value || autoUpload) ? 1 : 0);
  }

  DateTime? get lastUploadAt => _instantSetting(_lastUploadKey);

  void setLastUploadAt(DateTime value) =>
      _setSetting(_lastUploadKey, encodeInstant(value));

  DateTime? get lastDownloadAt => _instantSetting(_lastDownloadKey);

  void setLastDownloadAt(DateTime value) =>
      _setSetting(_lastDownloadKey, encodeInstant(value));

  static const String _autoUploadKey = 'sync_auto_upload';
  static const String _autoDownloadKey = 'sync_auto_download';
  static const String _lastUploadKey = 'sync_last_upload_at';
  static const String _lastDownloadKey = 'sync_last_download_at';

  String? get lastError => _string('last_error');

  void setLastError(String? value) => _set('last_error', value);

  bool get needsReconcile => _int('needs_reconcile') != 0;

  void setNeedsReconcile(bool value) =>
      _setInt('needs_reconcile', value ? 1 : 0);

  // -------------------------------------------------------------------------

  String? _setting(String key) {
    final rows = _handle.select(
      'SELECT value FROM settings WHERE key = ?',
      <Object?>[key],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['value'];
    return value is String ? value : null;
  }

  void _setSetting(String key, String? value) {
    _handle.execute(
      'INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)',
      <Object?>[key, value],
    );
  }

  bool _boolSetting(String key, {required bool fallback}) {
    final raw = _setting(key);
    if (raw == null) return fallback;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  DateTime? _instantSetting(String key) {
    final raw = _setting(key);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  String? _string(String column) {
    final row = _handle
        .select('SELECT $column AS value FROM sync_state WHERE id = 1')
        .first;
    final value = row['value'];
    return value is String ? value : null;
  }

  int _int(String column) {
    final row = _handle
        .select('SELECT $column AS value FROM sync_state WHERE id = 1')
        .first;
    final value = row['value'];
    return value is int ? value : 0;
  }

  void _set(String column, String? value) {
    _handle.execute('UPDATE sync_state SET $column = ? WHERE id = 1', <Object?>[
      value,
    ]);
  }

  void _setInt(String column, int value) {
    _handle.execute('UPDATE sync_state SET $column = ? WHERE id = 1', <Object?>[
      value,
    ]);
  }
}
