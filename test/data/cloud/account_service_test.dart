import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/data/data.dart';

import 'fake_planner_server.dart';

/// 记录写入内容的令牌存储，用来断言"密码/令牌不落明文配置"。
final class RecordingTokenStore implements SecureTokenStore {
  final Map<String, String> values = <String, String>{};

  @override
  bool get isAvailable => true;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late FakePlannerServer server;
  const email = 'auth@example.com';
  const password = 'password-123456';
  const ownerId = 'usr_auth_owner';

  setUp(() async {
    server = await FakePlannerServer.start();
    server.addAccount(
      email: email,
      password: password,
      ownerId: ownerId,
      name: '认证测试',
    );
  });

  tearDown(() async {
    await server.close();
  });

  test('连接校验：正式域名拒绝 http，只允许 HTTPS', () async {
    final service = PocketBaseAccountService(tokenStore: MemoryTokenStore());
    addTearDown(service.close);
    await expectLater(
      () => service.connectServer(Uri.parse('http://planner.example.com')),
      throwsA(
        isA<CloudException>().having(
          (error) => error.kind,
          'kind',
          CloudErrorKind.protocol,
        ),
      ),
    );
  });

  test('协议不兼容时拒绝连接', () async {
    server.protocolVersionOverride = 2;
    final service = PocketBaseAccountService(tokenStore: MemoryTokenStore());
    addTearDown(service.close);
    await expectLater(
      () => service.connectServer(server.baseUrl),
      throwsA(
        isA<CloudException>().having(
          (error) => error.kind,
          'kind',
          CloudErrorKind.protocol,
        ),
      ),
    );
  });

  test('登录成功：密码不落存储，令牌写入安全存储', () async {
    final store = RecordingTokenStore();
    final service = PocketBaseAccountService(tokenStore: store);
    addTearDown(service.close);
    await service.connectServer(server.baseUrl);
    final account = await service.login(
      username: email,
      password: password,
    );
    expect(account.ownerId, ownerId);
    expect(account.email, email);
    expect(store.values, isNotEmpty);
    final persisted = store.values.values.join();
    expect(persisted, isNot(contains(password)), reason: '密码绝不能落盘');
    expect(persisted, contains('token'));
    expect(await service.requireToken(), isNotEmpty);
  });

  test('登录失败统一提示账号或密码不正确', () async {
    final service = PocketBaseAccountService(tokenStore: MemoryTokenStore());
    addTearDown(service.close);
    await service.connectServer(server.baseUrl);
    await expectLater(
      () => service.login(username: email, password: 'wrong-password'),
      throwsA(
        isA<CloudException>().having(
          (error) => error.kind,
          'kind',
          CloudErrorKind.unauthorized,
        ),
      ),
    );
    expect(service.currentAccount(), isNull);
  });

  test('恢复会话 + 刷新令牌 + 退出登录', () async {
    final store = RecordingTokenStore();
    final first = PocketBaseAccountService(tokenStore: store);
    await first.connectServer(server.baseUrl);
    await first.login(username: email, password: password);
    await first.close();

    final second = PocketBaseAccountService(tokenStore: store);
    addTearDown(second.close);
    final restored = await second.restoreSession();
    expect(restored?.ownerId, ownerId);
    final token = await second.requireToken();
    final refreshed = await second.refreshToken();
    expect(refreshed, isNot(token));
    expect(await second.requireToken(), refreshed);

    await second.logout();
    expect(second.currentAccount(), isNull);
    expect(store.values, isEmpty);
    expect(await second.restoreSession(), isNull);
  });

  test('令牌过期且刷新失败：清除会话并返回 null', () async {
    server.tokenTtlOverride = const Duration(seconds: -1);
    final store = RecordingTokenStore();
    final service = PocketBaseAccountService(tokenStore: store);
    addTearDown(service.close);
    await service.connectServer(server.baseUrl);
    await service.login(username: email, password: password);
    expect(store.values, isNotEmpty);

    final restored = await service.restoreSession();
    expect(restored, isNull);
    expect(service.currentAccount(), isNull);
    expect(store.values, isEmpty);
  });
}
