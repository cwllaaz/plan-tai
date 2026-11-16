/// Android 安全令牌存储（Dart 侧）测试。
///
/// 用 `flutter_test` 的 mock method call handler 模拟原生 Keystore 通道，
/// 覆盖：探测、读写删、key 命名空间、体积上限、异常归一化、超时、缺插件。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/data/cloud/android_secure_token_store.dart';
import 'package:jihuatai/data/cloud/secure_token_store.dart';

const MethodChannel _channel = MethodChannel(
  AndroidSecureTokenStore.channelName,
);

/// 模拟原生 Keystore + SharedPreferences：只在测试内存里保存密文。
///
/// 行为对齐 B 交付的 `SecureStorePlugin.kt`：
/// - 接收命名参数 `{key, value}`；
/// - 原生侧自己给 key 加 `JihuaTai/` 命名空间后再存 SharedPreferences。
final class _FakeNativeKeystore {
  static const String storagePrefix = 'JihuaTai/';

  final Map<String, String> values = <String, String>{};
  final List<MethodCall> calls = <MethodCall>[];
  bool available = true;
  PlatformException? nextError;
  Completer<void>? blockNextCall;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final blocked = blockNextCall;
    if (blocked != null) {
      blockNextCall = null;
      await blocked.future;
    }
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    final arguments = call.arguments is Map<Object?, Object?>
        ? Map<String, Object?>.from(call.arguments! as Map<Object?, Object?>)
        : const <String, Object?>{};
    final key = arguments['key'] as String?;
    final storageKey = key == null ? null : '$storagePrefix$key';
    switch (call.method) {
      case 'isAvailable':
        return available;
      case 'read':
        return storageKey == null ? null : values[storageKey];
      case 'write':
        values[storageKey!] = arguments['value'] as String;
        return null;
      case 'delete':
        if (storageKey != null) values.remove(storageKey);
        return null;
      default:
        throw PlatformException(code: 'UNKNOWN_METHOD', message: call.method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNativeKeystore native;
  final List<void Function()> cleanups = <void Function()>[];

  void installHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, native.handle);
    cleanups.add(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });
  }

  setUp(() {
    native = _FakeNativeKeystore();
    installHandler();
  });

  tearDown(() {
    for (final cleanup in cleanups) {
      cleanup();
    }
    cleanups.clear();
  });

  test('探测成功后可读可写可删；命名空间由原生侧补齐（与 B 的实现一致）', () async {
    final store = AndroidSecureTokenStore();
    expect(store.isAvailable, isFalse);

    expect(await store.probe(), isTrue);
    expect(store.isAvailable, isTrue);
    expect(store.unavailableReason, isNull);
    expect(native.calls.single.method, 'isAvailable');

    await store.write('JihuaTai/cloud-session', '{"token":"abc"}');
    // 原生侧 SecureStorePlugin.kt 会把收到的 key 存成 JihuaTai/<key>；
    // Dart 侧已去掉重复命名空间，因此最终存储名恰好是 JihuaTai/cloud-session。
    final writeCall = native.calls.last;
    expect(
      (writeCall.arguments! as Map<Object?, Object?>)['key'],
      'cloud-session',
      reason: '通道上传输的是业务 key，JihuaTai/ 前缀由原生侧追加',
    );
    expect(
      native.values['${_FakeNativeKeystore.storagePrefix}cloud-session'],
      '{"token":"abc"}',
    );

    await store.write('theme', 'light');
    expect(
      native.values['${_FakeNativeKeystore.storagePrefix}theme'],
      'light',
    );

    expect(await store.read('JihuaTai/cloud-session'), '{"token":"abc"}');
    expect(await store.read('theme'), 'light');
    expect(await store.read('missing'), isNull);

    await store.delete('JihuaTai/cloud-session');
    expect(
      native.values.containsKey(
        '${_FakeNativeKeystore.storagePrefix}cloud-session',
      ),
      isFalse,
    );
    // 删除不存在的 key 不抛异常。
    await store.delete('missing');
  });

  test('UTF-8 中文与多行 JSON 原样往返', () async {
    final store = AndroidSecureTokenStore();
    await store.probe();
    const payload = '{"email":"测试账号@example.com","note":"第一行\\n第二行 ✓"}';
    await store.write('JihuaTai/cloud-session', payload);
    expect(await store.read('JihuaTai/cloud-session'), payload);
  });

  test('原生通道报告不可用时：probe=false 且读写抛 CloudException', () async {
    native.available = false;
    final store = AndroidSecureTokenStore();
    expect(await store.probe(), isFalse);
    expect(store.isAvailable, isFalse);
    expect(store.unavailableReason, isA<CloudException>());

    await expectLater(
      store.read('JihuaTai/cloud-session'),
      throwsA(
        isA<CloudException>().having(
          (CloudException e) => e.kind,
          'kind',
          CloudErrorKind.unknown,
        ),
      ),
    );
    await expectLater(
      store.write('JihuaTai/cloud-session', 'x'),
      throwsA(isA<CloudException>()),
    );
    await expectLater(
      store.delete('JihuaTai/cloud-session'),
      throwsA(isA<CloudException>()),
    );
  });

  test('没有原生实现（MissingPluginException）时不崩溃，按不可用处理', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    final store = AndroidSecureTokenStore();
    expect(await store.probe(), isFalse);
    expect(store.isAvailable, isFalse);
    final reason = store.unavailableReason;
    expect(reason, isNotNull);
    expect(reason!.message, contains('安全存储'));
  });

  test('写入超过 8KB 的令牌被拒绝，且不会调用原生通道', () async {
    final store = AndroidSecureTokenStore();
    await store.probe();
    final huge = 'a' * (AndroidSecureTokenStore.defaultMaxValueBytes + 1);
    await expectLater(
      store.write('JihuaTai/cloud-session', huge),
      throwsA(
        isA<CloudException>().having(
          (CloudException e) => e.kind,
          'kind',
          CloudErrorKind.protocol,
        ),
      ),
    );
    expect(native.calls.where((MethodCall c) => c.method == 'write'), isEmpty);
  });

  test('原生异常被归一化为 CloudException，且 message 不含令牌内容', () async {
    final store = AndroidSecureTokenStore();
    await store.probe();
    native.nextError = PlatformException(
      code: 'KEYSTORE_LOCKED',
      message: 'detail-of-native-error',
    );
    try {
      await store.read('JihuaTai/cloud-session');
      fail('应当抛出 CloudException');
    } on CloudException catch (error) {
      expect(error.kind, CloudErrorKind.unknown);
      expect(error.message, contains('KEYSTORE_LOCKED'));
      expect(error.message, isNot(contains('detail-of-native-error')));
      expect(error.cause, isA<PlatformException>());
    }
  });

  test('通道超时被归一化为 timeout 且可重试', () async {
    final store = AndroidSecureTokenStore(
      timeout: const Duration(milliseconds: 20),
    );
    await store.probe();
    native.blockNextCall = Completer<void>();
    await expectLater(
      store.read('JihuaTai/cloud-session'),
      throwsA(
        isA<CloudException>()
            .having((CloudException e) => e.kind, 'kind', CloudErrorKind.timeout)
            .having((CloudException e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('read 返回非文本内容时拒绝使用（协议错误）', () async {
    final store = AndroidSecureTokenStore();
    await store.probe();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          if (call.method == 'read') return <int>[1, 2, 3];
          return true;
        });
    await expectLater(
      store.read('JihuaTai/cloud-session'),
      throwsA(
        isA<CloudException>().having(
          (CloudException e) => e.kind,
          'kind',
          CloudErrorKind.protocol,
        ),
      ),
    );
  });

  test('MemoryTokenStore 仅用于测试且 isAvailable=true', () async {
    final SecureTokenStore store = MemoryTokenStore();
    expect(store.isAvailable, isTrue);
    await store.write('a', 'b');
    expect(await store.read('a'), 'b');
    await store.delete('a');
    expect(await store.read('a'), isNull);
  });
}
