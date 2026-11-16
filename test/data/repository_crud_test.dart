import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/test_env.dart';

void main() {
  late FakeClock clock;
  late TestEnv env;
  late SqlitePlannerRepository repo;

  setUp(() {
    clock = FakeClock();
    env = TestEnv.create(clock: clock.now);
    repo = env.repository;
  });

  tearDown(() async {
    await env.dispose();
  });

  group('项目 CRUD', () {
    test('创建项目：revision 从 1 开始、名称去空白、颜色按色板自动分配', () async {
      final first = await repo.createProject(
        const ProjectDraft(name: '  新项目  '),
      );

      expect(first.name, '新项目');
      expect(first.revision, 1);
      expect(first.deletedAt, isNull);
      expect(first.color, ProjectColor.blue);
      expect(first.createdAt, clock.value);
      expect(first.createdAt.isUtc, isTrue);
      expect(first.updatedAt, first.createdAt);

      final second = await repo.createProject(
        const ProjectDraft(name: '第二个项目'),
      );
      expect(second.color, ProjectColor.palette[1], reason: '第二个项目取色板第二色');
      expect(
        await repo.findProject(first.id),
        first,
        reason: '读回的实体应与写入值全字段相等',
      );
    });

    test('更新项目：revision +1、updatedAt 刷新、createdAt 与 id 不变', () async {
      final project = await repo.createProject(
        const ProjectDraft(name: '项目', description: '旧描述'),
      );

      clock.advance(const Duration(minutes: 5));
      final updated = await repo.updateProject(
        project.copyWith(name: '改名', description: '新描述', sortOrder: 7),
      );

      expect(updated.id, project.id);
      expect(updated.revision, 2);
      expect(updated.createdAt, project.createdAt);
      expect(updated.updatedAt.isAfter(project.updatedAt), isTrue);
      expect(updated.name, '改名');
      expect(updated.sortOrder, 7);
      expect(await repo.findProject(project.id), updated);
    });

    test('更新项目使用过期 revision 时抛冲突，且不写入', () async {
      final project = await repo.createProject(const ProjectDraft(name: '项目'));
      final fresh = await repo.updateProject(project.copyWith(name: '第一次'));

      await expectLater(
        () => repo.updateProject(project.copyWith(name: '用旧版本覆盖')),
        throwsA(
          isA<PlannerConflictException>()
              .having((e) => e.expected, 'expected', 1)
              .having((e) => e.actual, 'actual', 2),
        ),
      );

      expect((await repo.findProject(project.id))!.name, '第一次');
      expect(fresh.revision, 2);
    });

    test('删除项目：级联软删除阶段与任务，三者 deletedAt 一致，原始行保留', () async {
      final project = await repo.createProject(
        const ProjectDraft(name: '要删的项目'),
      );
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '阶段',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-07'),
        ),
      );
      final task = await repo.createTask(
        PlannerTaskDraft(
          title: '任务',
          projectId: project.id,
          spanId: span.id,
          scheduledDate: d('2026-11-04'),
        ),
      );

      clock.advance(const Duration(hours: 1));
      await repo.deleteProject(project.id);

      expect(await repo.findProject(project.id), isNull);
      expect(await repo.findSpan(span.id), isNull);
      expect(await repo.findTask(task.id), isNull);
      expect(await repo.watchProjects().first, isEmpty);
      expect(await repo.watchAllTasks().first, isEmpty);

      String? stampOf(String table) {
        final rows = env.database.handle.select(
          'SELECT deleted_at FROM $table WHERE id = ?',
          <Object?>[
            switch (table) {
              'projects' => project.id,
              'plan_spans' => span.id,
              _ => task.id,
            },
          ],
        );
        return rows.single['deleted_at'] as String?;
      }

      final projectStamp = stampOf('projects');
      expect(projectStamp, isNotNull);
      expect(stampOf('plan_spans'), projectStamp, reason: '级联删除必须同一时刻写入');
      expect(stampOf('planner_tasks'), projectStamp);

      final revisions = env.database.handle.select(
        'SELECT revision FROM planner_tasks WHERE id = ?',
        <Object?>[task.id],
      );
      expect(revisions.single['revision'], 2, reason: '软删除也要 revision +1');
    });

    test('项目不存在时更新 / 删除抛未找到', () async {
      await expectLater(
        () => repo.deleteProject('not-exist'),
        throwsA(isA<PlannerNotFoundException>()),
      );
    });
  });

  group('跨天阶段 CRUD', () {
    test('创建阶段：项目必须存在，结束日不能早于开始日', () async {
      await expectLater(
        () => repo.createSpan(
          PlanSpanDraft(
            projectId: 'missing-project',
            title: '阶段',
            startDate: d('2026-11-03'),
            endDate: d('2026-11-07'),
          ),
        ),
        throwsA(isA<PlannerNotFoundException>()),
      );

      final project = await repo.createProject(const ProjectDraft(name: '项目'));
      await expectLater(
        () => repo.createSpan(
          PlanSpanDraft(
            projectId: project.id,
            title: '倒着写',
            startDate: d('2026-11-07'),
            endDate: d('2026-11-03'),
          ),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('创建阶段：闭区间天数正确（3 日到 7 日是 5 天）', () async {
      final project = await repo.createProject(const ProjectDraft(name: '项目'));
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '信息架构评审',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-07'),
          color: ProjectColor.teal,
        ),
      );

      expect(span.lengthInDays, 5);
      expect(span.covers(d('2026-11-03')), isTrue);
      expect(span.covers(d('2026-11-07')), isTrue);
      expect(span.covers(d('2026-11-08')), isFalse);
      expect((await repo.findSpan(span.id))!.color, ProjectColor.teal);
    });

    test('更新阶段：版本冲突被拒绝', () async {
      final project = await repo.createProject(const ProjectDraft(name: '项目'));
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '阶段',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-07'),
        ),
      );
      final updated = await repo.updateSpan(
        span.copyWith(status: PlanSpanStatus.doing),
      );

      await expectLater(
        () => repo.updateSpan(span.copyWith(title: '旧版本')),
        throwsA(isA<PlannerConflictException>()),
      );
      expect((await repo.findSpan(span.id))!.status, PlanSpanStatus.doing);
      expect(updated.revision, 2);
    });

    test('删除阶段：阶段消失，任务保留且 spanId 置空、revision +1', () async {
      final project = await repo.createProject(const ProjectDraft(name: '项目'));
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '阶段',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-07'),
        ),
      );
      final task = await repo.createTask(
        PlannerTaskDraft(
          title: '挂在阶段上的任务',
          projectId: project.id,
          spanId: span.id,
          scheduledDate: d('2026-11-04'),
        ),
      );

      clock.advance(const Duration(minutes: 1));
      await repo.deleteSpan(span.id);

      final reloaded = (await repo.findTask(task.id))!;
      expect(await repo.findSpan(span.id), isNull);
      expect(reloaded.spanId, isNull);
      expect(reloaded.projectId, project.id);
      expect(reloaded.title, task.title);
      expect(reloaded.revision, 2);
      expect(reloaded.updatedAt.isAfter(task.updatedAt), isTrue);
    });
  });

  group('任务 CRUD', () {
    test('三种任务形态：收件箱 / 只排到日 / 排到具体时刻', () async {
      final inbox = await repo.createTask(
        const PlannerTaskDraft(title: '收件箱任务'),
      );
      expect(inbox.isUnscheduled, isTrue);
      expect(inbox.timeSlot, isNull);

      final dayOnly = await repo.createTask(
        PlannerTaskDraft(title: '只排到日', scheduledDate: d('2026-11-16')),
      );
      expect(dayOnly.scheduledDate, d('2026-11-16'));
      expect(dayOnly.hasTime, isFalse, reason: '不排几点是合法状态，不能补默认时间');

      final timed = await repo.createTask(
        PlannerTaskDraft(
          title: '排到 09:00',
          scheduledDate: d('2026-11-16'),
          timeSlot: TimeSlot.at(hour: 9, durationMinutes: 90),
        ),
      );
      expect(timed.timeSlot!.startMinute, 540);
      expect(timed.timeSlot!.durationMinutes, 90);

      expect(await repo.findTask(timed.id), timed);
    });

    test('有时间的任务必须先有日期', () async {
      await expectLater(
        () => repo.createTask(
          PlannerTaskDraft(title: '只有时间', timeSlot: TimeSlot(startMinute: 540)),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('任务的阶段必须属于同一项目', () async {
      final first = await repo.createProject(const ProjectDraft(name: '项目一'));
      final second = await repo.createProject(const ProjectDraft(name: '项目二'));
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: first.id,
          title: '阶段',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-07'),
        ),
      );

      await expectLater(
        () => repo.createTask(
          PlannerTaskDraft(
            title: '跨项目挂阶段',
            projectId: second.id,
            spanId: span.id,
            scheduledDate: d('2026-11-04'),
          ),
        ),
        throwsA(isA<PlannerValidationException>()),
      );

      await expectLater(
        () =>
            repo.createTask(PlannerTaskDraft(title: '有阶段没项目', spanId: span.id)),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('完成任务写入完成时刻，取消完成清空，已完成状态改写不清空', () async {
      final task = await repo.createTask(
        PlannerTaskDraft(title: '要做的事', scheduledDate: d('2026-11-16')),
      );

      clock.advance(const Duration(minutes: 30));
      final completionMoment = clock.value;
      final done = await repo.updateTask(
        task.copyWith(status: TaskStatus.done),
      );
      expect(done.status, TaskStatus.done);
      expect(done.completedAt, completionMoment);
      expect(done.revision, 2);

      clock.advance(const Duration(minutes: 30));
      final renamed = await repo.updateTask(done.copyWith(title: '改个名'));
      expect(renamed.completedAt, completionMoment, reason: '已完成任务改标题不应重置完成时刻');

      final undone = await repo.updateTask(
        renamed.copyWith(status: TaskStatus.todo),
      );
      expect(undone.completedAt, isNull);
      expect(undone.status, TaskStatus.todo);

      final stored = await repo.findTask(task.id);
      expect(stored!.completedAt, isNull);
    });

    test('直接从草稿创建已完成任务会写入完成时刻', () async {
      final done = await repo.createTask(
        PlannerTaskDraft(
          title: '一开始就完成',
          scheduledDate: d('2026-11-16'),
          status: TaskStatus.done,
        ),
      );
      expect(done.status, TaskStatus.done);
      expect(done.completedAt, clock.value);
    });

    test('删除任务为软删除：查询不到但原始行仍在，revision +1', () async {
      final task = await repo.createTask(const PlannerTaskDraft(title: '待删除'));

      await repo.deleteTask(task.id);

      expect(await repo.findTask(task.id), isNull);
      expect(await repo.watchAllTasks().first, isEmpty);

      final rows = env.database.handle.select(
        'SELECT deleted_at, revision FROM planner_tasks WHERE id = ?',
        <Object?>[task.id],
      );
      expect(rows, hasLength(1), reason: '软删除不能物理删除');
      expect(rows.single['deleted_at'], isNotNull);
      expect(rows.single['revision'], 2);

      await expectLater(
        () => repo.deleteTask(task.id),
        throwsA(isA<PlannerNotFoundException>()),
      );
    });

    test('任务字段边界：标题超长被拒绝，备注与排序正常保存', () async {
      await expectLater(
        () => repo.createTask(PlannerTaskDraft(title: 'x' * 201)),
        throwsA(isA<PlannerValidationException>()),
      );

      final task = await repo.createTask(
        PlannerTaskDraft(
          title: '带备注',
          notes: '备注内容',
          priority: TaskPriority.urgent,
          sortOrder: 3,
          scheduledDate: d('2026-11-16'),
        ),
      );
      final reloaded = (await repo.findTask(task.id))!;
      expect(reloaded.notes, '备注内容');
      expect(reloaded.priority, TaskPriority.urgent);
      expect(reloaded.sortOrder, 3);
    });
  });

  group('每日备注', () {
    test('同一天第二次保存复用同一条记录（id 不变、revision +1）', () async {
      final date = d('2026-11-14');
      final first = await repo.saveDailyNote(
        date,
        body: '第一版',
        focusItems: <String>['重点一 ', '', '重点二'],
      );
      expect(first.revision, 1);
      expect(first.focusItems, <String>['重点一', '重点二'], reason: '去空白、去空串');

      clock.advance(const Duration(minutes: 2));
      final second = await repo.saveDailyNote(date, body: '第二版');

      expect(second.id, first.id);
      expect(second.revision, 2);
      expect(second.body, '第二版');
      expect(second.focusItems, isEmpty);
      expect(second.createdAt, first.createdAt);
      expect(await repo.findDailyNote(date), second);
      expect(
        env.database.handle
            .select('SELECT COUNT(*) AS c FROM daily_notes')
            .first['c'],
        1,
        reason: '一天只能有一条备注',
      );
    });

    test('当日重点最多 3 条、单条不超过 60 字', () async {
      final date = d('2026-11-14');
      await expectLater(
        () =>
            repo.saveDailyNote(date, focusItems: <String>['a', 'b', 'c', 'd']),
        throwsA(isA<PlannerValidationException>()),
      );
      await expectLater(
        () => repo.saveDailyNote(date, focusItems: <String>['x' * 61]),
        throwsA(isA<PlannerValidationException>()),
      );
      expect(await repo.findDailyNote(date), isNull, reason: '失败不应留下脏数据');
    });

    test('没有备注时返回 null（不等于空备注）', () async {
      expect(await repo.findDailyNote(d('2026-11-20')), isNull);
      expect(await repo.watchDailyNote(d('2026-11-20')).first, isNull);
    });
  });

  group('一致性与可靠性', () {
    test('事务回滚：中途抛异常时一条都不写', () async {
      await repo.createProject(const ProjectDraft(name: '已有项目'));
      final now = DateTime.utc(2026, 1, 1);
      final ghost = Project(
        id: 'ghost-project',
        createdAt: now,
        updatedAt: now,
        revision: 1,
        name: '半条数据',
      );

      await expectLater(
        () async => env.database.transaction(() {
          env.database.handle.execute(
            insertProjectSql,
            projectInsertParams(ghost),
          );
          throw StateError('模拟写入中途失败');
        }),
        throwsA(isA<StateError>()),
      );

      final count = env.database.handle
          .select('SELECT COUNT(*) AS c FROM projects')
          .first['c'];
      expect(count, 1, reason: '事务必须整体回滚');
      expect(await repo.findProject('ghost-project'), isNull);
    });

    test('数据库约束：原始 SQL 也写不进非法阶段与悬空外键', () {
      final project = Project(
        id: 'p1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        revision: 1,
        name: '项目',
      );
      env.database.handle.execute(
        insertProjectSql,
        projectInsertParams(project),
      );

      expect(
        () => env.database.handle.execute(
          'INSERT INTO plan_spans (id, created_at, updated_at, revision, '
          'project_id, title, start_date, end_date) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'bad-span',
            '2026-01-01T00:00:00.000000Z',
            '2026-01-01T00:00:00.000000Z',
            1,
            project.id,
            '倒序阶段',
            '2026-11-07',
            '2026-11-03',
          ],
        ),
        throwsA(isA<SqliteException>()),
        reason: 'CHECK (end_date >= start_date) 必须拦住',
      );

      expect(
        () => env.database.handle.execute(
          'INSERT INTO planner_tasks (id, created_at, updated_at, revision, '
          'project_id, title) VALUES (?, ?, ?, ?, ?, ?)',
          <Object?>[
            'bad-task',
            '2026-01-01T00:00:00.000000Z',
            '2026-01-01T00:00:00.000000Z',
            1,
            'no-such-project',
            '悬空任务',
          ],
        ),
        throwsA(isA<SqliteException>()),
        reason: 'PRAGMA foreign_keys = ON 必须生效',
      );
    });

    test('每次写入都留下 change_log 记录（为同步预留）', () async {
      final project = await repo.createProject(const ProjectDraft(name: '项目'));
      await repo.createTask(
        PlannerTaskDraft(title: '任务', projectId: project.id),
      );

      final rows = env.database.handle.select(
        'SELECT entity_type, operation, revision FROM change_log ORDER BY seq',
      );
      expect(
        rows
            .map(
              (row) =>
                  '${row['entity_type']}:${row['operation']}:${row['revision']}',
            )
            .toList(),
        <String>['project:create:1', 'task:create:1'],
      );
    });

    test('关闭仓储后写操作抛 StateError，close 可重复调用', () async {
      await repo.close();
      await repo.close();

      expect(
        () => repo.createProject(const ProjectDraft(name: '关闭后')),
        throwsA(isA<StateError>()),
      );
    });
  });
}
