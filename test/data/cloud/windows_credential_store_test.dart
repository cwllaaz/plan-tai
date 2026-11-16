import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/data/data.dart';

void main() {
  test('Windows 凭据管理器：写入/读取/删除（不存在时返回 null）', () async {
    if (!Platform.isWindows) {
      return;
    }
    final store = WindowsCredentialStore(targetPrefix: 'JihuaTaiTest');
    const key = 'smoke-session';
    expect(store.isAvailable, isTrue);
    try {
      await store.delete(key);
      expect(await store.read(key), isNull);
      await store.write(key, '{"token":"abc"}');
      expect(await store.read(key), '{"token":"abc"}');
      await store.delete(key);
      expect(await store.read(key), isNull);
    } finally {
      await store.delete(key);
    }
  });

  test('Windows 凭据管理器：大内容 gzip 压缩后仍可读回', () async {
    if (!Platform.isWindows) return;
    final store = WindowsCredentialStore(targetPrefix: 'JihuaTaiTest');
    const key = 'large-session';
    final value = 'x' * 6000;
    try {
      await store.write(key, value);
      expect(await store.read(key), value);
    } finally {
      await store.delete(key);
    }
  });
}
