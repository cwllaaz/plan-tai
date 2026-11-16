import 'local_date.dart';
import 'planner_entity.dart';
import 'planner_exception.dart';
import 'time_slot.dart';
import 'validation.dart';

/// 任务优先级。数字越大越紧急，顺序稳定，可直接落库。
enum TaskPriority {
  low(0, '低'),
  normal(1, '普通'),
  high(2, '高'),
  urgent(3, '紧急');

  const TaskPriority(this.level, this.label);

  final int level;
  final String label;

  static TaskPriority fromLevel(int level) {
    for (final priority in TaskPriority.values) {
      if (priority.level == level) return priority;
    }
    throw PlannerValidationException('未知优先级：$level');
  }
}

/// 任务完成状态。注意「完成」不是删除：`done` 的任务仍留在当天。
enum TaskStatus {
  todo('待办'),
  done('已完成');

  const TaskStatus(this.label);

  final String label;
}

/// 某一天的一项具体任务。
///
/// 三个关键约定：
/// 1. [scheduledDate] 为 null 表示**未排期（收件箱）**，不属于任何一天；
/// 2. [timeSlot] 为 null 表示**当天没有固定时刻**（只排到日，不排到分）；
/// 3. 任务不能跨午夜——跨天的事情用 [PlanSpan] 表达。
final class PlannerTask extends PlannerEntity {
  PlannerTask({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    required super.revision,
    super.deletedAt,
    this.projectId,
    this.spanId,
    required String title,
    String notes = '',
    this.scheduledDate,
    this.timeSlot,
    this.priority = TaskPriority.normal,
    this.status = TaskStatus.todo,
    this.completedAt,
    this.sortOrder = 0,
  }) : title = requireText(title, field: '任务标题', maxLength: 200),
       notes = optionalText(notes, field: '任务备注', maxLength: 5000) {
    if (timeSlot != null && scheduledDate == null) {
      throw const PlannerValidationException('设置了时间区间的任务必须先指定日期');
    }
    if (spanId != null && projectId == null) {
      throw const PlannerValidationException('关联阶段的任务必须同时属于该项目');
    }
    if (completedAt != null && status != TaskStatus.done) {
      throw const PlannerValidationException('只有已完成的任务才能有完成时刻');
    }
  }

  /// null = 无项目（收件箱）。
  final String? projectId;

  /// null = 不属于任何阶段。
  final String? spanId;

  final String title;
  final String notes;

  /// null = 未排期。
  final LocalDate? scheduledDate;

  /// null = 当天无固定时刻。
  final TimeSlot? timeSlot;

  final TaskPriority priority;
  final TaskStatus status;

  /// 完成时刻（UTC）；仅当 [status] 为 done 时非 null。
  final DateTime? completedAt;

  final int sortOrder;

  bool get isDone => status == TaskStatus.done;

  bool get isUnscheduled => scheduledDate == null;

  bool get hasTime => timeSlot != null;

  /// 半开区间重叠判断；无时刻的任务永不重叠。
  bool overlapsTime(PlannerTask other) {
    final a = timeSlot;
    final b = other.timeSlot;
    if (a == null || b == null) return false;
    return a.overlaps(b);
  }

  PlannerTask copyWith({
    Object? projectId = unset,
    Object? spanId = unset,
    String? title,
    String? notes,
    Object? scheduledDate = unset,
    Object? timeSlot = unset,
    TaskPriority? priority,
    TaskStatus? status,
    Object? completedAt = unset,
    int? sortOrder,
    Object? deletedAt = unset,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? revision,
  }) {
    // 状态与完成时刻必须保持一致：改回 todo 时自动清空 completedAt。
    final nextStatus = status ?? this.status;
    final DateTime? nextCompletedAt;
    if (!identical(completedAt, unset)) {
      nextCompletedAt = completedAt as DateTime?;
    } else if (nextStatus == TaskStatus.done) {
      nextCompletedAt = this.completedAt;
    } else {
      nextCompletedAt = null;
    }

    return PlannerTask(
      id: id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      revision: revision ?? this.revision,
      deletedAt: identical(deletedAt, unset)
          ? this.deletedAt
          : deletedAt as DateTime?,
      projectId: identical(projectId, unset)
          ? this.projectId
          : projectId as String?,
      spanId: identical(spanId, unset) ? this.spanId : spanId as String?,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      scheduledDate: identical(scheduledDate, unset)
          ? this.scheduledDate
          : scheduledDate as LocalDate?,
      timeSlot: identical(timeSlot, unset)
          ? this.timeSlot
          : timeSlot as TimeSlot?,
      priority: priority ?? this.priority,
      status: nextStatus,
      completedAt: nextCompletedAt,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlannerTask &&
      baseEquals(other) &&
      projectId == other.projectId &&
      spanId == other.spanId &&
      title == other.title &&
      notes == other.notes &&
      scheduledDate == other.scheduledDate &&
      timeSlot == other.timeSlot &&
      priority == other.priority &&
      status == other.status &&
      completedAt == other.completedAt &&
      sortOrder == other.sortOrder;

  @override
  int get hashCode => Object.hash(
    baseHashCode(),
    projectId,
    spanId,
    title,
    notes,
    scheduledDate,
    timeSlot,
    priority,
    status,
    completedAt,
    sortOrder,
  );

  @override
  String toString() =>
      'PlannerTask($id, $title, ${scheduledDate?.iso ?? '未排期'})';
}

/// 新建任务的输入载荷。
///
/// [scheduledDate] 为 null 时创建的是收件箱任务；[timeSlot] 只能与日期同时出现。
final class PlannerTaskDraft {
  const PlannerTaskDraft({
    required this.title,
    this.projectId,
    this.spanId,
    this.notes = '',
    this.scheduledDate,
    this.timeSlot,
    this.priority = TaskPriority.normal,
    this.status = TaskStatus.todo,
    this.sortOrder = 0,
  });

  final String title;
  final String? projectId;
  final String? spanId;
  final String notes;
  final LocalDate? scheduledDate;
  final TimeSlot? timeSlot;
  final TaskPriority priority;
  final TaskStatus status;
  final int sortOrder;

  PlannerTaskDraft copyWith({
    String? title,
    Object? projectId = unset,
    Object? spanId = unset,
    String? notes,
    Object? scheduledDate = unset,
    Object? timeSlot = unset,
    TaskPriority? priority,
    TaskStatus? status,
    int? sortOrder,
  }) => PlannerTaskDraft(
    title: title ?? this.title,
    projectId: identical(projectId, unset)
        ? this.projectId
        : projectId as String?,
    spanId: identical(spanId, unset) ? this.spanId : spanId as String?,
    notes: notes ?? this.notes,
    scheduledDate: identical(scheduledDate, unset)
        ? this.scheduledDate
        : scheduledDate as LocalDate?,
    timeSlot: identical(timeSlot, unset)
        ? this.timeSlot
        : timeSlot as TimeSlot?,
    priority: priority ?? this.priority,
    status: status ?? this.status,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
