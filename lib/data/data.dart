/// 本地数据层统一出口。
///
/// 对上层只暴露：正式仓储 [SqlitePlannerRepository]（实现 `PlannerRepository`）、
/// 数据库门面 [PlannerDatabase]、备份服务 [BackupService]、路径规则
/// [PlannerPaths] 与错误类型。
///
/// 快速开始：
/// ```dart
/// final repository = SqlitePlannerRepository.open(); // %APPDATA%\计划台\data\app.db
/// final backups = BackupService(repository);
/// // ... 界面退出时
/// await repository.close();
/// ```
library;

export 'backup_service.dart';
export 'cloud/cloud.dart';
export 'data_exception.dart';
export 'entity_codec.dart';
export 'planner_database.dart';
export 'planner_paths.dart';
export 'sql_schema.dart';
export 'sqlite_planner_repository.dart';
export 'sync/sync.dart';
