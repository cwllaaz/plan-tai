/// Android 云端普通配置测试（自动同步默认策略的去重标记）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/data/cloud/android_cloud_preferences.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('jihuatai_android_prefs_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('文件不存在时按未配置处理', () async {
    final preferences = AndroidCloudPreferences(directory.path);
    await preferences.load();
    expect(preferences.autoSyncConfigured, isFalse);
    expect(File(preferences.filePath).existsSync(), isFalse);
  });

  test('标记后落盘，重新加载仍为已配置', () async {
    final first = AndroidCloudPreferences(directory.path);
    await first.load();
    await first.markAutoSyncConfigured();
    expect(first.autoSyncConfigured, isTrue);
    expect(File(p.join(directory.path, 'android_cloud.json')).existsSync(), isTrue);

    final second = AndroidCloudPreferences(directory.path);
    await second.load();
    expect(second.autoSyncConfigured, isTrue);
  });

  test('重复标记不重复写文件（幂等）', () async {
    final preferences = AndroidCloudPreferences(directory.path);
    await preferences.load();
    await preferences.markAutoSyncConfigured();
    final file = File(preferences.filePath);
    final modified = file.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await preferences.markAutoSyncConfigured();
    expect(file.lastModifiedSync(), modified);
  });

  test('文件损坏时按未配置处理，不抛异常', () async {
    final path = p.join(directory.path, 'android_cloud.json');
    File(path).writeAsStringSync('{ not json');
    final preferences = AndroidCloudPreferences(directory.path);
    await preferences.load();
    expect(preferences.autoSyncConfigured, isFalse);
  });

  test('配置不包含任何密钥字段', () async {
    final preferences = AndroidCloudPreferences(directory.path);
    await preferences.load();
    await preferences.markAutoSyncConfigured();
    final text = File(preferences.filePath).readAsStringSync();
    expect(text, isNot(contains('token')));
    expect(text, isNot(contains('password')));
    expect(text, isNot(contains('secret')));
  });
}
