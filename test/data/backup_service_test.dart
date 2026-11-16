import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/test_env.dart';

/// 造一份覆盖各种情况的数据：项目、跨天阶段、任务（含一条已软删除）、每日备注。
Future<Map<String, String>> seedDataset(TestEnv env) async {
  final project = await env.repository.createProject(
    const ProjectDraft(
      name: '备份项目',
      description: '描述',
      color: ProjectColor.teal,
    ),
  );
  final span = await env.repository.createSpan(
    PlanSpanDraft(
      projectId: project.id,
      title: '阶段',
      startDate: d('2026-11-03'),
      endDate: d('2026-11-07'),
      status: PlanSpanStatus.doing,
    ),
  );
  final kept = await env.repository.createTask(
    PlannerTaskDraft(
      title: '保留任务',
      projectId: project.id,
      spanId: span.id,
      scheduledDate: d('2026-11-04'),
      timeSlot: TimeSlot.at(hour: 10),
      priority: TaskPriority.high,
    ),
  );
  final removed = await env.repository.createTask(
    PlannerTaskDraft(
      title: '已删任务',
      projectId: project.id,
      scheduledDate: d('2026-11-05'),
    ),
  );
  await env.repository.deleteTask(removed.id);
  await env.repository.saveDailyNote(
    d('2026-11-04'),
    body: '当天备注',
    focusItems: <String>['重点'],
  );
  return <String, String>{
    'project': project.id,
    'span': span.id,
    'task': kept.id,
    'deletedTask': removed.id,
  };
}

