import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/platform/platform.dart';

import 'support/platform_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockChannel mock;
  late AndroidStorageChannel storage;

  setUp(() {
    mock = MockChannel(AndroidStorageChannel.channelName)..install();
    storage = AndroidStorageChannel(channel: const MethodChannel(AndroidStorageChannel.channelName));
  });

  tearDown(() {
    mock.uninstall();
  });

  group('AndroidStorageChannel.createDocument（导出）', () {
    test('把文件名 / MIME / 字节原样交给原生，并解析保存结果', () async {
      mock.handler = (MethodCall call) async => <Object?, Object?>{
        'uri': 'content://com.android.providers.downloads/document/42',
        'name': 'jihuatai-backup-20261115-190000.json',
        'bytes': 3,
      };

      final result = await storage.createDocument(
        fileName: 'jihuatai-backup-20261115-190000.json',
        mimeType: AndroidStorageChannel.jsonBackupMimeType,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );

      expect(result, isNotNull);
      expect(result!.displayName, 'jihuatai-backup-20261115-190000.json');
      expect(result.bytes, 3);
      expect(result.uri, contains('content://'));

      final call = mock.callTo('createDocument');
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['fileName'], 'jihuatai-backup-20261115-190000.json');
      expect(arguments['mimeType'], 'application/json');
      expect(arguments['bytes'], isA<Uint8List>());
      expect((arguments['bytes']! as Uint8List).toList(), <int>[1, 2, 3]);
    });

    test('用户取消返回 null（不是错误）', () async {
      mock.handler = (MethodCall call) async => null;

      final result = await storage.createDocument(
        fileName: 'a.json',
        mimeType: AndroidStorageChannel.jsonBackupMimeType,
        bytes: Uint8List.fromList(<int>[1]),
      );

      expect(result, isNull);
    });

    test('原生错误码被翻译成可读中文原因', () async {
      mock.handler = (MethodCall call) async {
        throw PlatformException(code: 'file_too_large', message: '超过上限');
      };

      await expectLater(
        storage.createDocument(
          fileName: 'big.json',
          mimeType: 'application/json',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(
          isA<AndroidStorageException>()
              .having((error) => error.code, 'code', 'file_too_large')
              .having((error) => error.message, 'message', contains('64MB')),
        ),
      );
    });

    test('非 Android 平台（通道未注册）明确报「不支持」', () async {
      mock.uninstall();

      await expectLater(
        storage.createDocument(
          fileName: 'a.json',
          mimeType: 'application/json',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(
          isA<AndroidStorageException>()
              .having((error) => error.code, 'code', 'not_supported'),
        ),
      );
    });
  });

  group('AndroidStorageChannel.openDocument（导入）', () {
    test('返回缓存里的临时副本路径与原始文件名', () async {
      mock.handler = (MethodCall call) async => <Object?, Object?>{
        'path': r'C:\cache\imports\1700000000-backup.json',
        'name': 'backup.json',
        'bytes': 128,
      };

      final result = await storage.openDocument();

      expect(result, isNotNull);
      expect(result!.path, endsWith('backup.json'));
      expect(result.displayName, 'backup.json');
      expect(result.bytes, 128);
      final call = mock.callTo('openDocument');
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['mimeTypes'], isA<List<Object?>>());
    });

    test('用户取消返回 null', () async {
      mock.handler = (MethodCall call) async => null;
      expect(await storage.openDocument(), isNull);
    });

    test('原生未给出路径时按 IO 失败处理', () async {
      mock.handler = (MethodCall call) async => <Object?, Object?>{
        'name': 'backup.json',
        'bytes': 0,
      };

      await expectLater(
        storage.openDocument(),
        throwsA(
          isA<AndroidStorageException>()
              .having((error) => error.code, 'code', 'io_failed'),
        ),
      );
    });
  });

  group('AndroidStorageChannel.isAvailable', () {
    test('原生返回 true/false 时如实透传', () async {
      mock.handler = (MethodCall call) async => true;
      expect(await storage.isAvailable(), isTrue);

      mock.handler = (MethodCall call) async => false;
      expect(await storage.isAvailable(), isFalse);
    });

    test('通道不可用时安全返回 false', () async {
      mock.uninstall();
      expect(await storage.isAvailable(), isFalse);
    });
  });
}
