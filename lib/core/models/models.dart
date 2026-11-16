/// 公共业务模型统一出口。
///
/// **冻结约定**：本目录（lib/core/models/）由维护者维护。
/// 三个并行 Agent 不得修改这些文件；确需变更（加字段、改语义）必须提给维护者，
/// 模型是跨平台契约，修改需同步更新文档与测试。
library;

export 'daily_note.dart';
export 'ids.dart';
export 'local_date.dart';
export 'local_date_range.dart';
export 'plan_span.dart';
export 'planner_entity.dart';
export 'planner_exception.dart';
export 'planner_task.dart';
export 'project.dart';
export 'project_color.dart';
export 'time_slot.dart';
export 'validation.dart' show unset;
