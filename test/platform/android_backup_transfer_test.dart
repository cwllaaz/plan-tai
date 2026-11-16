import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:jihuatai/platform/platform.dart';
import 'package:path/path.dart' as p;

import 'support/platform_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TempBase base;
  late Directory scratch;
  late SqlitePlannerRepository repository;
  late MockChannel storageMock;
  late AndroidBackupTransfer transfer;

  setUp(() {
    base = TempBase.create();
    scratch = Directory(p.join(base.path, 'scratch'))
      ..createSync(recursive: true);
    PlannerPaths.useBaseDirectory(base.path);
    repository = SqlitePlannerRepository.open(databasePath: base.databasePath);
    storageMock = MockChannel(AndroidStorageChannel.channelName)..install();
    transfer = AndroidBackupTransfer(
      repository: repository,
      storage: AndroidStorageChannel(
        channel: const MethodChannel(AndroidStorageChannel.channelName),
      ),
      appVersion: '1.0.0-test',
      backupDirectory: base.backupDirectory,
      scratchDirectory: () async => scratch.path,
    );
  });

  tearDown(() async {
    await repository.close();
    PlannerPaths.useBaseDirectory(null);
    storageMock.uninstall();
    base.delete();
  });

  Future<Project> seedData() async {
    final project = await repository.createProject(
      const ProjectDraft(name: '项目A'),
    );
    await repository.createTask(
      PlannerTaskDraft(
        title: '任务A',
        projectId: project.id,
        scheduledDate: d('2026-11-15'),
      ),
    );
    await repository.saveDailyNote(
      d('2026-11-15'),
      body: '今日备注',
      focusItems: const <String>['重点一'],
    );
    return project;
  }

  Future<String> writeBackupFile(String name) async {
    final path = p.join(base.path, name);
    await BackupService(
      repository,
      backupDirectory: base.backupDirectory,
    ).exportJson(targetPath: path);
    return path;
  }

  List<File> scratchFiles() =>
      scratch.listSync().whereType<File>().toList(growable: false);

  group('导出到系统文件选择器', () {
    test('导出内容与 Windows 备份格式完全一致，并清理缓存中转文件', () async {
      await seedData();
      late Uint8List bytes;
      storageMock.handler = (MethodCall call) async {
        if (call.method != 'createDocument') return null;
        final arguments = call.arguments as Map<Object?, Object?>;
        bytes = arguments['bytes']! as Uint8List;
        return <Object?, Object?>{
          'uri': 'content://downloads/document/1',
          'name': arguments['fileName'],
          'bytes': bytes.length,
        };
      };

      final outcome = await transfer.exportJsonToUser();

      expect(outcome.isExported, isTrue);
      expect(outcome.fileName, startsWith('jihuatai-backup-'));
      expect(outcome.fileName, endsWith('.json'));
      expect(outcome.bytes, bytes.length);
      expect(scratchFiles(), isEmpty, reason: '导出完成后不能把中转 JSON 留在缓存里');

      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect(json['format'], kBackupFormat);
      expect(json['formatVersion'], kBackupFormatVersion);
      expect(json['schemaVersion'], PlannerDatabase.schemaVersion);
      expect(json['appVersion'], '1.0.0-test');
      expect(json.keys.toSet(), <String>{
        'format',
        'formatVersion',
        'schemaVersion',
        'appVersion',
        'exportedAt',
        'projects',
        'planSpans',
        'plannerTasks',
        'dailyNotes',
      });
      expect((json['projects']! as List<Object?>).length, 1);
      expect((json['plannerTasks']! as List<Object?>).length, 1);
      expect((json['dailyNotes']! as List<Object?>).length, 1);
    });

    test('用户取消保存：返回取消结果，不留下任何文件', () async {
      await seedData();
      storageMock.handler = (MethodCall call) async => null;

      final outcome = await transfer.exportJsonToUser();

      expect(outcome.isExported, isFalse);
      expect(outcome.bytes, 0);
      expect(scratchFiles(), isEmpty);
    });

    test('数据库快照导出是合法 SQLite 文件（排障用）', () async {
      await seedData();
      late Uint8List bytes;
      storageMock.handler = (MethodCall call) async {
        if (call.method != 'createDocument') return null;
        final arguments = call.arguments as Map<Object?, Object?>;
        bytes = arguments['bytes']! as Uint8List;
        return <Object?, Object?>{
          'uri': 'content://downloads/document/2',
          'name': arguments['fileName'],
          'bytes': bytes.length,
        };
      };

      final outcome = await transfer.exportDatabaseSnapshotToUser();

      expect(outcome.isExported, isTrue);
      expect(outcome.fileName, endsWith('.db'));
      expect(String.fromCharCodes(bytes.take(15)), 'SQLite format 3');
      expect(scratchFiles(), isEmpty);
    });
  });

  group('导入校验与恢复', () {
    test('校验通过的备份给出预览摘要，并保留临时副本待恢复', () async {
      await seedData();
      final backupPath = await writeBackupFile('valid-backup.json');
      storageMock.handler = (MethodCall call) async => <Object?, Object?>{
        'path': backupPath,
        'name': 'valid-backup.json',
        'bytes': File(backupPath).lengthSync(),
      };

      final imported = await transfer.pickAndInspectBackup();

      expect(imported.hasPreview, isTrue);
      expect(imported.temporaryPath, backupPath);
      expect(imported.displayName, 'valid-backup.json');
      expect(imported.preview!.summary, contains('1 个项目'));
      expect(imported.preview!.summary, contains('1 个任务'));
      expect(File(backupPath).existsSync(), isTrue);
    });

    test('用户取消选择：返回空结果', () async {
      storageMock.handler = (MethodCall call) async => null;

      final imported = await transfer.pickAndInspectBackup();

      expect(imported.hasPreview, isFalse);
      expect(imported.temporaryPath, isNull);
    });

    test('非法备份被拒绝，并清掉缓存副本', () async {
      final broken = File(p.join(base.path, 'broken.json'))
        ..writeAsStringSync('{"format":"something-else","schemaVersion":1}');
      storageMock.handler = (MethodCall call) async => <Object?, Object?>{
        'path': broken.path,
        'name': 'broken.json',
        'bytes': broken.lengthSync(),
      };

      await expectLater(
        transfer.pickAndInspectBackup(),
        throwsA(isA<BackupException>()),
      );
      expect(broken.existsSync(), isFalse);
    });

    test('恢复必须先确认；用户取消时数据完全不变', () async {
      await seedData();
      final backupPath = await writeBackupFile('cancelled-backup.json');
      storageMock.handler = (MethodCall call) async => <Object?, Object?>{
        'path': backupPath,
        'name': 'cancelled-backup.json',
        'bytes': File(backupPath).lengthSync(),
      };
      final imported = await transfer.pickAndInspectBackup();
      final before = await repository.watchAllTasks().first;

      BackupPreview? confirmedPreview;
      final outcome = await transfer.restore(
        preview: imported.preview!,
        temporaryPath: imported.temporaryPath,
        confirmOverwrite: (BackupPreview preview) async {
          confirmedPreview = preview;
          return false;
        },
      );

      expect(confirmedPreview, same(imported.preview));
      expect(outcome.isRestored, isFalse);
      expect(File(backupPath).existsSync(), isFalse, reason: '取消后也要清理临时副本');
      expect((await repository.watchAllTasks().first).length, before.length);
    });

    test('确认后整体覆盖本地数据，并留下恢复前快照', () async {
      await seedData();
      final backupPath = await writeBackupFile('restore-backup.json');

      // 导出之后再改数据：恢复应把它整体覆盖回备份时的状态。
      await repository.createProject(const ProjectDraft(name: '备份后新增的项目'));
      await repository.createTask(
        PlannerTaskDraft(title: '备份后新增的任务', scheduledDate: d('2026-11-16')),
      );
      expect(
        (await repository.watchProjects(includeArchived: true).first).length,
        2,
      );

      storageMock.handler = (MethodCall call) async => <Object?, Object?>{
        'path': backupPath,
        'name': 'restore-backup.json',
        'bytes': File(backupPath).lengthSync(),
      };
      final imported = await transfer.pickAndInspectBackup();

      var confirmCalls = 0;
      final outcome = await transfer.restore(
        preview: imported.preview!,
        temporaryPath: imported.temporaryPath,
        confirmOverwrite: (BackupPreview preview) async {
          confirmCalls++;
          return true;
        },
      );

      expect(confirmCalls, 1);
      expect(outcome.isRestored, isTrue);
      final result = outcome.result!;
      expect(result.projects, 1);
      expect(result.tasks, 1);
      expect(result.notes, 1);
      expect(File(result.safetyCopyPath).existsSync(), isTrue);

      expect(
        (await repository.watchProjects(includeArchived: true).first)
            .map((project) => project.name),
        <String>['项目A'],
      );
      expect(
        (await repository.watchAllTasks().first).map((task) => task.title),
        <String>['任务A'],
      );
    });

    test('恢复后仓库流会刷新（界面自动看到新数据）', () async {
      await seedData();
      final backupPath = await writeBackupFile('refresh-backup.json');
      storageMock.handler = (MethodCall call) async => <Object?, Object?>{
        'path': backupPath,
        'name': 'refresh-backup.json',
        'bytes': File(backupPath).lengthSync(),
      };
      final imported = await transfer.pickAndInspectBackup();

      final before = await repository.watchAllTasks().first;
      expect(before.length, 1);
      await repository.deleteTask(before.single.id);
      expect(await repository.watchAllTasks().first, isEmpty);

      await transfer.restore(
        preview: imported.preview!,
        temporaryPath: imported.temporaryPath,
        confirmOverwrite: (BackupPreview preview) async => true,
      );

      // 每个 watch* 调用返回独立流，重新订阅才拿得到恢复后的数据。
      expect(
        (await repository.watchAllTasks().first).map((task) => task.title),
        <String>['任务A'],
      );
    });
  });

  group('应用私有备份列表与缓存清理', () {
    test('列出 <base>/data/backups 里的 JSON 备份，最新在前', () async {
      PlannerPaths.ensureDirectory(base.backupDirectory);
      final older = File(p.join(base.backupDirectory, 'older.json'))
        ..writeAsStringSync('{"a":1}');
      final newer = File(p.join(base.backupDirectory, 'newer.json'))
        ..writeAsStringSync('{"b":2}');
      older.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      newer.setLastModifiedSync(DateTime.now());

      final backups = await transfer.listLocalBackups();

      expect(backups.map((file) => file.name), <String>[
        'newer.json',
        'older.json',
      ]);
      expect(backups.first.sizeLabel, endsWith('KB'));
      expect(backups.first.path, newer.path);
    });

    test('cleanupScratch 只删除过期的缓存中转文件', () async {
      final old = File(p.join(scratch.path, 'old.json'))
        ..writeAsStringSync('{}');
      final fresh = File(p.join(scratch.path, 'fresh.json'))
        ..writeAsStringSync('{}');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));

      await transfer.cleanupScratch();

      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });
  });
}
