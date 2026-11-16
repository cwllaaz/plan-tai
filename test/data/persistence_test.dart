import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'support/test_env.dart';

void main() {
  group('重启持久化', () {
    test('关闭连接后重新打开：四类实体全字段一致（含微秒级时间戳）', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);

      final project = await env.repository.createProject(
        const ProjectDraft(name: '长期项目', description: '说明文字'),
      );
      final span = await env.repository.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '跨月阶段',
          startDate: d('2026-10-28'),
          endDate: d('2026-11-03'),
          status: PlanSpanStatus.doing,
          color: ProjectColor.purple,
        ),
      );
      final task = await env.repository.createTask(
        PlannerTaskDraft(
          title: '带时刻任务',
          projectId: project.id,
          spanId: span.id,
          notes: '任务备注',
          scheduledDate: d('2026-11-01'),
          timeSlot: TimeSlot.at(hour: 14, minute: 30, durationMinutes: 45),
          priority: TaskPriority.high,
          sortOrder: 4,
        ),
      );
      final note = await env.repository.saveDailyNote(
        d('2026-11-01'),
        body: '当天备注',
        focusItems: <String>['重点一', '重点二'],
      );

      await env.repository.close();

      final reopened = TestEnv.openIn(env.directory, clock: clock.now);
      try {
        expect(await reopened.repository.findProject(project.id), project);
        expect(await reopened.repository.findSpan(span.id), span);
        expect(await reopened.repository.findTask(task.id), task);
        expect(await reopened.repository.findDailyNote(note.date), note);
        expect(
          (await reopened.repository.findTask(task.id))!.createdAt.microsecond,
          task.createdAt.microsecond,
          reason: '时间戳必须毫秒外还能还原微秒',
        );
      } finally {
        await reopened.dispose();
      }
    });

    test('备注重复保存在重启后仍然只有一条（upsert 语义跨进程成立）', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      final first = await env.repository.saveDailyNote(
        d('2026-11-14'),
        body: '第一次',
      );
      await env.repository.close();

      final reopened = TestEnv.openIn(env.directory, clock: clock.now);
      try {
        clock.advance(const Duration(minutes: 5));
        final second = await reopened.repository.saveDailyNote(
          d('2026-11-14'),
          body: '第二次',
        );
        expect(second.id, first.id);
        expect(second.revision, 2);
        expect(
          reopened.database.handle
              .select('SELECT COUNT(*) AS c FROM daily_notes')
              .first['c'],
          1,
        );
      } finally {
        await reopened.dispose();
      }
    });

    test('关闭后 WAL 已 checkpoint，没有残留的大日志文件', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      await env.repository.createTask(
        PlannerTaskDraft(title: '任务', scheduledDate: d('2026-11-16')),
      );
      await env.repository.close();

      final wal = File('${env.databasePath}-wal');
      final hasLeftover = wal.existsSync() && wal.lengthSync() > 0;
      expect(hasLeftover, isFalse, reason: '正常退出应清理 WAL，异常退出才需要靠 WAL 恢复');

      await env.dispose();
    });

    test('重新打开后外键约束与索引仍然生效', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      await env.repository.createProject(const ProjectDraft(name: '项目'));
      await env.repository.close();

      final reopened = TestEnv.openIn(env.directory, clock: clock.now);
      try {
        expect(
          () => reopened.database.handle.execute(
            'INSERT INTO planner_tasks (id, created_at, updated_at, revision, '
            'project_id, title) VALUES (?, ?, ?, ?, ?, ?)',
            <Object?>[
              'x',
              '2026-01-01T00:00:00.000000Z',
              '2026-01-01T00:00:00.000000Z',
              1,
              'no-project',
              '悬空任务',
            ],
          ),
          throwsA(isA<SqliteException>()),
        );

        final plan = reopened.database.handle.select(
          'EXPLAIN QUERY PLAN SELECT id FROM planner_tasks '
          'WHERE deleted_at IS NULL AND scheduled_date BETWEEN ? AND ?',
          <Object?>['2026-11-01', '2026-11-30'],
        );
        final detail = plan.map((row) => row['detail']).join(' | ');
        expect(
          detail,
          contains('idx_tasks_scheduled'),
          reason: '月历范围查询必须走 scheduled_date 索引',
        );
      } finally {
        await reopened.dispose();
      }
    });
  });

  group('存储位置规则', () {
    test('默认数据库在用户应用数据目录，不在工作目录或临时目录', () {
      final path = PlannerPaths.defaultDatabasePath();

      expect(path, endsWith(p.join('计划台', 'data', 'app.db')));
      expect(path, isNot(startsWith(Directory.current.path)));
      expect(path, isNot(startsWith(Directory.systemTemp.path)));

      if (Platform.isWindows) {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          expect(path, startsWith(appData));
        }
      }
    });

    test('备份目录与数据库同级', () {
      final backupDirectory = PlannerPaths.defaultBackupDirectory();
      expect(backupDirectory, endsWith(p.join('计划台', 'data', 'backups')));
    });

    test('JIHUATAI_DATA_DIR 可覆盖基目录（便携模式）', () {
      final path = PlannerPaths.defaultDatabasePath(
        environment: <String, String>{'JIHUATAI_DATA_DIR': r'D:\PortableJihua'},
      );
      expect(path, p.join(r'D:\PortableJihua', 'data', 'app.db'));
    });

    test('测试库文件确实落在临时目录里', () {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      try {
        expect(File(env.databasePath).existsSync(), isTrue);
        expect(env.databasePath, startsWith(Directory.systemTemp.path));
      } finally {
        env.dispose();
      }
    });
  });

  group('容量与故障', () {
    test('2000 条任务写入后按月查询正确且足够快', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      final repo = env.repository;
      try {
        final project = await repo.createProject(
          const ProjectDraft(name: '大项目'),
        );

        final writeStarted = DateTime.now();
        env.database.transaction(() {
          for (var index = 0; index < 2000; index++) {
            final task = PlannerTask(
              id: Ids.newId(),
              createdAt: clock.value,
              updatedAt: clock.value,
              revision: 1,
              projectId: project.id,
              title: '批量任务 $index',
              scheduledDate: LocalDate(
                2026,
                1 + (index % 12),
                1 + (index % 28),
              ),
              timeSlot: index.isEven ? TimeSlot.at(hour: 9) : null,
            );
            env.database.handle.execute(insertTaskSql, taskInsertParams(task));
          }
        });
        expect(DateTime.now().difference(writeStarted).inSeconds, lessThan(30));

        final queryStarted = DateTime.now();
        final november = await repo.tasksInRange(
          LocalDateRange.monthOf(d('2026-11-15')),
        );
        final queryElapsed = DateTime.now().difference(queryStarted);

        final expected = List<int>.generate(
          2000,
          (index) => index,
        ).where((index) => 1 + (index % 12) == 11).length;
        expect(november, hasLength(expected));
        expect(
          queryElapsed.inMilliseconds,
          lessThan(2000),
          reason: '单月查询必须在秒级以内，否则月历会卡',
        );
        expect(await repo.watchAllTasks().first, hasLength(2000));
      } finally {
        await env.dispose();
      }
    });

    test('磁盘写满：报可读错误、整体回滚，恢复空间后可继续写', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      final repo = env.repository;
      try {
        await repo.createProject(const ProjectDraft(name: '已有项目'));
        final pages =
            env.database.handle.select('PRAGMA page_count').first['page_count']
                as int;
        env.database.handle.execute('PRAGMA max_page_count = $pages');

        var failures = 0;
        String? message;
        for (var index = 0; index < 200 && failures == 0; index++) {
          try {
            await repo.createProject(
              ProjectDraft(name: '填充项目 $index', description: 'x' * 2000),
            );
          } on LocalDatabaseException catch (error) {
            failures += 1;
            message = error.message;
          }
        }

        expect(failures, 1, reason: '写满后必须报错，不能静默丢数据');
        expect(message, isNotNull);
        expect(
          message,
          anyOf(contains('磁盘空间不足'), contains('保存失败'), contains('写入失败')),
        );

        final liveCount =
            env.database.handle
                    .select(
                      'SELECT COUNT(*) AS c FROM projects WHERE deleted_at IS NULL',
                    )
                    .first['c']
                as int;
        final persisted = await repo.watchProjects().first;
        expect(persisted, hasLength(liveCount), reason: '失败的那次写入必须整体回滚');
        expect(env.database.integrityCheck(), 'ok');

        env.database.handle.execute('PRAGMA max_page_count = 1073741823');
        final healthy = await repo.createProject(
          const ProjectDraft(name: '恢复后新增'),
        );
        expect(healthy.name, '恢复后新增');
        expect(env.database.integrityCheck(), 'ok');
      } finally {
        await env.dispose();
      }
    });

    test('数据库被其它连接写锁占用时给出可读错误，解锁后恢复正常', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now, busyTimeoutMs: 60);
      try {
        final blocker = sqlite3.open(env.databasePath);
        blocker.execute('BEGIN IMMEDIATE');
        try {
          await expectLater(
            () =>
                env.repository.createProject(const ProjectDraft(name: '写不进去')),
            throwsA(
              isA<LocalDatabaseException>().having(
                (error) => error.message,
                'message',
                contains('占用'),
              ),
            ),
          );
        } finally {
          blocker.execute('ROLLBACK');
          blocker.close();
        }

        final saved = await env.repository.createProject(
          const ProjectDraft(name: '解锁后新增'),
        );
        expect(saved.name, '解锁后新增');
      } finally {
        await env.dispose();
      }
    });

    test('首次创建：自动建出完整目录层级', () async {
      final directory = Directory.systemTemp.createTempSync('jihuatai_nested_');
      try {
        final path = p.join(directory.path, '计划台', 'data', 'app.db');
        final database = PlannerDatabase.open(path: path);
        try {
          expect(File(path).existsSync(), isTrue);
          expect(database.storedSchemaVersion, PlannerDatabase.schemaVersion);
        } finally {
          await database.close();
        }
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('异常退出后重启：WAL 里已提交的数据能被恢复', () async {
      final clock = FakeClock();
      final env = TestEnv.create(clock: clock.now);
      // 把"崩溃瞬间磁盘上的文件"（主库 + WAL）复制到另一个目录，
      // 相当于进程被强杀、来不及 checkpoint。
      final crashDirectory = Directory.systemTemp.createTempSync(
        'jihuatai_crash_',
      );
      try {
        await env.repository.createTask(
          PlannerTaskDraft(title: '崩溃前写入', scheduledDate: d('2026-11-16')),
        );

        final wal = File('${env.databasePath}-wal');
        expect(wal.existsSync(), isTrue, reason: '刚提交的数据应先落在 WAL 里');

        File(env.databasePath).copySync(p.join(crashDirectory.path, 'app.db'));
        wal.copySync(p.join(crashDirectory.path, 'app.db-wal'));
      } finally {
        await env.dispose();
      }

      final recovered = TestEnv.openIn(crashDirectory, clock: clock.now);
      try {
        final tasks = await recovered.repository.watchAllTasks().first;
        expect(tasks.single.title, '崩溃前写入');
        expect(tasks.single.scheduledDate!.iso, '2026-11-16');
        expect(recovered.database.integrityCheck(), 'ok');
      } finally {
        await recovered.dispose();
      }
    });

    test('损坏的数据库文件不会被静默重建', () {
      final directory = Directory.systemTemp.createTempSync(
        'jihuatai_corrupt_',
      );
      try {
        final path = p.join(directory.path, 'app.db');
        File(path).writeAsBytesSync(List<int>.filled(128, 0x41), flush: true);
        final sizeBefore = File(path).lengthSync();

        expect(
          () => PlannerDatabase.open(path: path),
          throwsA(isA<LocalDatabaseException>()),
        );
        expect(File(path).existsSync(), isTrue, reason: '不能删掉用户文件重建');
        expect(File(path).lengthSync(), sizeBefore);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });
}
