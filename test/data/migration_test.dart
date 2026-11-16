import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'support/test_env.dart';

void main() {
  test('新建数据库即为最新结构，契约要求的表与索引都存在', () async {
    final env = TestEnv.create(clock: FakeClock().now);
    try {
      expect(env.database.storedSchemaVersion, PlannerDatabase.schemaVersion);
      expect(env.database.storedSchemaVersion, 2);

      final tables = env.database.handle
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toSet();
      expect(
        tables,
        containsAll(<String>[
          'projects',
          'plan_spans',
          'planner_tasks',
          'daily_notes',
          'change_log',
          'settings',
        ]),
      );

      final indexes = env.database.handle
          .select("SELECT name FROM sqlite_master WHERE type = 'index'")
          .map((row) => row['name'] as String)
          .toSet();
      expect(
        indexes,
        containsAll(<String>[
          'idx_tasks_scheduled',
          'idx_tasks_project',
          'idx_tasks_span',
          'idx_tasks_status',
          'idx_spans_range',
          'idx_spans_project',
          'idx_notes_date',
        ]),
        reason: 'docs/DATA_CONTRACT.md §7 要求的索引一个都不能少',
      );

      final mirror = env.database.handle
          .select("SELECT value FROM settings WHERE key = 'schema_version'")
          .single['value'];
      expect(mirror, '${PlannerDatabase.schemaVersion}');
    } finally {
      await env.dispose();
    }
  });

  test('重新打开不会重复建表，用户数据保留', () async {
    final clock = FakeClock();
    final env = TestEnv.create(clock: clock.now);
    final project = await env.repository.createProject(
      const ProjectDraft(name: '不能丢的项目'),
    );
    await env.repository.close();

    final reopened = TestEnv.openIn(env.directory, clock: clock.now);
    try {
      expect(reopened.database.storedSchemaVersion, 2);
      expect(
        (await reopened.repository.findProject(project.id))!.name,
        '不能丢的项目',
      );
    } finally {
      await reopened.dispose();
    }
  });

  test('数据库版本高于当前应用时拒绝打开，且不动用户数据', () {
    final directory = Directory.systemTemp.createTempSync('jihuatai_version_');
    try {
      final path = p.join(directory.path, 'app.db');
      final raw = sqlite3.open(path);
      raw.execute('CREATE TABLE keeper(value TEXT)');
      raw.execute("INSERT INTO keeper(value) VALUES ('旧数据')");
      raw.execute('PRAGMA user_version = 99');
      raw.close();

      expect(
        () => PlannerDatabase.open(path: path),
        throwsA(
          isA<LocalDatabaseException>().having(
            (error) => error.message,
            'message',
            contains('升级应用'),
          ),
        ),
      );

      final probe = sqlite3.open(path);
      try {
        expect(PlannerDatabase.readSchemaVersion(probe), 99);
        expect(probe.select('SELECT value FROM keeper').single['value'], '旧数据');
      } finally {
        probe.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('迁移机制：按版本顺序执行、可加列、旧数据无损', () {
    final directory = Directory.systemTemp.createTempSync('jihuatai_migrate_');
    try {
      final path = p.join(directory.path, 'app.db');
      final setup = sqlite3.open(path);
      setup.execute('CREATE TABLE demo(id TEXT PRIMARY KEY, name TEXT)');
      setup.execute("INSERT INTO demo(id, name) VALUES ('1', '旧数据')");
      setup.close();

      final handle = sqlite3.open(path);
      try {
        final steps = <SchemaMigration>[
          SchemaMigration(
            version: 1,
            description: '基础表已存在（空操作）',
            apply: (_) {},
          ),
          SchemaMigration(
            version: 2,
            description: '给 demo 增加 note 列',
            apply: (db) => db.execute('ALTER TABLE demo ADD COLUMN note TEXT'),
          ),
        ];

        PlannerDatabase.applyMigrations(handle, from: 0, to: 2, steps: steps);

        expect(PlannerDatabase.readSchemaVersion(handle), 2);
        final row = handle.select('SELECT id, name, note FROM demo').single;
        expect(row['name'], '旧数据', reason: '加列迁移不能丢数据');
        expect(row['note'], isNull);
      } finally {
        handle.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('缺少迁移脚本时停在已完成版本，并说明缺哪一步', () {
    final directory = Directory.systemTemp.createTempSync('jihuatai_missing_');
    try {
      final path = p.join(directory.path, 'app.db');
      final handle = sqlite3.open(path);
      try {
        final steps = <SchemaMigration>[
          SchemaMigration(
            version: 1,
            description: '建 t1',
            apply: (db) => db.execute('CREATE TABLE t1(x TEXT)'),
          ),
        ];

        expect(
          () => PlannerDatabase.applyMigrations(
            handle,
            from: 0,
            to: 2,
            steps: steps,
          ),
          throwsA(
            isA<LocalDatabaseException>().having(
              (error) => error.message,
              'message',
              contains('缺少'),
            ),
          ),
        );

        expect(PlannerDatabase.readSchemaVersion(handle), 1);
        expect(
          handle.select("SELECT name FROM sqlite_master WHERE name = 't1'"),
          hasLength(1),
        );
      } finally {
        handle.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('不允许回退结构版本', () {
    final directory = Directory.systemTemp.createTempSync(
      'jihuatai_downgrade_',
    );
    try {
      final handle = sqlite3.open(p.join(directory.path, 'app.db'));
      try {
        handle.execute('PRAGMA user_version = 2');
        expect(
          () => PlannerDatabase.applyMigrations(handle, from: 2, to: 1),
          throwsA(isA<LocalDatabaseException>()),
        );
        expect(PlannerDatabase.readSchemaVersion(handle), 2);
      } finally {
        handle.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('迁移脚本抛异常时整体回滚，版本与数据都不变', () {
    final directory = Directory.systemTemp.createTempSync('jihuatai_badmig_');
    try {
      final path = p.join(directory.path, 'app.db');
      final handle = sqlite3.open(path);
      try {
        handle.execute('CREATE TABLE demo(a TEXT)');
        handle.execute("INSERT INTO demo(a) VALUES ('x')");

        final steps = <SchemaMigration>[
          SchemaMigration(
            version: 1,
            description: '一半就崩的迁移',
            apply: (db) {
              db.execute('ALTER TABLE demo ADD COLUMN b TEXT');
              throw StateError('迁移脚本坏了');
            },
          ),
        ];

        expect(
          () => PlannerDatabase.applyMigrations(
            handle,
            from: 0,
            to: 1,
            steps: steps,
          ),
          throwsA(isA<LocalDatabaseException>()),
        );

        expect(PlannerDatabase.readSchemaVersion(handle), 0);
        expect(
          handle.select('PRAGMA table_info(demo)').map((row) => row['name']),
          isNot(contains('b')),
          reason: '失败的迁移不能留下半截结构',
        );
        expect(handle.select('SELECT a FROM demo').single['a'], 'x');
      } finally {
        handle.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
