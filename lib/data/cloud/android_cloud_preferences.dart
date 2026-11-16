/// Android 云端模块的普通配置（**不含任何密钥**）。
///
/// 为什么需要它：同步引擎把「自动上传 / 自动下载」开关存在 SQLite 的
/// `settings` 表里，但无法区分「用户主动关闭」与「从未设置」。Android 首版
/// 默认开启前台自动同步，用一个独立小文件记录「是否已经做过默认设置」，
/// 避免用户关掉开关后下次启动又被打开。
///
/// 存放位置：`<data>/android_cloud.json`（与 `app.db` 同级，随数据目录迁移）。
/// 文件损坏/缺失一律按「未配置」处理，不抛异常、不影响本地功能。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class AndroidCloudPreferences {
  AndroidCloudPreferences(this.dataDirectory);

  final String dataDirectory;

  bool _autoSyncConfigured = false;

  /// 是否已写入过「自动同步默认开启」的设置。
  bool get autoSyncConfigured => _autoSyncConfigured;

  String get filePath => p.join(dataDirectory, fileName);

  static const String fileName = 'android_cloud.json';

  Future<void> load() async {
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<Object?, Object?>) return;
      final json = Map<String, Object?>.from(decoded);
      _autoSyncConfigured = json['autoSyncConfigured'] == true;
    } on Object {
      // 配置坏了不影响任何功能：按「未配置」继续。
      _autoSyncConfigured = false;
    }
  }

  Future<void> markAutoSyncConfigured() async {
    if (_autoSyncConfigured) return;
    _autoSyncConfigured = true;
    await _save();
  }

  Future<void> _save() async {
    final file = File(filePath);
    Directory(p.dirname(filePath)).createSync(recursive: true);
    final json = <String, Object?>{
      'version': 1,
      'autoSyncConfigured': _autoSyncConfigured,
    };
    final temp = File('$filePath.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(filePath);
  }
}
