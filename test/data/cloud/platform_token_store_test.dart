import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud_types.dart';
import 'package:jihuatai/data/cloud/linux_credential_store.dart';
import 'package:jihuatai/data/cloud/platform_token_store.dart';
import 'package:jihuatai/data/cloud/windows_credential_store.dart';

void main() {
  group('createPlatformTokenStore', () {
    test('Windows 仍返回 Windows 凭据管理器实现（Windows 行为不变）', () {
      if (!Platform.isWindows) return;
      final store = createPlatformTokenStore();
      expect(store, isA<WindowsCredentialStore>());
      expect(store.isAvailable, isTrue);
    });

    test('Linux 返回 Secret Service 实现', () {
      if (!Platform.isLinux) return;
      expect(createPlatformTokenStore(), isA<LinuxCredentialStore>());
    });
  });

  group('UnsupportedTokenStore', () {
    test('明确不可用，且读写删都抛 CloudException（不提供明文兜底）', () async {
      const store = UnsupportedTokenStore();
      expect(store.isAvailable, isFalse);
      await expectLater(store.read('k'), throwsA(isA<CloudException>()));
      await expectLater(store.write('k', 'v'), throwsA(isA<CloudException>()));
      await expectLater(store.delete('k'), throwsA(isA<CloudException>()));
    });
  });
}
