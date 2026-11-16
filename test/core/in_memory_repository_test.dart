import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';

void main() {
  late InMemoryPlannerRepository repo;
  late int counter;

  setUp(() {
    counter = 0;
    repo = InMemoryPlannerRepository(
      clock: () => DateTime.utc(2026, 11, 14, 8, 0, counter++),
    );
  });

  tearDown(() => repo.close());

  Future<Project> project([String name = '项目A']) =>
      repo.createProject(ProjectDraft(name: name));

  Future<PlannerTask> task({
    required LocalDate date,
    String title = '任务',
    TimeSlot? slot,
    String? projectId,
    TaskPriority priority = TaskPriority.normal,
  }) => repo.createTask(
    PlannerTaskDraft(
      title: title,
      projectId: projectId,
      scheduledDate: date,
      timeSlot: slot,
      priority: priority,
    ),
  );

  group('项目', () {
    test('创建时去空白、自动配色、版本从 1 开始', () async {
      final p1 = await repo.createProject(const ProjectDraft(name: '  项目A  '));
      final p2 = await repo.createProject(const ProjectDraft(name: '项目B'));
      final p3 = await repo.createProject(
        const ProjectDraft(name: '项目C', color: ProjectColor.red),
      );

      expect(p1.name, '项目A');
      expect(p1.color, ProjectColor.blue);
      expect(p2.color, ProjectColor.teal);
      expect(p3.color, ProjectColor.red);
      expect(p1.revision, 1);
      expect(p1.createdAt.isUtc, isTrue);
    });

    test('更新递增 revision，冲突时抛异常', () async {
      final p1 = await project();
      final updated = await repo.updateProject(p1.copyWith(name: '项目A2'));
      expect(updated.revision, 2);
      expect((await repo.findProject(p1.id))!.name, '项目A2');
      await expectLater(
        repo.updateProject(p1.copyWith(name: '旧版本写入')),
        throwsA(isA<PlannerConflictException>()),
      );
    });

    test('归档项目默认不出现在 watchProjects，可选包含', () async {
      final p1 = await project();
      await repo.updateProject(p1.copyWith(status: ProjectStatus.archived));
      expect(await repo.watchProjects().first, isEmpty);
      expect((await repo.watchProjects(includeArchived: true).first).length, 1);
    });
  });

  group('任务范围查询', () {
    test('闭区间、排除未排期、稳定排序', () async {
      final p = await project();
      final t1 = await task(
        date: LocalDate(2026, 11, 10),
        title: '有时间',
        slot: TimeSlot.at(hour: 9, durationMinutes: 60),
        projectId: p.id,
      );
      final t2 = await task(date: LocalDate(2026, 11, 10), title: '无时间');
      final t3 = await task(
        date: LocalDate(2026, 11, 12),
        title: '区间末日',
        priority: TaskPriority.high,
      );
      await task(date: LocalDate(2026, 11, 9), title: '区间外');
      final unscheduled = await repo.createTask(
        const PlannerTaskDraft(title: '收件箱任务'),
      );

      final range = LocalDateRange(
        LocalDate(2026, 11, 10),
        LocalDate(2026, 11, 12),
      );
      final tasks = await repo.tasksInRange(range);
      expect(tasks.map((t) => t.id), <String>[t1.id, t2.id, t3.id]);
      expect(
        (await repo.watchUnscheduledTasks().first).single.id,
        unscheduled.id,
      );
    });

    test('跨天阶段用闭区间重叠查询', () async {
      final p = await project();
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: p.id,
          title: '跨月阶段',
          startDate: LocalDate(2026, 10, 28),
          endDate: LocalDate(2026, 11, 3),
        ),
      );
      final visible = await repo
          .watchSpansInRange(
            LocalDateRange(LocalDate(2026, 11, 1), LocalDate(2026, 11, 30)),
          )
          .first;
      expect(visible.single.id, span.id);
      final outside = await repo
          .watchSpansInRange(
            LocalDateRange(LocalDate(2026, 12, 1), LocalDate(2026, 12, 31)),
          )
          .first;
      expect(outside, isEmpty);
    });

    test('流先推当前值，写入后推新值', () async {
      final p = await project();
      final values = <List<PlannerTask>>[];
      final subscription = repo.watchTasksForProject(p.id).listen(values.add);
      await Future<void>.delayed(Duration.zero);
      expect(values, hasLength(1));
      expect(values.first, isEmpty);

      await task(date: LocalDate(2026, 11, 14), projectId: p.id);
      await Future<void>.delayed(Duration.zero);
      expect(values, hasLength(2));
      expect(values.last, hasLength(1));

      await subscription.cancel();
    });
  });

  group('任务状态与并发', () {
    test('完成时写入 completedAt，取消完成时清空', () async {
      final t = await task(date: LocalDate(2026, 11, 14));
      final done = await repo.updateTask(t.copyWith(status: TaskStatus.done));
      expect(done.isDone, isTrue);
      expect(done.completedAt, isNotNull);
      expect(done.completedAt!.isUtc, isTrue);

      final reopened = await repo.updateTask(
        done.copyWith(status: TaskStatus.todo),
      );
      expect(reopened.completedAt, isNull);
    });

    test('过期 revision 的更新被拒绝', () async {
      final t = await task(date: LocalDate(2026, 11, 14));
      final fresh = await repo.updateTask(t.copyWith(title: '第一次修改'));
      expect(fresh.revision, 2);
      await expectLater(
        () => repo.updateTask(t.copyWith(title: '并发修改')),
        throwsA(isA<PlannerConflictException>()),
      );
    });

    test('删除任务后查询为空', () async {
      final t = await task(date: LocalDate(2026, 11, 14));
      await repo.deleteTask(t.id);
      expect(await repo.findTask(t.id), isNull);
      expect(await repo.watchAllTasks().first, isEmpty);
    });
  });

  group('级联与关联', () {
    test('删除阶段保留任务，只解开关联', () async {
      final p = await project();
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: p.id,
          title: '阶段',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
        ),
      );
      final t = await repo.createTask(
        PlannerTaskDraft(
          title: '阶段任务',
          projectId: p.id,
          spanId: span.id,
          scheduledDate: LocalDate(2026, 11, 4),
        ),
      );
      await repo.deleteSpan(span.id);
      final kept = await repo.findTask(t.id);
      expect(kept, isNotNull);
      expect(kept!.spanId, isNull);
      expect(kept.projectId, p.id);
      expect(kept.revision, 2);
    });

    test('删除项目级联软删除阶段与任务', () async {
      final p = await project();
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: p.id,
          title: '阶段',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
        ),
      );
      final t = await repo.createTask(
        PlannerTaskDraft(
          title: '任务',
          projectId: p.id,
          scheduledDate: LocalDate(2026, 11, 4),
        ),
      );

      await repo.deleteProject(p.id);

      expect(await repo.findProject(p.id), isNull);
      expect(await repo.findSpan(span.id), isNull);
      expect(await repo.findTask(t.id), isNull);
      expect(await repo.watchProjects(includeArchived: true).first, isEmpty);
      expect(await repo.watchAllTasks().first, isEmpty);
    });

    test('任务关联的阶段必须同项目', () async {
      final p1 = await project('项目A');
      final p2 = await project('项目B');
      final span = await repo.createSpan(
        PlanSpanDraft(
          projectId: p1.id,
          title: 'A 的阶段',
          startDate: LocalDate(2026, 11, 3),
          endDate: LocalDate(2026, 11, 7),
        ),
      );
      await expectLater(
        () => repo.createTask(
          PlannerTaskDraft(
            title: '跨项目关联',
            projectId: p2.id,
            spanId: span.id,
            scheduledDate: LocalDate(2026, 11, 4),
          ),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });
  });

  group('每日备注', () {
    test('同一天 upsert，revision 递增', () async {
      final date = LocalDate(2026, 11, 14);
      final first = await repo.saveDailyNote(date, body: '第一版');
      final second = await repo.saveDailyNote(
        date,
        body: '第二版',
        focusItems: const <String>['重点一'],
      );
      expect(second.id, first.id);
      expect(second.revision, 2);
      expect(second.body, '第二版');
      expect(second.focusItems, <String>['重点一']);
      expect((await repo.findDailyNote(date))!.body, '第二版');
      expect(await repo.findDailyNote(date.addDays(1)), isNull);
    });

    test('非法重点数量被拒绝', () async {
      await expectLater(
        () => repo.saveDailyNote(
          LocalDate(2026, 11, 14),
          focusItems: const <String>['1', '2', '3', '4'],
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });
  });

  group('输入校验', () {
    test('带时间但没有日期', () async {
      await expectLater(
        () => repo.createTask(
          PlannerTaskDraft(title: '无日期', timeSlot: TimeSlot.at(hour: 9)),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('阶段结束日早于开始日', () async {
      final p = await project();
      await expectLater(
        () => repo.createSpan(
          PlanSpanDraft(
            projectId: p.id,
            title: '错误区间',
            startDate: LocalDate(2026, 11, 7),
            endDate: LocalDate(2026, 11, 3),
          ),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('不存在的项目不能创建任务', () async {
      await expectLater(
        () => repo.createTask(
          PlannerTaskDraft(
            title: '幽灵任务',
            projectId: 'not-exists',
            scheduledDate: LocalDate(2026, 11, 14),
          ),
        ),
        throwsA(isA<PlannerNotFoundException>()),
      );
    });
  });
}
