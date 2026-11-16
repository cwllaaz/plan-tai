import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/platform/open_directory.dart';

void main() {
  group('directoryOpenerCommand', () {
    test('Windows 使用 explorer.exe（保持原行为）', () {
      expect(directoryOpenerCommand('windows'), 'explorer.exe');
    });

    test('Linux 使用 xdg-open', () {
      expect(directoryOpenerCommand('linux'), 'xdg-open');
    });

    test('macOS 使用 open', () {
      expect(directoryOpenerCommand('macos'), 'open');
    });

    test('未知平台明确抛 UnsupportedError', () {
      expect(
        () => directoryOpenerCommand('fuchsia'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('openDirectory', () {
    test('Linux 分支执行 xdg-open 并传目录路径（不再硬编码 explorer.exe）', () async {
      final calls = <List<String>>[];
      final result = await openDirectory(
        '/home/ubuntu/.local/share/计划台/data',
        operatingSystem: 'linux',
        runner: (executable, arguments) async {
          calls.add(<String>[executable, ...arguments]);
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(calls, <List<String>>[
        <String>['xdg-open', '/home/ubuntu/.local/share/计划台/data'],
      ]);
      expect(result.exitCode, 0);
    });

    test('Windows 分支仍然执行 explorer.exe', () async {
      final calls = <List<String>>[];
      await openDirectory(
        r'C:\Users\u\AppData\Roaming\计划台\data',
        operatingSystem: 'windows',
        runner: (executable, arguments) async {
          calls.add(<String>[executable, ...arguments]);
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(calls.single.first, 'explorer.exe');
    });

    test('平台命令不存在时异常向上抛（由调用方提示用户）', () async {
      await expectLater(
        openDirectory(
          '/tmp/x',
          operatingSystem: 'linux',
          runner: (executable, arguments) async {
            throw ProcessException(executable, arguments, '没有图形会话', 1);
          },
        ),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
