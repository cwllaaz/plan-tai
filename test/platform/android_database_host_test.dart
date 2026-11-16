import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:jihuatai/platform/platform.dart';
import 'package:path/path.dart' as p;

import 'support/platform_test_support.dart';

void main() {
  late TempBase base;

  setUp(() {
    base = TempBase.create();
  });

  tearDown(() async {
    await AndroidDatabaseHost.resetForTesting();
    PlannerPaths.useBaseDirectory(null);
    base.delete();
  });

  Future<AndroidDatabaseHost> openHost({String? path}) =>
      AndroidDatabaseHost.open(
        baseDirectory: path ?? base.path,
        // 测试基目录在系统 Temp 下；守卫本身由单独用例显式验证。
        enforcePrivateDirectoryGuard: false,
      );

  group('AndroidDatabaseHost 初始化', () {
    test('首次启动在 <base>/data/app.db 建库，并落在应用私有目录', () async {
      final host = await openHost();

      expect(host.databasePath, base.databasePath);
      expect(host.dataDirectory, base.dataDirectory);
      expect(host.createdDatabase, isTrue);
      expect(File(host.databasePath).existsSync(), isTrue);
      expect(File(host.databasePath).lengthSync(), greaterThan(0));
      expect(host.isOpen, isTrue);
      expect(host.verifyAlive(), isTrue);
      expect(host.repository, isA<SqlitePlannerRepository>());

      // 没有演示数据：新库必须为空，不能悄悄塞 demo。
      expect(await host.repository.watchProjects().first, isEmpty);
      expect(await host.repository.watchAllTasks().first, isEmpty);
    });

    test('同进程重复调用返回同一实例（页面重建不重复建连/建库）', () async {
      final first = await openHost();
      final second = await openHost();

      expect(identical(first, second), isTrue);
      expect(AndroidDatabaseHost.current, same(first));
      expect(second.createdDatabase, isTrue);
    });

    test('关闭后重新打开：不重建库、数据完整', () async {
      final first = await openHost();
      await first.repository.createProject(const ProjectDraft(name: '重启后仍在的项目'));
      await first.repository.createTask(
        PlannerTaskDraft(title: '重启后仍在的任务', scheduledDate: d('2026-11-15')),
      );
      await AndroidDatabaseHost.resetForTesting();

      final second = await openHost();
      expect(second.createdDatabase, isFalse);
      final projects = await second.repository.watchProjects().first;
      final tasks = await second.repository.tasksInRange(
        LocalDateRange(d('2026-11-01'), d('2026-11-30')),
      );
      expect(projects.map((project) => project.name), <String>['重启后仍在的项目']);
      expect(tasks.map((task) => task.title), <String>['重启后仍在的任务']);
    });

    test('拒绝把数据库放进缓存/临时目录', () async {
      final cacheDirectory = Directory(p.join(base.path, 'cache', 'jihuatai'))
        ..createSync(recursive: true);

      await expectLater(
        AndroidDatabaseHost.open(
          baseDirectory: cacheDirectory.path,
          enforcePrivateDirectoryGuard: true,
        ),
        throwsA(isA<LocalDatabaseException>()),
      );
      // 失败时不能留下任何数据库文件。
      expect(
        Directory(cacheDirectory.path)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.db')),
        isEmpty,
      );
    });

    test('数据库损坏时报错停下，不删除/重建用户数据', () async {
      Directory(base.dataDirectory).createSync(recursive: true);
      final corrupt = File(base.databasePath)
        ..writeAsBytesSync(List<int>.filled(4096, 7));

      await expectLater(
        openHost(),
        throwsA(isA<LocalDatabaseException>()),
      );

      expect(corrupt.existsSync(), isTrue);
      expect(corrupt.lengthSync(), 4096);
      expect(corrupt.readAsBytesSync().first, 7);
      expect(AndroidDatabaseHost.current, isNull);
    });

    test('空基目录直接失败', () async {
      await expectLater(
        AndroidDatabaseHost.open(baseDirectory: '   '),
        throwsA(isA<LocalDatabaseException>()),
      );
    });

    test('已有连接时不允许静默切换到另一个库', () async {
      final host = await openHost();
      final other = TempBase.create();
      addTearDown(other.delete);

      await expectLater(
        AndroidDatabaseHost.open(
          baseDirectory: other.path,
          enforcePrivateDirectoryGuard: false,
        ),
        throwsA(isA<LocalDatabaseException>()),
      );
      expect(host.isOpen, isTrue);
    });
  });

  group('AndroidDatabaseHost 账号工作区', () {
    test('按 cloud_workspace.json 指针打开账号库', () async {
      Directory(base.dataDirectory).createSync(recursive: true);
      final accountDirectory = Directory(
        p.join(base.dataDirectory, 'accounts', 'owner1'),
      )..createSync(recursive: true);
      final accountRepository = SqlitePlannerRepository.open(
        databasePath: p.join(accountDirectory.path, 'app.db'),
      );
      await accountRepository.createProject(const ProjectDraft(name: '云端工作区项目'));
      await accountRepository.close();

      File(p.join(base.dataDirectory, 'cloud_workspace.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'ownerId': 'owner1',
          'databasePath': p.join('accounts', 'owner1', 'app.db'),
        }),
      );

      final host = await openHost();
      expect(host.databasePath, p.join(accountDirectory.path, 'app.db'));
      final projects = await host.repository.watchProjects().first;
      expect(projects.single.name, '云端工作区项目');
    });
  });

  group('AndroidDatabaseHost 数据安全', () {
    test('模拟进程被杀：已提交事务在未 checkpoint 的 WAL 副本里可恢复', () async {
      final host = await openHost();
      await host.repository.createTask(
        PlannerTaskDraft(title: '进程被杀前提交的任务', scheduledDate: d('2026-11-15')),
      );

      // 进程被系统直接杀掉时不会走 close()：这里直接拷走「主库 + WAL」。
      final crashedBase = TempBase.create();
      final crashedData = Directory(crashedBase.dataDirectory)
        ..createSync(recursive: true);
      final sourceData = Directory(base.dataDirectory);
      for (final entity in sourceData.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name == 'app.db' || name == 'app.db-wal') {
          entity.copySync(p.join(crashedData.path, name));
        }
      }
      expect(File(p.join(crashedData.path, 'app.db')).existsSync(), isTrue);

      // 只有关掉当前宿主才能切换基目录（模拟"新进程"）。
      await AndroidDatabaseHost.resetForTesting();
      PlannerPaths.useBaseDirectory(null);

      final recovered = await AndroidDatabaseHost.open(
        baseDirectory: crashedBase.path,
        enforcePrivateDirectoryGuard: false,
      );
      try {
        final tasks = await recovered.repository.tasksInRange(
          LocalDateRange(d('2026-11-01'), d('2026-11-30')),
        );
        expect(tasks.map((task) => task.title), <String>['进程被杀前提交的任务']);
        expect(recovered.createdDatabase, isFalse);
      } finally {
        // Windows 上必须先关句柄再删目录，否则文件被占用。
        await recovered.close();
        crashedBase.delete();
      }
    });

    test('checkpoint / 释放内存 / 健康检查在连接存活时可用，关闭后安全返回 false', () async {
      final host = await openHost();
      expect(host.checkpoint(), isTrue);
      expect(host.releaseMemory(), isTrue);
      expect(host.verifyAlive(), isTrue);

      await host.close();
      expect(host.isOpen, isFalse);
      expect(host.checkpoint(), isFalse);
      expect(host.releaseMemory(), isFalse);
      expect(host.verifyAlive(), isFalse);
      expect(AndroidDatabaseHost.current, isNull);
    });

    test('月范围查询在 120 条任务下保持毫秒级（回归护栏，真机性能另需实测）', () async {
      final host = await openHost();
      for (var index = 0; index < 120; index++) {
        await host.repository.createTask(
          PlannerTaskDraft(
            title: '任务 $index',
            scheduledDate: d('2026-11-${(index % 28 + 1).toString().padLeft(2, '0')}'),
          ),
        );
      }

      final stopwatch = Stopwatch()..start();
      final tasks = await host.repository.tasksInRange(
        LocalDateRange(d('2026-11-01'), d('2026-11-30')),
      );
      stopwatch.stop();

      expect(tasks.length, 120);
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: '月历一次查整月的查询耗时必须远低于一帧预算（16ms 量级），'
            '否则移动端会出现掉帧；实测 ${stopwatch.elapsedMilliseconds}ms',
      );
    });
  });
}
