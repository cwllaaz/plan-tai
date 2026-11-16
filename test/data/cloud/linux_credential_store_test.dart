import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud_types.dart';
import 'package:jihuatai/data/cloud/linux_credential_store.dart';
import 'package:jihuatai/data/cloud/secure_token_store.dart';

/// 记录一次 `secret-tool` 调用。
final class _Call {
  _Call(this.arguments, this.stdinText);

  final List<String> arguments;
  final String? stdinText;
}

/// 用假 runner 构造 store，模拟 secret-tool 的各种返回。
LinuxCredentialStore _storeWith(
  List<_Call> calls, {
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
  bool throwProcessException = false,
}) {
  return LinuxCredentialStore(
    runner: (arguments, stdinText) async {
      calls.add(_Call(arguments, stdinText));
      if (throwProcessException) {
        throw ProcessException('secret-tool', arguments, 'No such file', 2);
      }
      return ProcessResult(1, exitCode, stdout, stderr);
    },
  );
}

void main() {
  const key = 'JihuaTai/cloud-session';
  const value = '{"token":"SECRET-TOKEN","ownerId":"u1"}';

  group('LinuxCredentialStore 读写', () {
    test('write 通过 stdin 传 secret，属性走参数（不出现在命令行可见的明文文件里）', () async {
      final calls = <_Call>[];
      final store = _storeWith(calls);

      await store.write(key, value);

      expect(store.isAvailable, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.stdinText, value);
      expect(
        calls.single.arguments,
        containsAllInOrder(<String>[
          'store',
          '--label',
          '计划台 云同步令牌',
          'service',
          'jihuatai',
          'key',
          key,
        ]),
      );
      // 属性里不能带 secret 本身
      expect(calls.single.arguments.join(' '), isNot(contains('SECRET-TOKEN')));
    });

    test('read 返回 secret-tool 输出（去掉行尾换行）', () async {
      final calls = <_Call>[];
      final store = _storeWith(calls, stdout: '$value\n');

      expect(await store.read(key), value);
      expect(calls.single.arguments, containsAllInOrder(<String>['lookup', 'service', 'jihuatai', 'key', key]));
    });

    test('read 未找到返回 null（不抛错、不当成明文回退）', () async {
      final calls = <_Call>[];
      final store = _storeWith(calls, exitCode: 1);

      expect(await store.read(key), isNull);
    });

    test('delete 正常删除（exit 0 或 1 视为已删除）', () async {
      final calls = <_Call>[];
      final store = _storeWith(calls);
      await store.delete(key);
      expect(calls.single.arguments.first, 'clear');

      final calls2 = <_Call>[];
      final store2 = _storeWith(calls2, exitCode: 1);
      await store2.delete(key); // 不存在也应成功
    });
  });

  group('LinuxCredentialStore 失败契约', () {
    test('Secret Service 不可用时抛 CloudException 且给出安装/解锁指引', () async {
      final calls = <_Call>[];
      final store = _storeWith(
        calls,
        exitCode: 1,
        stderr: 'Cannot autolaunch D-Bus without X11 \$DISPLAY',
      );

      await expectLater(
        store.write(key, value),
        throwsA(
          isA<CloudException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Secret Service'),
              contains('gnome-keyring'),
              contains('KWallet'),
            ),
          ),
        ),
      );
      // 错误信息里绝不能出现 token
      try {
        await store.write(key, value);
      } on CloudException catch (error) {
        expect(error.message, isNot(contains('SECRET-TOKEN')));
      }
      expect(calls, hasLength(2));
    });

    test('secret-tool 不存在（ProcessException）→ CloudException 并标记不可用', () async {
      final calls = <_Call>[];
      final store = _storeWith(calls, throwProcessException: true);

      await expectLater(
        store.read(key),
        throwsA(
          isA<CloudException>().having(
            (e) => e.message,
            'message',
            contains('libsecret-tools'),
          ),
        ),
      );
      expect(store.isAvailable, isFalse);

      // 已确认不可用后不再反复调用进程，但仍必须抛错而不是返回明文/空值
      await expectLater(store.read(key), throwsA(isA<CloudException>()));
      expect(calls, hasLength(1));
    });

    test('实现类满足 SecureTokenStore 契约', () {
      final store = LinuxCredentialStore(
        runner: (arguments, stdinText) async => ProcessResult(1, 0, '', ''),
      );
      expect(store, isA<SecureTokenStore>());
    });
  });
}