void main() {
  group('导出', () {
    test('导出 JSON 备份：格式标识、版本、四张表数据齐全', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(env);
        final backup = BackupService(
          env.repository,
          appVersion: '1.0.0',
          clock: clock.now,
          backupDirectory: env.pathInDirectory('backups'),
        );

        final path = await backup.exportJson();

        expect(File(path).existsSync(), isTrue);
        expect(path, contains(env.pathInDirectory('backups')));

        final text = File(path).readAsStringSync();
        expect(text, contains('\n  "'), reason: '缩进输出，便于人工检查');

        final json = jsonDecode(text) as Map<String, Object?>;
        expect(json['format'], kBackupFormat);
        expect(json['formatVersion'], kBackupFormatVersion);
        expect(json['schemaVersion'], PlannerDatabase.schemaVersion);
        expect(json['appVersion'], '1.0.0');
        expect(json['exportedAt'], endsWith('Z'));
        expect(json['projects']! as List<Object?>, hasLength(1));
        expect(json['planSpans']! as List<Object?>, hasLength(1));
        expect(
          json['plannerTasks']! as List<Object?>,
          hasLength(2),
          reason: '软删除的记录也要导出，恢复时才不会"复活"',
        );
        expect(json['dailyNotes']! as List<Object?>, hasLength(1));
      } finally {
        await env.dispose();
      }
    });

    test('inspect 能读出摘要与数量，不修改数据库', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(env);
        final backup = BackupService(
          env.repository,
          clock: clock.now,
          backupDirectory: env.pathInDirectory('backups'),
        );
        final path = await backup.exportJson();

        final preview = await backup.inspect(path);

        expect(preview.content.liveProjectCount, 1);
        expect(preview.content.liveTaskCount, 1);
        expect(preview.content.liveNoteCount, 1);
        expect(preview.content.deletedRecordCount, 1);
        expect(preview.bytes, greaterThan(0));
        expect(preview.summary, contains('1 个任务'));
        expect(preview.summary, contains('已删除记录'));
      } finally {
        await env.dispose();
      }
    });

    test('snapshotDatabase 导出的一致性副本可独立打开且行数一致', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(env);
        final backup = BackupService(
          env.repository,
          clock: clock.now,
          backupDirectory: env.pathInDirectory('backups'),
        );

        final path = backup.snapshotDatabase(
          directory: env.pathInDirectory('snapshots'),
        );

        expect(File(path).existsSync(), isTrue);
        final probe = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          expect(probe.select('PRAGMA quick_check').first['quick_check'], 'ok');
          expect(
            probe.select('SELECT COUNT(*) AS c FROM planner_tasks').first['c'],
            2,
          );
          expect(
            probe.select('SELECT COUNT(*) AS c FROM projects').first['c'],
            1,
          );
        } finally {
          probe.close();
        }
      } finally {
        await env.dispose();
      }
    });
  });

  group('校验', () {
    test('文件不存在 / 不是 JSON / 版本过高 / 引用不完整都有明确错误', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(env);
        final backup = BackupService(
          env.repository,
          clock: clock.now,
          backupDirectory: env.pathInDirectory('backups'),
        );

        await expectLater(
          backup.inspect(env.pathInDirectory('nope.json')),
          throwsA(
            isA<BackupException>().having(
              (error) => error.kind,
              'kind',
              BackupErrorKind.fileNotFound,
            ),
          ),
        );

        final notJson = env.pathInDirectory('bad.json');
        File(notJson).writeAsStringSync('这不是 JSON');
        await expectLater(
          backup.inspect(notJson),
          throwsA(
            isA<BackupException>().having(
              (error) => error.kind,
              'kind',
              BackupErrorKind.invalidFormat,
            ),
          ),
        );

        final newer = env.pathInDirectory('newer.json');
        File(newer).writeAsStringSync(
          jsonEncode(<String, Object?>{
            'format': kBackupFormat,
            'formatVersion': 1,
            'schemaVersion': 99,
            'appVersion': '9.0.0',
            'exportedAt': '2026-11-14T00:00:00.000000Z',
            'projects': <Object?>[],
            'planSpans': <Object?>[],
            'plannerTasks': <Object?>[],
            'dailyNotes': <Object?>[],
          }),
        );
        await expectLater(
          backup.inspect(newer),
          throwsA(
            isA<BackupException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  BackupErrorKind.newerSchema,
                )
                .having((error) => error.message, 'message', contains('升级')),
          ),
        );

        final exported = await backup.exportJson();
        final json = jsonDecode(
          File(exported).readAsStringSync(),
        ) as Map<String, Object?>;
        final tasks = (json['plannerTasks']! as List<Object?>)
            .cast<Map<String, Object?>>();
        tasks.first['projectId'] = 'ghost-project';
        final broken = env.pathInDirectory('broken.json');
        File(broken).writeAsStringSync(jsonEncode(json));

        await expectLater(
          backup.inspect(broken),
          throwsA(
            isA<BackupException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  BackupErrorKind.invalidFormat,
                )
                .having((error) => error.message, 'message', contains('不存在')),
          ),
        );
      } finally {
        await env.dispose();
      }
    });
  });

  group('恢复', () {
    test('本地已有数据时未确认恢复会被拒绝，数据原样保留', () async {
      final clock = FakeClock();
      final source = TestEnv.create(clock: clock.now);
      final target = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(source);
        final exporter = BackupService(
          source.repository,
          clock: clock.now,
          backupDirectory: source.pathInDirectory('backups'),
        );
        final path = await exporter.exportJson();

        await target.repository.createProject(
          const ProjectDraft(name: '目标库已有项目'),
        );

        final importer = BackupService(
          target.repository,
          clock: clock.now,
          backupDirectory: target.pathInDirectory('backups'),
        );
        final preview = await importer.inspect(path);

        await expectLater(
          importer.restore(preview),
          throwsA(
            isA<BackupException>().having(
              (error) => error.kind,
              'kind',
              BackupErrorKind.overwriteRefused,
            ),
          ),
        );

        final projects = await target.repository.watchProjects().first;
        expect(projects.map((project) => project.name).toList(), <String>[
          '目标库已有项目',
        ]);
      } finally {
        await source.dispose();
        await target.dispose();
      }
    });

    test('恢复到空库后四类数据完全一致，id / revision / 墓碑都保留', () async {
      final clock = FakeClock();
      final source = TestEnv.create(clock: clock.now);
      final target = TestEnv.create(clock: clock.now);
      try {
        final ids = await seedDataset(source);
        final exporter = BackupService(
          source.repository,
          clock: clock.now,
          backupDirectory: source.pathInDirectory('backups'),
        );
        final path = await exporter.exportJson();
        final importer = BackupService(
          target.repository,
          clock: clock.now,
          backupDirectory: target.pathInDirectory('backups'),
        );

        final preview = await importer.inspect(path);
        final result = await importer.restore(preview);

        expect(result.projects, 1);
        expect(result.spans, 1);
        expect(result.tasks, 2);
        expect(result.notes, 1);
        expect(File(result.safetyCopyPath).existsSync(), isTrue);

        final range = LocalDateRange(d('2026-11-01'), d('2026-11-30'));
        expect(
          await target.repository.tasksInRange(range),
          await source.repository.tasksInRange(range),
        );
        expect(
          await target.repository.watchProjects().first,
          await source.repository.watchProjects().first,
        );
        expect(
          await target.repository.watchSpansInRange(range).first,
          await source.repository.watchSpansInRange(range).first,
        );
        expect(
          await target.repository.findDailyNote(d('2026-11-04')),
          await source.repository.findDailyNote(d('2026-11-04')),
        );

        expect(await target.repository.findTask(ids['task']!), isNotNull);
        expect(await target.repository.findTask(ids['deletedTask']!), isNull);

        final tombstone = target.database.handle.select(
          'SELECT deleted_at, revision FROM planner_tasks WHERE id = ?',
          <Object?>[ids['deletedTask']],
        ).single;
        expect(tombstone['deleted_at'], isNotNull, reason: '软删除记录必须原样恢复');
        expect(tombstone['revision'], 2);
      } finally {
        await source.dispose();
        await target.dispose();
      }
    });

    test('恢复前自动快照旧数据，快照能独立打开并查到旧内容', () async {
      final clock = FakeClock();
      final source = TestEnv.create(clock: clock.now);
      final target = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(source);
        final exporter = BackupService(
          source.repository,
          clock: clock.now,
          backupDirectory: source.pathInDirectory('backups'),
        );
        final path = await exporter.exportJson();
        await target.repository.createProject(
          const ProjectDraft(name: '目标库旧项目'),
        );

        final importer = BackupService(
          target.repository,
          clock: clock.now,
          backupDirectory: target.pathInDirectory('backups'),
        );
        final preview = await importer.inspect(path);
        final result = await importer.restore(preview, confirmOverwrite: true);

        expect(File(result.safetyCopyPath).existsSync(), isTrue);
        final probe = sqlite3.open(
          result.safetyCopyPath,
          mode: OpenMode.readOnly,
        );
        try {
          final names = probe
              .select('SELECT name FROM projects')
              .map((row) => row['name'])
              .toList();
          expect(names, <String>['目标库旧项目'], reason: '快照必须是恢复前的数据');
        } finally {
          probe.close();
        }

        expect(
          (await target.repository.watchProjects().first).single.name,
          '备份项目',
        );
      } finally {
        await source.dispose();
        await target.dispose();
      }
    });

    test('恢复中途失败整体回滚，现有数据不受影响', () async {
      final clock = FakeClock();
      final target = TestEnv.create(clock: clock.now);
      try {
        final existing = await target.repository.createProject(
          const ProjectDraft(name: '保留的项目'),
        );
        final importer = BackupService(
          target.repository,
          clock: clock.now,
          backupDirectory: target.pathInDirectory('backups'),
        );

        // 故意构造重复主键：第一条能插入，第二条触发约束失败。
        final content = BackupContent(
          schemaVersion: PlannerDatabase.schemaVersion,
          appVersion: '1.0.0',
          exportedAt: clock.value,
          projects: <Project>[
            existing,
            existing.copyWith(name: '重复 ID 的项目'),
          ],
          spans: const <PlanSpan>[],
          tasks: const <PlannerTask>[],
          notes: const <DailyNote>[],
        );
        final preview = BackupPreview(
          path: 'inline',
          content: content,
          bytes: 0,
          formatVersion: kBackupFormatVersion,
        );

        await expectLater(
          importer.restore(preview, confirmOverwrite: true),
          throwsA(isA<BackupException>()),
        );

        final projects = await target.repository.watchProjects().first;
        expect(projects.map((project) => project.name).toList(), <String>[
          '保留的项目',
        ]);
        expect(existing.id, projects.single.id);
      } finally {
        await target.dispose();
      }
    });

    test('备份在重启后依然可以恢复', () async {
      final clock = FakeClock();
      final backupDir = Directory.systemTemp.createTempSync('jihuatai_backup_');
      final source = TestEnv.create(clock: clock.now);
      late final String path;
      late final List<PlannerTask> expectedTasks;
      try {
        await seedDataset(source);
        final exporter = BackupService(
          source.repository,
          clock: clock.now,
          backupDirectory: backupDir.path,
        );
        path = await exporter.exportJson();
        expectedTasks = await source.repository.watchAllTasks().first;
      } finally {
        await source.dispose();
      }

      final target = TestEnv.create(clock: clock.now);
      try {
        final importer = BackupService(
          target.repository,
          clock: clock.now,
          backupDirectory: backupDir.path,
        );
        final preview = await importer.inspect(path);
        await importer.restore(preview);

        expect(await target.repository.watchAllTasks().first, expectedTasks);
      } finally {
        await target.dispose();
        backupDir.deleteSync(recursive: true);
      }
    });

    test('恢复完成后界面订阅的流会刷新', () async {
      final clock = FakeClock();
      final source = TestEnv.create(clock: clock.now);
      final target = TestEnv.create(clock: clock.now);
      try {
        await seedDataset(source);
        final exporter = BackupService(
          source.repository,
          clock: clock.now,
          backupDirectory: source.pathInDirectory('backups'),
        );
        final path = await exporter.exportJson();
        final importer = BackupService(
          target.repository,
          clock: clock.now,
          backupDirectory: target.pathInDirectory('backups'),
        );
        final preview = await importer.inspect(path);

        final refreshed = target.repository.watchAllTasks().firstWhere(
          (tasks) => tasks.isNotEmpty,
        );
        await importer.restore(preview);

        expect(await refreshed, hasLength(1));
      } finally {
        await source.dispose();
        await target.dispose();
      }
    });
  });
}
