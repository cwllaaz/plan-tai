import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/features/day_detail/day_detail_math.dart';

PlannerTask _task({
  String id = 't1',
  String title = '任务',
  int? hour,
  int durationMinutes = 30,
  TaskPriority priority = TaskPriority.normal,
  TaskStatus status = TaskStatus.todo,
  LocalDate? date,
}) {
  final now = DateTime.utc(2026, 11, 14, 1);
  return PlannerTask(
    id: id,
    createdAt: now,
    updatedAt: now,
    revision: 1,
    title: title,
    scheduledDate: date ?? LocalDate(2026, 11, 14),
    timeSlot: hour == null
        ? null
        : TimeSlot.at(hour: hour, durationMinutes: durationMinutes),
    priority: priority,
    status: status,
    completedAt: status == TaskStatus.done ? now : null,
  );
}

void main() {
  group('computeDayTaskStats', () {
    test('没有任务时是 0/0、0%', () {
      final stats = computeDayTaskStats(const <PlannerTask>[]);
      expect(stats.total, 0);
      expect(stats.done, 0);
      expect(stats.ratio, 0);
      expect(stats.percent, 0);
      expect(stats.allDone, isFalse);
      expect(stats.countLabel, '完成 0/0');
      expect(stats.summaryLabel, '完成 0/0 · 0%');
    });

    test('按完成状态统计并四舍五入百分比', () {
      final tasks = <PlannerTask>[
        _task(id: 'a', status: TaskStatus.done),
        _task(id: 'b', status: TaskStatus.done),
        _task(id: 'c'),
      ];
      final stats = computeDayTaskStats(tasks);
      expect(stats.total, 3);
      expect(stats.done, 2);
      expect(stats.remaining, 1);
      expect(stats.percent, 67);
      expect(stats.countLabel, '完成 2/3');
      expect(stats.allDone, isFalse);
    });

    test('全部完成时 allDone 为 true', () {
      final stats = computeDayTaskStats(<PlannerTask>[
        _task(id: 'a', status: TaskStatus.done),
      ]);
      expect(stats.allDone, isTrue);
      expect(stats.percent, 100);
    });
  });

  group('任务分组', () {
    test('有时间的进时间轴，无时间的进「未安排」', () {
      final tasks = <PlannerTask>[
        _task(id: 'a', hour: 9),
        _task(id: 'b'),
        _task(id: 'c', hour: 14),
      ];
      expect(timedTasksOf(tasks).map((task) => task.id), <String>['a', 'c']);
      expect(untimedTasksOf(tasks).map((task) => task.id), <String>['b']);
    });
  });

  group('formatMinuteOfDay', () {
    test('补零并处理边界', () {
      expect(formatMinuteOfDay(0), '00:00');
      expect(formatMinuteOfDay(9 * 60 + 5), '09:05');
      expect(formatMinuteOfDay(23 * 60 + 59), '23:59');
      expect(formatMinuteOfDay(1440), '24:00');
      expect(formatMinuteOfDay(-5), '00:00');
    });
  });

  group('parseTimeOfDay', () {
    test('接受常见写法', () {
      expect(parseTimeOfDay('9:00'), 540);
      expect(parseTimeOfDay('09:00'), 540);
      expect(parseTimeOfDay(' 09：30 '), 570); // 全角冒号
      expect(parseTimeOfDay('9'), 540);
      expect(parseTimeOfDay('23:59'), 1439);
    });

    test('拒绝非法输入', () {
      expect(parseTimeOfDay(''), isNull);
      expect(parseTimeOfDay('24:00'), isNull);
      expect(parseTimeOfDay('9:60'), isNull);
      expect(parseTimeOfDay('abc'), isNull);
      expect(parseTimeOfDay('9:00:00'), isNull);
      expect(parseTimeOfDay('25'), isNull);
    });
  });

  group('validateTimeInputs', () {
    test('合法区间返回 null', () {
      expect(validateTimeInputs(startText: '09:00', endText: '10:30'), isNull);
    });

    test('结束早于或等于开始都报错', () {
      expect(
        validateTimeInputs(startText: '10:00', endText: '09:00'),
        '结束时间必须晚于开始时间',
      );
      expect(
        validateTimeInputs(startText: '10:00', endText: '10:00'),
        '结束时间必须晚于开始时间',
      );
    });

    test('格式错误给出输入提示', () {
      expect(
        validateTimeInputs(startText: '十点', endText: '10:00'),
        '开始时间格式应为 09:00',
      );
      expect(
        validateTimeInputs(startText: '10:00', endText: ''),
        '结束时间格式应为 09:00',
      );
    });
  });

  group('timeSlotFromInputs', () {
    test('转换出开始分钟与持续时长', () {
      final slot = timeSlotFromInputs(startText: '09:15', endText: '10:45');
      expect(slot.startMinute, 555);
      expect(slot.durationMinutes, 90);
      expect(slot.label, '09:15–10:45');
    });

    test('非法输入抛 PlannerValidationException', () {
      expect(
        () => timeSlotFromInputs(startText: '10:00', endText: '09:00'),
        throwsA(isA<PlannerValidationException>()),
      );
    });
  });

  group('defaultEndTimeText', () {
    test('默认顺延 30 分钟', () {
      expect(defaultEndTimeText('09:00'), '09:30');
      expect(defaultEndTimeText('9:45'), '10:15');
    });

    test('跨到 23:59 上限时不越界', () {
      expect(defaultEndTimeText('23:50'), '23:59');
    });
  });

  group('overlappingTasks', () {
    test('检测真正重叠，相邻不算', () {
      final target = _task(
        id: 'a',
        hour: 9,
        durationMinutes: 60,
      ); // 09:00–10:00
      final tasks = <PlannerTask>[
        target,
        _task(id: 'b', hour: 9, durationMinutes: 30), // 09:00–09:30
        _task(id: 'c', hour: 10, durationMinutes: 30), // 10:00 紧接，不算
        _task(id: 'd'), // 无时间，永不重叠
      ];
      final overlaps = overlappingTasks(target, tasks);
      expect(overlaps.map((task) => task.id), <String>['b']);
    });

    test('没有时刻的任务不参与重叠', () {
      final target = _task(id: 'a');
      expect(overlappingTasks(target, <PlannerTask>[target]), isEmpty);
    });

    test('提示文案包含对方时间与标题', () {
      final target = _task(id: 'a', hour: 9, durationMinutes: 60);
      final other = _task(id: 'b', title: '周会', hour: 9, durationMinutes: 30);
      expect(overlapHint(target, other), '与你 09:00–09:30「周会」的安排重叠');
    });
  });
}
