import 'planner_entity.dart';
import 'project_color.dart';
import 'validation.dart';

/// 项目状态。归档项目默认不出现在侧栏与选择器中。
enum ProjectStatus {
  active('进行中'),
  paused('已暂停'),
  archived('已归档');

  const ProjectStatus(this.label);

  final String label;

  bool get isArchived => this == ProjectStatus.archived;
}

/// 项目：任务的归属单元，也是月历上颜色的来源。
final class Project extends PlannerEntity {
  Project({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    required super.revision,
    super.deletedAt,
    required String name,
    String description = '',
    this.color = ProjectColor.blue,
    this.status = ProjectStatus.active,
    this.sortOrder = 0,
  }) : name = requireText(name, field: '项目名称', maxLength: 80),
       description = optionalText(description, field: '项目描述', maxLength: 2000);

  final String name;
  final String description;
  final ProjectColor color;
  final ProjectStatus status;
  final int sortOrder;

  bool get isArchived => status.isArchived;

  Project copyWith({
    String? name,
    String? description,
    ProjectColor? color,
    ProjectStatus? status,
    int? sortOrder,
    Object? deletedAt = unset,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? revision,
  }) => Project(
    id: id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    revision: revision ?? this.revision,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
    name: name ?? this.name,
    description: description ?? this.description,
    color: color ?? this.color,
    status: status ?? this.status,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  @override
  bool operator ==(Object other) =>
      other is Project &&
      baseEquals(other) &&
      name == other.name &&
      description == other.description &&
      color == other.color &&
      status == other.status &&
      sortOrder == other.sortOrder;

  @override
  int get hashCode =>
      Object.hash(baseHashCode(), name, description, color, status, sortOrder);

  @override
  String toString() => 'Project($id, $name)';
}

/// 新建项目的输入载荷。
///
/// 仓储负责填写 id / createdAt / updatedAt / revision / deletedAt，调用方不构造实体。
final class ProjectDraft {
  const ProjectDraft({
    required this.name,
    this.description = '',
    this.color,
    this.status = ProjectStatus.active,
    this.sortOrder = 0,
  });

  final String name;
  final String description;

  /// null 表示由仓储按色板自动分配。
  final ProjectColor? color;
  final ProjectStatus status;
  final int sortOrder;
}
