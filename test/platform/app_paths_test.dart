import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/data/planner_paths.dart';
import 'package:jihuatai/platform/app_paths.dart';

void main() {
  group('AppPaths.isEphemeralDirectory', () {
    test('Android 应用私有 files 目录不是临时目录', () {
      expect(
        AppPaths.isEphemeralDirectory(
          '/data/user/0/com.jihuatai.planner/files',
        ),
        isFalse,
      );
      expect(
        AppPaths.isEphemeralDirectory(
          '/data/data/com.jihuatai.planner/files/data',
        ),
        isFalse,
      );
    });

    test('cache / temp / no_backup 目录必须判定为临时目录', () {
      const ephemeral = <String>[
        '/data/user/0/com.jihuatai.planner/cache',
        '/data/user/0/com.jihuatai.planner/code_cache',
        '/data/user/0/com.jihuatai.planner/files/no_backup',
        '/storage/emulated/0/Android/data/com.jihuatai.planner/cache',
        r'C:\Users\someone\AppData\Local\Temp\jihuatai_test',
        '/tmp/jihuatai',
      ];
      for (final path in ephemeral) {
        expect(
          AppPaths.isEphemeralDirectory(path),
          isTrue,
          reason: '$path 应判定为临时目录',
        );
      }
    });

    test('Windows 用户数据目录不是临时目录', () {
      expect(
        AppPaths.isEphemeralDirectory(r'C:\Users\someone\AppData\Roaming\计划台\data'),
        isFalse,
      );
    });

    test('空路径视为临时目录（防御空字符串误用）', () {
      expect(AppPaths.isEphemeralDirectory(''), isTrue);
      expect(AppPaths.isEphemeralDirectory('   '), isTrue);
      expect(AppPaths.isEphemeralDirectory('.'), isTrue);
    });
  });

  group('AppPaths.resolveBaseDirectory（桌面平台行为不变）', () {
    tearDown(() {
      PlannerPaths.useBaseDirectory(null);
    });

    test('桌面沿用 PlannerPaths.defaultBaseDirectory', () async {
      if (Platform.isAndroid) return; // 仅桌面语义
      PlannerPaths.useBaseDirectory(null);
      final resolved = await AppPaths.resolveBaseDirectory();
      expect(resolved, PlannerPaths.defaultBaseDirectory());
    });

    test('注入后的基目录会被优先使用（Android 正式路径靠它）', () async {
      if (Platform.isAndroid) return;
      final base = Directory.systemTemp.createTempSync('jihuatai_app_paths_');
      addTearDown(() {
        PlannerPaths.useBaseDirectory(null);
        if (base.existsSync()) base.deleteSync(recursive: true);
      });
      PlannerPaths.useBaseDirectory(base.path);
      final resolved = await AppPaths.resolveBaseDirectory();
      expect(resolved, base.path);
    });
  });

  group('AppPaths.resolveScratchDirectory', () {
    test('返回可写目录，且位于系统临时位置（只放一次性中转文件）', () async {
      final path = await AppPaths.resolveScratchDirectory();
      final directory = Directory(path);
      expect(directory.existsSync(), isTrue);
      expect(AppPaths.isEphemeralDirectory(path), isTrue);
      final probe = File('$path/probe.txt')..writeAsStringSync('ok');
      expect(probe.readAsStringSync(), 'ok');
      probe.deleteSync();
    });
  });
}
