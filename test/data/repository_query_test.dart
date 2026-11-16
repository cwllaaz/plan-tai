import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';

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

  group('任务范围查询与排序', () {
    test('闭区间过滤 + 契约排序：日期 → 有时间的在前 → 开始分钟 → 优先级 → 排序号', () async {
      final project = await repo.createProject(const ProjectDraft(name: 'P'));
      Future<void> add(
        String title, {
        required LocalDate day,
        TimeSlot? timeSlot,
        TaskPriority priority = TaskPriority.normal,
        int sortOrder = 0,
      }) => repo.createTask(
        PlannerTaskDraft(
          title: title,
          projectId: project.id,
          scheduledDate: day,
          timeSlot: timeSlot,
          priority: priority,
          sortOrder: sortOrder,
        ),
      );

      await add('无时刻-紧急', day: d('2026-11-16'), priority: TaskPriority.urgent);
      await add(
        '09:00-低',
        day: d('2026-11-16'),
        timeSlot: TimeSlot.at(hour: 9),
        priority: TaskPriority.low,
      );
      await add(
        '08:00-普通',
        day: d('2026-11-16'),
        timeSlot: TimeSlot.at(hour: 8),
      );
      await add(
        '10:00-普通-排序2',
        day: d('2026-11-16'),
        timeSlot: TimeSlot.at(hour: 10),
        sortOrder: 2,
      );
      await add(
        '10:00-普通-排序1',
        day: d('2026-11-16'),
        timeSlot: TimeSlot.at(hour: 10),
        sortOrder: 1,
      );
      await add('前一天', day: d('2026-11-15'));
      await add('后一天', day: d('2026-11-17'));
      await repo.createTask(const PlannerTaskDraft(title: '收件箱'));

      final today = await repo.tasksInRange(
        LocalDateRange.singleDay(d('2026-11-16')),
      );
      expect(today.map((task) => task.title).toList(), <String>[
        '08:00-普通',
        '09:00-低',
        '10:00-普通-排序1',
        '10:00-普通-排序2',
        '无时刻-紧急',
      ]);

      final wide = await repo.tasksInRange(
        LocalDateRange(d('2026-11-15'), d('2026-11-17')),
      );
      expect(wide, hasLength(7));
      expect(wide.first.title, '前一天');
      expect(wide.last.title, '后一天');
      expect(
        wide.any((task) => task.isUnscheduled),
        isFalse,
        reason: '未排期不属于任何范围',
      );
    });

    test('未排期任务单独查询，按优先级降序排列', () async {
      await repo.createTask(
        const PlannerTaskDraft(title: '低', priority: TaskPriority.low),
      );
      await repo.createTask(
        const PlannerTaskDraft(title: '紧急', priority: TaskPriority.urgent),
      );
      await repo.createTask(
        PlannerTaskDraft(title: '已排期', scheduledDate: d('2026-11-16')),
      );

      final unscheduled = await repo.watchUnscheduledTasks().first;
      expect(unscheduled.map((task) => task.title).toList(), <String>[
        '紧急',
        '低',
      ]);

      final all = await repo.watchAllTasks().first;
      expect(all.first.title, '已排期', reason: '已排期必须排在未排期之前');
      expect(all, hasLength(3));
    });

    test('按项目过滤任务，跨日期返回', () async {
      final first = await repo.createProject(const ProjectDraft(name: '项目一'));
      final second = await repo.createProject(const ProjectDraft(name: '项目二'));
      await repo.createTask(
        PlannerTaskDraft(
          title: '一月任务',
          projectId: first.id,
          scheduledDate: d('2026-01-05'),
        ),
      );
      await repo.createTask(
        PlannerTaskDraft(
          title: '十二月任务',
          projectId: first.id,
          scheduledDate: d('2026-12-05'),
        ),
      );
      await repo.createTask(
        PlannerTaskDraft(
          title: '别人的任务',
          projectId: second.id,
          scheduledDate: d('2026-06-05'),
        ),
      );

      final tasks = await repo.watchTasksForProject(first.id).first;
      expect(tasks.map((task) => task.title).toList(), <String>[
        '一月任务',
        '十二月任务',
      ]);
    });
  });

  group('跨天阶段范围查询', () {
    test('闭区间重叠：接触边界日算重叠，隔一天不算', () async {
      final project = await repo.createProject(const ProjectDraft(name: 'P'));
      await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '3-7 日阶段',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-07'),
        ),
      );

      final touchesEnd = await repo
          .watchSpansInRange(LocalDateRange(d('2026-11-07'), d('2026-11-10')))
          .first;
      expect(touchesEnd, hasLength(1), reason: '结束日当天必须算重叠');

      final touchesStart = await repo
          .watchSpansInRange(LocalDateRange(d('2026-11-01'), d('2026-11-03')))
          .first;
      expect(touchesStart, hasLength(1), reason: '开始日当天必须算重叠');

      final disjoint = await repo
          .watchSpansInRange(LocalDateRange(d('2026-11-08'), d('2026-11-10')))
          .first;
      expect(disjoint, isEmpty);

      final enclosing = await repo
          .watchSpansInRange(LocalDateRange(d('2026-10-01'), d('2026-12-31')))
          .first;
      expect(enclosing, hasLength(1));
    });

    test('跨月阶段同时出现在两个月的查询结果里', () async {
      final project = await repo.createProject(const ProjectDraft(name: 'P'));
      await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '10 月底到 11 月初',
          startDate: d('2026-10-28'),
          endDate: d('2026-11-03'),
        ),
      );

      final october = await repo
          .watchSpansInRange(LocalDateRange.monthOf(d('2026-10-15')))
          .first;
      final november = await repo
          .watchSpansInRange(LocalDateRange.monthOf(d('2026-11-15')))
          .first;
      final december = await repo
          .watchSpansInRange(LocalDateRange.monthOf(d('2026-12-15')))
          .first;

      expect(october, hasLength(1));
      expect(november, hasLength(1));
      expect(december, isEmpty);
    });

    test('阶段排序：开始日升序 → 结束日降序', () async {
      final project = await repo.createProject(const ProjectDraft(name: 'P'));
      await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '短',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-05'),
        ),
      );
      await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '长',
          startDate: d('2026-11-03'),
          endDate: d('2026-11-20'),
        ),
      );
      await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '更早',
          startDate: d('2026-11-01'),
          endDate: d('2026-11-02'),
        ),
      );

      final spans = await repo
          .watchSpansInRange(LocalDateRange.monthOf(d('2026-11-15')))
          .first;
      expect(spans.map((span) => span.title).toList(), <String>[
        '更早',
        '长',
        '短',
      ]);
    });

    test('阶段按项目过滤', () async {
      final first = await repo.createProject(const ProjectDraft(name: '项目一'));
      final second = await repo.createProject(const ProjectDraft(name: '项目二'));
      await repo.createSpan(
        PlanSpanDraft(
          projectId: first.id,
          title: 'A 的阶段',
          startDate: d('2026-11-01'),
          endDate: d('2026-11-02'),
        ),
      );
      await repo.createSpan(
        PlanSpanDraft(
          projectId: second.id,
          title: 'B 的阶段',
          startDate: d('2026-11-01'),
          endDate: d('2026-11-02'),
        ),
      );

      final spans = await repo.watchSpansForProject(first.id).first;
      expect(spans.map((span) => span.title).toList(), <String>['A 的阶段']);
    });
  });

  group('日期规则：不漂移', () {
    test('跨月末、闰年、跨年日期按原样存取', () async {
      const isoDates = <String>[
        '2024-02-29',
        '2026-01-31',
        '2026-02-01',
        '2026-12-31',
        '2027-01-01',
        '2026-11-16',
      ];

      for (final iso in isoDates) {
        final task = await repo.createTask(
          PlannerTaskDraft(
            title: '任务 $iso',
            scheduledDate: LocalDate.parse(iso),
          ),
        );
        expect(task.scheduledDate!.iso, iso);

        final stored = await repo.tasksInRange(
          LocalDateRange.singleDay(LocalDate.parse(iso)),
        );
        expect(stored.single.id, task.id, reason: '$iso 必须能按当天查到');

        final raw = env.database.handle.select(
          'SELECT scheduled_date FROM planner_tasks WHERE id = ?',
          <Object?>[task.id],
        ).single['scheduled_date'];
        expect(raw, iso, reason: '数据库里就是纯日期文本，不含时间与时区');
      }
    });

    test('1 月 31 日与 2 月 1 日分属不同月份查询', () async {
      await repo.createTask(
        PlannerTaskDraft(title: '1 月最后一天', scheduledDate: d('2026-01-31')),
      );
      await repo.createTask(
        PlannerTaskDraft(title: '2 月第一天', scheduledDate: d('2026-02-01')),
      );

      final january = await repo.tasksInRange(
        LocalDateRange.monthOf(d('2026-01-15')),
      );
      final february = await repo.tasksInRange(
        LocalDateRange.monthOf(d('2026-02-15')),
      );

      expect(january.map((task) => task.title).toList(), <String>['1 月最后一天']);
      expect(february.map((task) => task.title).toList(), <String>['2 月第一天']);
    });

    test('闰日 2 月 29 日只在闰年出现', () async {
      await repo.createTask(
        PlannerTaskDraft(title: '闰日任务', scheduledDate: d('2024-02-29')),
      );
      final leapDay = await repo.tasksInRange(
        LocalDateRange.singleDay(d('2024-02-29')),
      );
      final adjacent = await repo.tasksInRange(
        LocalDateRange.singleDay(d('2024-02-28')),
      );

      expect(leapDay, hasLength(1));
      expect(leapDay.single.scheduledDate!.iso, '2024-02-29');
      expect(adjacent, isEmpty);
    });

    test('时刻字段与日历日分离：createdAt 是 UTC 时刻，scheduledDate 是纯日期', () async {
      final task = await repo.createTask(
        PlannerTaskDraft(title: '任务', scheduledDate: d('2026-11-16')),
      );

      final raw = env.database.handle.select(
        'SELECT created_at, scheduled_date FROM planner_tasks WHERE id = ?',
        <Object?>[task.id],
      ).single;

      expect(raw['created_at'], endsWith('Z'));
      expect(raw['created_at'], isNot(contains('2026-11-16T00:00')));
      expect(raw['scheduled_date'], '2026-11-16');
      expect(LocalDate.parse(raw['scheduled_date'] as String), d('2026-11-16'));
    });
  });

  group('项目列表', () {
    test('默认过滤归档项目，includeArchived 时包含', () async {
      await repo.createProject(const ProjectDraft(name: '进行中'));
      await repo.createProject(
        const ProjectDraft(name: '已归档', status: ProjectStatus.archived),
      );

      final visible = await repo.watchProjects().first;
      final withArchived = await repo
          .watchProjects(includeArchived: true)
          .first;

      expect(visible.map((project) => project.name).toList(), <String>['进行中']);
      expect(withArchived.map((project) => project.name).toList(), <String>[
        '进行中',
        '已归档',
      ]);
    });

    test('sortOrder 升序优先，其次创建时间升序', () async {
      clock.advance(const Duration(seconds: 1));
      await repo.createProject(const ProjectDraft(name: '顺序2', sortOrder: 2));
      clock.advance(const Duration(seconds: 1));
      await repo.createProject(
        const ProjectDraft(name: '顺序1-后建', sortOrder: 1),
      );
      clock.advance(const Duration(seconds: 1));
      await repo.createProject(
        const ProjectDraft(name: '顺序1-先建', sortOrder: 1),
      );

      final projects = await repo.watchProjects().first;
      expect(projects.map((project) => project.name).toList(), <String>[
        '顺序1-后建',
        '顺序1-先建',
        '顺序2',
      ]);
    });
  });

  group('响应式流', () {
    test('任务流：订阅先推当前值，写入后再推新值', () async {
      final range = LocalDateRange.singleDay(d('2026-11-16'));
      expect(await repo.watchTasksInRange(range).first, isEmpty);

      final pushed = repo
          .watchTasksInRange(range)
          .firstWhere((tasks) => tasks.isNotEmpty);
      final created = await repo.createTask(
        PlannerTaskDraft(title: '新任务', scheduledDate: d('2026-11-16')),
      );

      final tasks = await pushed;
      expect(tasks.single.id, created.id);
    });

    test('项目流在删除后推送空列表', () async {
      final project = await repo.createProject(
        const ProjectDraft(name: '临时项目'),
      );
      final emptied = repo.watchProjects().firstWhere(
        (projects) => projects.isEmpty,
      );

      await repo.deleteProject(project.id);

      expect(await emptied, isEmpty);
    });

    test('每日备注流：先推 null，保存后推数据', () async {
      final date = d('2026-11-14');
      expect(await repo.watchDailyNote(date).first, isNull);

      final pushed = repo
          .watchDailyNote(date)
          .firstWhere((note) => note != null);
      await repo.saveDailyNote(date, body: '今日总结', focusItems: <String>['重点']);

      final note = await pushed;
      expect(note!.body, '今日总结');
      expect(note.focusItems, <String>['重点']);
    });

    test('单实体流：存在的实体推实体，不存在推 null', () async {
      final task = await repo.createTask(const PlannerTaskDraft(title: '任务'));
      expect(await repo.watchTask(task.id).first, task);
      expect(await repo.watchTask('not-exist').first, isNull);
      expect(await repo.watchSpan('not-exist').first, isNull);
    });

    test('返回的列表是只读的', () async {
      await repo.createTask(
        PlannerTaskDraft(title: '任务', scheduledDate: d('2026-11-16')),
      );
      final tasks = await repo.tasksInRange(
        LocalDateRange.singleDay(d('2026-11-16')),
      );

      expect(
        () => tasks.add(tasks.first),
        throwsUnsupportedError,
        reason: '流里推出去的集合不能被外部改动',
      );
    });
  });
}
