import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/features/cloud_account/util/server_address_input.dart';

void main() {
  group('服务器地址校验', () {
    test('空地址提示必填', () {
      final result = parseServerAddressInput('   ');
      expect(result.ok, isFalse);
      expect(result.error, '请填写服务器地址');
    });

    test('只填域名时默认补 https', () {
      final result = parseServerAddressInput('sync.example.com');
      expect(result.ok, isTrue);
      expect(result.uri, Uri.parse('https://sync.example.com'));
      expect(result.uri!.scheme, 'https');
    });

    test('规范化：去路径、去尾斜杠、主机小写', () {
      final result = parseServerAddressInput(
        '  HTTPS://Sync.Example.com:8443/demo/  ',
      );
      expect(result.ok, isTrue);
      expect(result.uri.toString(), 'https://sync.example.com:8443');
    });

    test('http 非本机地址被拒绝', () {
      final result = parseServerAddressInput('http://sync.example.com');
      expect(result.ok, isFalse);
      expect(result.error, contains('HTTPS'));
    });

    test('http 本机地址作为开发环境例外放行', () {
      final localhost = parseServerAddressInput('http://localhost:8090');
      expect(localhost.ok, isTrue);
      expect(localhost.uri!.scheme, 'http');

      final loopback = parseServerAddressInput('http://127.0.0.1:8090/');
      expect(loopback.ok, isTrue);
      expect(loopback.uri.toString(), 'http://127.0.0.1:8090');
    });

    test('非 http(s) 协议被拒绝', () {
      final result = parseServerAddressInput('ftp://sync.example.com');
      expect(result.ok, isFalse);
      expect(result.error, contains('https://'));
    });

    test('缺少主机名被拒绝', () {
      final result = parseServerAddressInput('https://');
      expect(result.ok, isFalse);
      expect(result.error, contains('格式不正确'));
    });

    test('带空格被拒绝', () {
      final result = parseServerAddressInput('https://exa mple.com');
      expect(result.ok, isFalse);
      expect(result.error, contains('空格'));
    });

    test('地址内嵌账号密码被拒绝', () {
      final result = parseServerAddressInput(
        'https://user:pass@sync.example.com',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('账号密码'));
    });

    test('带查询参数被拒绝', () {
      final result = parseServerAddressInput(
        'https://sync.example.com/api?x=1',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('查询参数'));
    });

    test('非法端口被拒绝', () {
      final result = parseServerAddressInput('https://sync.example.com:99999');
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
    });

    test('回环主机识别', () {
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('192.168.1.10'), isFalse);
      expect(isLoopbackHost('sync.example.com'), isFalse);
    });
  });
}
