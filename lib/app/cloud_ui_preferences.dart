/// 云账号 UI 的普通配置：只保存服务器地址，绝不保存密码或 token。
///
/// 存放位置：`<data>/cloud_ui.json`（与 `app.db` 同级，随数据目录迁移）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../features/cloud_account/cloud_account.dart';

final class FileCloudUiPreferences implements CloudUiPreferences {
  FileCloudUiPreferences(this.dataDirectory);

  final String dataDirectory;

  String get _path => p.join(dataDirectory, 'cloud_ui.json');

  @override
  Future<String?> readServerAddress() async {
    final file = File(_path);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<Object?, Object?>) return null;
      final value = decoded['serverAddress'];
      return value is String && value.trim().isNotEmpty ? value : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeServerAddress(String? address) async {
    final file = File(_path);
    Directory(p.dirname(_path)).createSync(recursive: true);
    final value = <String, Object?>{
      'version': 1,
      'serverAddress': address,
    };
    final temp = File('$_path.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(_path);
  }
}
