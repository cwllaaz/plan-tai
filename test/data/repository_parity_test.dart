import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/contracts/planner_repository.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';

import 'support/test_env.dart';

/// 把"用户能看到的结果"压成字符串列表，便于两种实现直接对比。
Future<List<String>> runScenario(PlannerRepository repo) async {
  final project = await repo.createProject(
    const ProjectDraft(name: '项目', sortOrder: 1),
  );
  final span = await repo.createSpan(
    PlanSpanDraft(
      projectId: project.id,
      title: '阶段',
      startDate: d('2026-11-03'),
      endDate: d('2026-11-07'),
    ),
  );
  final afternoon = await repo.createTask(
    PlannerTaskDraft(
      title: '下午低优先级',
      projectId: project.id,
      scheduledDate: d('2026-11-04'),
      timeSlot: TimeSlot.at(hour: 14),
      priority: TaskPriority.low,
      sortOrder: 2,
    ),
  );
  final morning = await repo.createTask(
    PlannerTaskDraft(
      title: '上午高优先级',
      projectId: project.id,
      spanId: span.id,
      scheduledDate: d('2026-11-04'),
      timeSlot: TimeSlot.at(hour: 9),
      priority: TaskPriority.high,
      sortOrder: 1,
    ),
  );
  final noTime = await repo.createTask(
    PlannerTaskDraft(
      title: '无时刻',
      projectId: project.id,
      scheduledDate: d('2026-11-04'),
      sortOrder: 3,
    ),
  );
  await repo.createTask(const PlannerTaskDraft(title: '收件箱'));
  await repo.saveDailyNote(
    d('2026-11-04'),
    body: '备注',
    focusItems: <String>['重点'],
  );

  final lines = <String>[];
  lines.add(
    'projects=${(await repo.watchProjects().first).map((project) => '${project.name}|${project.sortOrder}|${project.color.hex}').join(',')}',
  );
  lines.add(
    'tasks=${(await repo.watchAllTasks().first).map((task) => '${task.title}|${task.scheduledDate}|${task.timeSlot?.label}|${task.priority.name}|${task.status.name}').join(',')}',
  );
  lines.add(
    'range=${(await repo.tasksInRange(LocalDateRange.singleDay(d('2026-11-04')))).map((task) => task.title).join(',')}',
  );
  lines.add(
    'spans=${(await repo.watchSpansInRange(LocalDateRange(d('2026-11-01'), d('2026-11-30'))).first).map((span) => span.title).join(',')}',
  );
  lines.add(
    'note=${(await repo.findDailyNote(d('2026-11-04')))?.body}|${(await repo.findDailyNote(d('2026-11-04')))?.focusItems.join('/')}',
  );

  final done = await repo.updateTask(noTime.copyWith(status: TaskStatus.done));
  lines.add(
    'done=${done.status.name}|${done.completedAt != null}|${done.revision}',
  );

  final undone = await repo.updateTask(done.copyWith(status: TaskStatus.todo));
  lines.add('undone=${undone.completedAt == null}|${undone.revision}');

  await repo.deleteSpan(span.id);
  final afterSpanDelete = (await repo.findTask(morning.id))!;
  lines.add(
    'afterSpanDelete=${afterSpanDelete.spanId == null}|${afterSpanDelete.revision}|${afterSpanDelete.title}',
  );

  await repo.deleteProject(project.id);
  lines.add(
    'afterProjectDelete=${(await repo.watchAllTasks().first).map((task) => task.title).join(',')}',
  );
  lines.add('remainingProjects=${(await repo.watchProjects().first).length}');
  lines.add('afternoonVisible=${await repo.findTask(afternoon.id) != null}');
  return lines;
}

void main() {
  test('SQLite 仓储与内存仓储行为一致：排序 / 完成 / 软删除 / 级联', () async {
    final clock = FakeClock();
    final env = TestEnv.create(clock: clock.now);
    try {
      final inMemory = InMemoryPlannerRepository(clock: clock.now);
      final memoryResult = await runScenario(inMemory);
      final sqliteResult = await runScenario(env.repository);

      expect(sqliteResult, memoryResult, reason: '两种实现必须给出同样的结果');
    } finally {
      await env.dispose();
    }
  });

  test('乐观并发在两种实现上给出同样的冲突信息', () async {
    final clock = FakeClock();
    final env = TestEnv.create(clock: clock.now);
    try {
      Future<List<Object?>> conflictOf(PlannerRepository repo) async {
        final project = await repo.createProject(
          const ProjectDraft(name: '项目'),
        );
        await repo.updateProject(project.copyWith(name: '第一次'));
        try {
          await repo.updateProject(project.copyWith(name: '用旧版本覆盖'));
          return <Object?>['没有抛异常'];
        } on PlannerConflictException catch (error) {
          return <Object?>[
            error.runtimeType.toString(),
            error.expected,
            error.actual,
          ];
        }
      }

      expect(
        await conflictOf(env.repository),
        await conflictOf(InMemoryPlannerRepository(clock: clock.now)),
      );
    } finally {
      await env.dispose();
    }
  });
}
