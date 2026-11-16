import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:path/path.dart' as p;

/// 每个用例一个隔离的「模拟应用私有目录」。
///
/// 命名与真实 Android 无关（测试跑在 Windows），但目录结构完全同构：
/// `<base>/data/app.db`、`<base>/data/backups`。
final class TempBase {
  TempBase._(this.directory);

  final Directory directory;

  static TempBase create() =>
      TempBase._(Directory.systemTemp.createTempSync('jihuatai_platform_test_'));

  String get path => directory.path;

  String get dataDirectory => p.join(path, 'data');

  String get databasePath => p.join(dataDirectory, 'app.db');

  String get backupDirectory => p.join(dataDirectory, 'backups');

  void delete() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}

/// 便捷构造日历日。
LocalDate d(String iso) => LocalDate.parse(iso);

/// 记录所有调用并允许注入返回值的 mock MethodChannel。
final class MockChannel {
  MockChannel(this.name);

  final String name;

  final List<MethodCall> calls = <MethodCall>[];

  Future<Object?> Function(MethodCall call)? handler;

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  MethodChannel get channel => MethodChannel(name);

  void install() {
    _messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      final current = handler;
      if (current == null) return null;
      return current(call);
    });
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(channel, null);
  }

  MethodCall callTo(String method) =>
      calls.firstWhere((MethodCall call) => call.method == method);

  bool hasCall(String method) =>
      calls.any((MethodCall call) => call.method == method);
}
