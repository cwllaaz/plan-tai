import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// 验证 V1 真实数据库升级到 V2：只加列/加表，用户数据与 revision 不变。
void main() {
  test('v1 → v2 迁移：项目/任务/备注保留，server_revision=0，同步表就绪', () {
    final directory = Directory.systemTemp.createTempSync('jihuatai_mig_v2_');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final path = p.join(directory.path, 'app.db');
    final now = DateTime.utc(2026, 11, 1, 8);
    final project = Project(
      id: '0192f0a1-0000-7000-8000-000000000101',
      createdAt: now,
      updatedAt: now,
      revision: 3,
      name: '升级前项目',
      description: '不能丢',
      color: ProjectColor.blue,
    );
    final task = PlannerTask(
      id: '0192f0a2-0000-7000-8000-000000000101',
      createdAt: now,
      updatedAt: now,
      revision: 5,
      projectId: project.id,
      title: '升级前任务',
      scheduledDate: LocalDate.parse('2026-11-16'),
      priority: TaskPriority.high,
    );
    final note = DailyNote(
      id: '0192f0a3-0000-7000-8000-000000000101',
      createdAt: now,
      updatedAt: now,
      revision: 2,
      date: LocalDate.parse('2026-11-16'),
      body: '升级前备注',
    );

    final raw = sqlite3.open(path);
    try {
      for (final statement in createSchemaV1Statements) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 1');
      raw.execute(
        'INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)',
        <Object?>['schema_version', '1'],
      );
      raw.execute(insertProjectSql, projectInsertParams(project));
      raw.execute(insertTaskSql, taskInsertParams(task));
      raw.execute(insertNoteSql, noteInsertParams(note));
    } finally {
      raw.close();
    }

    final database = PlannerDatabase.open(path: path);
    addTearDown(database.close);
    expect(database.storedSchemaVersion, 2);

    final migrated = database.handle
        .select(
          'SELECT * FROM projects WHERE id = ?',
          <Object?>[project.id],
        )
        .single;
    expect(migrated['name'], '升级前项目');
    expect(migrated['revision'], 3);
    expect(migrated['server_revision'], 0);
    expect(migrated['created_at'], isNotNull);
    final taskRow = database.handle
        .select('SELECT * FROM planner_tasks WHERE id = ?', <Object?>[task.id])
        .single;
    expect(taskRow['title'], '升级前任务');
    expect(taskRow['revision'], 5);
    expect(taskRow['server_revision'], 0);
    final noteRow = database.handle
        .select('SELECT * FROM daily_notes WHERE id = ?', <Object?>[note.id])
        .single;
    expect(noteRow['body'], '升级前备注');

    final tables = database.handle
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    expect(
      tables,
      containsAll(<String>[
        'sync_outbox',
        'sync_conflicts',
        'sync_state',
      ]),
    );
    final state = database.handle
        .select('SELECT auto_sync, cursor FROM sync_state WHERE id = 1')
        .single;
    expect(state['auto_sync'], 1);
    expect(state['cursor'], isNull);
  });
}
