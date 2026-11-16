/// Linux Secret Service 真实环境冒烟测试（不注入 runner，直接调用系统 `secret-tool`）。
///
/// 需要满足：运行环境有 D-Bus 会话 + 已解锁的 keyring（GNOME Keyring / KWallet）。
/// 默认跳过；在 Linux CI/验收机里这样运行：
/// ```bash
/// dbus-launch --sh-syntax >/dev/null
/// eval "$(dbus-launch --sh-syntax)"
/// printf '%s' 'keyringpass' | gnome-keyring-daemon --unlock --components=secrets
/// JIHUATAI_SECRET_SMOKE=1 flutter test test/integration/linux_keyring_e2e_test.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/data/cloud/linux_credential_store.dart';

void main() {
  final enabled = Platform.environment['JIHUATAI_SECRET_SMOKE'] == '1';

  test('LinuxCredentialStore 真实 Secret Service 写入/读取/删除往返', () async {
    final store = LinuxCredentialStore();
    expect(store.isAvailable, isTrue);
    final key =
        'JihuaTai/e2e-smoke-${DateTime.now().microsecondsSinceEpoch}';
    final session = <String, Object?>{
      'token': 'smoke-token-value',
      'expiresAt': '2026-11-16T00:00:00.000Z',
      'ownerId': 'smoke-owner',
      'email': 'smoke@jihuatai.local',
      'serverUrl': 'http://127.0.0.1:8090',
    };
    final value = jsonEncode(session);

    await store.write(key, value);
    final read = await store.read(key);
    expect(read, isNotNull);
    final decoded = jsonDecode(read!) as Map<String, Object?>;
    expect(decoded['token'], 'smoke-token-value');
    expect(decoded['ownerId'], 'smoke-owner');

    await store.delete(key);
    expect(await store.read(key), isNull);
  }, skip: enabled ? false : '设置 JIHUATAI_SECRET_SMOKE=1 且在已解锁 keyring 的 D-Bus 会话中运行');
}
