import 'package:flutter/services.dart';

/// Android 文件选择/导出通道（`com.jihuatai.planner/storage`）。
///
/// 原生实现见 `android/app/src/main/kotlin/com/jihuatai/planner/StoragePlugin.kt`。
///
/// 为什么走 SAF（Storage Access Framework）而不是存储权限：
/// - 备份导出让用户自己选位置（下载目录 / 网盘 / U 盘），不需要任何运行时权限；
/// - 导入只拿到用户显式选择的那一个文件的临时读权限，用完即弃；
/// - 完全避开 `READ/WRITE_EXTERNAL_STORAGE` 这类宽权限与分区存储兼容问题。
final class AndroidStorageChannel {
  AndroidStorageChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// 与 `StoragePlugin.CHANNEL` 保持一致。
  static const String channelName = 'com.jihuatai.planner/storage';

  /// 计划台 JSON 备份的 MIME 类型。
  static const String jsonBackupMimeType = 'application/json';

  /// SQLite 快照的 MIME 类型（排障/取证用，不是正式导入格式）。
  static const String databaseSnapshotMimeType = 'application/octet-stream';

  final MethodChannel _channel;

  /// 当前是否有可用宿主 Activity（后台时系统选择器无法弹出）。
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 让用户选择保存位置并写入 [bytes]。用户取消返回 null。
  ///
  /// 这是**一次性完整写入**：要么整份备份写成功，要么返回错误/取消，
  /// 不会留下半份文件（原生侧用 `openOutputStream(uri, "wt")` 截断写）。
  Future<AndroidExportResult?> createDocument({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'createDocument',
        <String, Object?>{
          'fileName': fileName,
          'mimeType': mimeType,
          'bytes': bytes,
        },
      );
    } on MissingPluginException {
      throw const AndroidStorageException(
        code: 'not_supported',
        message: '当前平台不支持系统文件保存对话框（仅 Android 提供）。',
      );
    } on PlatformException catch (error) {
      throw AndroidStorageException.fromPlatform(error);
    }
    if (raw == null) return null;
    return AndroidExportResult(
      displayName: raw['name']?.toString(),
      uri: raw['uri']?.toString(),
      bytes: (raw['bytes'] as num?)?.toInt() ?? bytes.length,
    );
  }

  /// 让用户选择一份备份文件，原生侧会把它**拷贝**到应用缓存后返回本地路径。
  ///
  /// 用户取消返回 null。上层应只在这个临时副本上做校验与恢复，
  /// 用完 `File(path).delete()`（见 `AndroidBackupTransfer`）。
  Future<AndroidImportResult?> openDocument({
    List<String> mimeTypes = const <String>[jsonBackupMimeType],
  }) async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'openDocument',
        <String, Object?>{'mimeTypes': mimeTypes},
      );
    } on MissingPluginException {
      throw const AndroidStorageException(
        code: 'not_supported',
        message: '当前平台不支持系统文件选择器（仅 Android 提供）。',
      );
    } on PlatformException catch (error) {
      throw AndroidStorageException.fromPlatform(error);
    }
    if (raw == null) return null;
    final path = raw['path']?.toString();
    if (path == null || path.isEmpty) {
      throw const AndroidStorageException(
        code: 'io_failed',
        message: '系统未返回可读取的临时文件路径。',
      );
    }
    return AndroidImportResult(
      path: path,
      displayName: raw['name']?.toString(),
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一次成功导出（用户已选好位置并写完）的结果。
final class AndroidExportResult {
  const AndroidExportResult({
    this.displayName,
    this.uri,
    required this.bytes,
  });

  /// 用户实际保存的文件名（系统可能改名）。
  final String? displayName;

  /// `content://` 地址，仅用于展示/日志（不要持久化依赖）。
  final String? uri;

  final int bytes;
}

/// 一次成功导入（已拷贝到应用缓存）的结果。
final class AndroidImportResult {
  const AndroidImportResult({
    required this.path,
    this.displayName,
    required this.bytes,
  });

  /// 应用缓存里的临时副本绝对路径。
  final String path;

  final String? displayName;

  final int bytes;
}

/// 文件通道错误（已转换成可展示的中文说明）。
final class AndroidStorageException implements Exception {
  const AndroidStorageException({required this.code, required this.message});

  final String code;
  final String message;

  factory AndroidStorageException.fromPlatform(PlatformException error) {
    final code = error.code;
    final detail = error.message;
    final message = switch (code) {
      'activity_unavailable' => '当前没有可直接使用的界面，暂时无法打开文件选择器。',
      'busy' => '上一份文件还在处理中，请稍候再试。',
      'file_too_large' => '所选文件过大（上限 64MB），不是计划台备份文件？',
      'read_failed' => '读取所选文件失败：${detail ?? '未知原因'}',
      'write_failed' => '写入备份文件失败：${detail ?? '未知原因'}',
      'open_failed' => '无法打开目标文件：${detail ?? '未知原因'}',
      'no_uri' => '系统未返回文件地址。',
      'invalid_argument' => '调用参数不合法：${detail ?? ''}',
      _ => '文件操作失败：${detail ?? code}',
    };
    return AndroidStorageException(code: code, message: message);
  }

  @override
  String toString() => 'AndroidStorageException($code): $message';
}
