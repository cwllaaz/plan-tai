import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';

void main() {
  final createdAt = DateTime.utc(2026, 11, 1, 8);
  final updatedAt = DateTime.utc(2026, 11, 2, 9);

  group('TimeSlot', () {
    test('区间合法性与标签', () {
      final slot = TimeSlot.at(hour: 9, minute: 30, durationMinutes: 75);
      expect(slot.startMinute, 570);
      expect(slot.endMinute, 645);
      expect(slot.label, '09:30–10:45');
      expect(slot.startLabel, '09:30');
      expect(slot.endLabel, '10:45');
    });

    test('跨午夜被拒绝', () {
      expect(
        () => TimeSlot(startMinute: 23 * 60, durationMinutes: 120),
        throwsA(isA<PlannerValidationException>()),
      );
      expect(
        () => TimeSlot.at(hour: 24),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('结束于 24:00 的边界', () {
      final slot = TimeSlot.startEnd(startMinute: 23 * 60, endMinute: 24 * 60);
      expect(slot.endLabel, '24:00');
    });

    test('重叠是半开区间，首尾相接不算重叠', () {
      final a = TimeSlot.at(hour: 9, durationMinutes: 60); // 09:00-10:00
      final b = TimeSlot.at(hour: 10, durationMinutes: 60); // 10:00-11:00
      final c = TimeSlot.at(hour: 9, minute: 30, durationMinutes: 30);
      expect(a.overlaps(b), isFalse);
      expect(a.overlaps(c), isTrue);
      expect(a.overlaps(a), isTrue);
    });

    test('相等与 copyWith', () {
      final slot = TimeSlot.at(hour: 9, durationMinutes: 60);
      expect(slot == TimeSlot.at(hour: 9, durationMinutes: 60), isTrue);
      expect(slot.copyWith(durationMinutes: 30).label, '09:00–09:30');
    });
  });

  group('ProjectColor', () {
    test('十六进制解析与输出', () {
      final color = ProjectColor.fromHex('#3e63dd');
      expect(color.rgb, 0x3E63DD);
      expect(color.hex, '#3E63DD');
      expect(ProjectColor.fromRgb(0x3E63DD), color);
    });

    test('非法颜色被拒绝', () {
      for (final bad in <String>['#FFF', '3E63DD', '#GGGGGG', '#3E63DD00']) {
        expect(
          () => ProjectColor.fromHex(bad),
          throwsA(isA<PlannerValidationException>()),
          reason: bad,
        );
      }
    });

    test('默认色板有 8 色且按数量轮转', () {
      expect(ProjectColor.palette.length, 8);
      expect(ProjectColor.suggestFor(0), ProjectColor.blue);
      expect(ProjectColor.suggestFor(8), ProjectColor.blue);
      expect(ProjectColor.suggestFor(3), ProjectColor.amber);
    });
  });

  group('Project', () {
    test('名称去空白并校验长度', () {
      final project = Project(
        id: 'p1',
        createdAt: createdAt,
        updatedAt: updatedAt,
        revision: 1,
        name: '  官网改版  ',
      );
      expect(project.name, '官网改版');
      expect(project.status, ProjectStatus.active);
      expect(project.color, ProjectColor.blue);
      expect(
        () => Project(
          id: 'p2',
          createdAt: createdAt,
          updatedAt: updatedAt,
          revision: 1,
          name: '   ',
        ),
        throwsA(isA<PlannerValidationException>()),
      );
      expect(
        () => Project(
          id: 'p3',
          createdAt: createdAt,
          updatedAt: updatedAt,
          revision: 1,
          name: 'x' * 81,
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('copyWith 保留 id 与同步字段，可切换归档', () {
      final project = Project(
        id: 'p1',
        createdAt: createdAt,
        updatedAt: updatedAt,
        revision: 3,
        name: '官网改版',
        color: ProjectColor.teal,
      );
      final archived = project.copyWith(status: ProjectStatus.archived);
      expect(archived.id, 'p1');
      expect(archived.revision, 3);
      expect(archived.isArchived, isTrue);
      expect(archived.color, ProjectColor.teal);
      expect(archived.copyWith(deletedAt: updatedAt).isDeleted, isTrue);
    });
  });

  group('PlanSpan', () {
    test('闭区间天数与覆盖判断', () {
      final span = PlanSpan(
        id: 's1',
        createdAt: createdAt,
        updatedAt: updatedAt,
        revision: 1,
        projectId: 'p1',
        title: '信息架构',
        startDate: LocalDate(2026, 11, 3),
        endDate: LocalDate(2026, 11, 7),
      );
      expect(span.lengthInDays, 5);
      expect(span.covers(LocalDate(2026, 11, 3)), isTrue);
      expect(span.covers(LocalDate(2026, 11, 7)), isTrue);
      expect(span.covers(LocalDate(2026, 11, 8)), isFalse);
      expect(
        span.overlaps(
          LocalDateRange(LocalDate(2026, 11, 7), LocalDate(2026, 11, 9)),
        ),
        isTrue,
      );
    });

    test('结束日早于开始日被拒绝', () {
      expect(
        () => PlanSpan(
          id: 's1',
          createdAt: createdAt,
          updatedAt: updatedAt,
          revision: 1,
          projectId: 'p1',
          title: '错误区间',
          startDate: LocalDate(2026, 11, 7),
          endDate: LocalDate(2026, 11, 3),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('跨度不能超过 366 天', () {
      expect(
        () => PlanSpan(
          id: 's1',
          createdAt: createdAt,
          updatedAt: updatedAt,
          revision: 1,
          projectId: 'p1',
          title: '太长',
          startDate: LocalDate(2026, 1, 1),
          endDate: LocalDate(2027, 1, 2),
        ),
        throwsA(isA<PlannerValidationException>()),
      );
    });
  });

  group('PlannerTask', () {
    PlannerTask build({
      String title = '写方案',
      String? projectId,
      String? spanId,
      LocalDate? scheduledDate,
      TimeSlot? timeSlot,
      TaskStatus status = TaskStatus.todo,
      DateTime? completedAt,
    }) => PlannerTask(
      id: 't1',
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: 1,
      projectId: projectId,
      spanId: spanId,
      title: title,
      scheduledDate: scheduledDate,
      timeSlot: timeSlot,
      status: status,
      completedAt: completedAt,
    );

    test('有时间的任务必须有日期', () {
      expect(
        () => build(timeSlot: TimeSlot.at(hour: 9)),
        throwsA(isA<PlannerValidationException>()),
      );
      final task = build(
        scheduledDate: LocalDate(2026, 11, 14),
        timeSlot: TimeSlot.at(hour: 9),
      );
      expect(task.hasTime, isTrue);
      expect(task.isUnscheduled, isFalse);
    });

    test('关联阶段必须同时有项目', () {
      expect(
        () => build(spanId: 's1'),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('完成时刻只能出现在已完成任务上', () {
      expect(
        () => build(completedAt: updatedAt),
        throwsA(isA<PlannerValidationException>()),
      );
      final done = build(status: TaskStatus.done, completedAt: updatedAt);
      expect(done.isDone, isTrue);
    });

    test('copyWith 能把可空字段显式置空', () {
      final task = build(
        projectId: 'p1',
        scheduledDate: LocalDate(2026, 11, 14),
        timeSlot: TimeSlot.at(hour: 9, durationMinutes: 60),
      );
      final moved = task.copyWith(
        projectId: null,
        scheduledDate: null,
        timeSlot: null,
      );
      expect(moved.projectId, isNull);
      expect(moved.scheduledDate, isNull);
      expect(moved.hasTime, isFalse);
      expect(moved.id, task.id);
    });

    test('重叠判断忽略无时刻任务', () {
      final a = build(
        scheduledDate: LocalDate(2026, 11, 14),
        timeSlot: TimeSlot.at(hour: 9, durationMinutes: 60),
      );
      final b = build(
        scheduledDate: LocalDate(2026, 11, 14),
        timeSlot: TimeSlot.at(hour: 9, minute: 30, durationMinutes: 60),
      );
      final c = build(scheduledDate: LocalDate(2026, 11, 14));
      expect(a.overlapsTime(b), isTrue);
      expect(a.overlapsTime(c), isFalse);
    });
  });

  group('DailyNote', () {
    DailyNote note({
      String body = '',
      List<String> focusItems = const <String>[],
    }) => DailyNote(
      id: 'n1',
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: 1,
      date: LocalDate(2026, 11, 14),
      body: body,
      focusItems: focusItems,
    );

    test('当日重点去空白、去空串、最多 3 条', () {
      final parsed = note(focusItems: <String>['  评审  ', '', '写代码']);
      expect(parsed.focusItems, <String>['评审', '写代码']);
      expect(
        () => note(focusItems: <String>['1', '2', '3', '4']),
        throwsA(isA<PlannerValidationException>()),
      );
      expect(
        () => note(focusItems: <String>['x' * 61]),
        throwsA(isA<PlannerValidationException>()),
      );
    });

    test('focusItems 不可变', () {
      final parsed = note(focusItems: const <String>['评审']);
      expect(() => parsed.focusItems.add('x'), throwsUnsupportedError);
    });

    test('isEmpty 判断', () {
      expect(note().isEmpty, isTrue);
      expect(note(body: '有内容').isEmpty, isFalse);
      expect(note(focusItems: const <String>['重点']).isEmpty, isFalse);
    });
  });
}
