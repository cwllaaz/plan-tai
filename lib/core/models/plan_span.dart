import 'local_date.dart';
import 'local_date_range.dart';
import 'planner_entity.dart';
import 'planner_exception.dart';
import 'project_color.dart';
import 'validation.dart';

/// 跨天阶段（阶段 / 安排）的状态。
enum PlanSpanStatus {
  planned('计划中'),
  doing('进行中'),
  done('已完成'),
  dropped('已放弃');

  const PlanSpanStatus(this.label);

  final String label;
}

/// 跨多天的项目阶段，例如「11 月 3 日 ~ 11 月 7 日：信息架构评审」。
///
/// 它**不是任务**：任务属于某一天（可带时刻），阶段是连续的一段日历区间，
/// 在月历上被渲染成跨格彩条。日期用闭区间：[startDate] 与 [endDate] 都包含，
/// 3 日~7 日是 5 天。
final class PlanSpan extends PlannerEntity {
  PlanSpan({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    required super.revision,
    super.deletedAt,
    required String projectId,
    required String title,
    required this.startDate,
    required this.endDate,
    this.status = PlanSpanStatus.planned,
    String description = '',
    this.color,
    this.sortOrder = 0,
  }) : projectId = requireText(projectId, field: '项目 ID', maxLength: 64),
       title = requireText(title, field: '阶段标题', maxLength: 120),
       description = optionalText(description, field: '阶段描述', maxLength: 2000) {
    if (endDate.isBefore(startDate)) {
      throw PlannerValidationException(
        '阶段结束日 ${endDate.iso} 不能早于开始日 ${startDate.iso}',
      );
    }
    if (lengthInDays > 366) {
      throw const PlannerValidationException('单条阶段跨度不能超过 366 天');
    }
  }

  final String projectId;
  final String title;

  /// 起始日，包含。
  final LocalDate startDate;

  /// 结束日，包含。
  final LocalDate endDate;

  final PlanSpanStatus status;
  final String description;

  /// null 表示继承项目颜色。
  final ProjectColor? color;

  /// 同一天多条阶段时的排序权重。
  final int sortOrder;

  /// 包含首尾的总天数。
  int get lengthInDays => endDate.differenceInDays(startDate) + 1;

  LocalDateRange get range => LocalDateRange(startDate, endDate);

  bool covers(LocalDate date) => date.isWithin(startDate, endDate);

  bool overlaps(LocalDateRange range) => this.range.overlaps(range);

  PlanSpan copyWith({
    String? projectId,
    String? title,
    LocalDate? startDate,
    LocalDate? endDate,
    PlanSpanStatus? status,
    String? description,
    Object? color = unset,
    int? sortOrder,
    Object? deletedAt = unset,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? revision,
  }) => PlanSpan(
    id: id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    revision: revision ?? this.revision,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
    projectId: projectId ?? this.projectId,
    title: title ?? this.title,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    status: status ?? this.status,
    description: description ?? this.description,
    color: identical(color, unset) ? this.color : color as ProjectColor?,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  @override
  bool operator ==(Object other) =>
      other is PlanSpan &&
      baseEquals(other) &&
      projectId == other.projectId &&
      title == other.title &&
      startDate == other.startDate &&
      endDate == other.endDate &&
      status == other.status &&
      description == other.description &&
      color == other.color &&
      sortOrder == other.sortOrder;

  @override
  int get hashCode => Object.hash(
    baseHashCode(),
    projectId,
    title,
    startDate,
    endDate,
    status,
    description,
    color,
    sortOrder,
  );

  @override
  String toString() => 'PlanSpan($id, $title, ${range.toString()})';
}

/// 新建跨天阶段的输入载荷。
final class PlanSpanDraft {
  const PlanSpanDraft({
    required this.projectId,
    required this.title,
    required this.startDate,
    required this.endDate,
    this.status = PlanSpanStatus.planned,
    this.description = '',
    this.color,
    this.sortOrder = 0,
  });

  final String projectId;
  final String title;
  final LocalDate startDate;
  final LocalDate endDate;
  final PlanSpanStatus status;
  final String description;
  final ProjectColor? color;
  final int sortOrder;
}
