/// 平台适配层统一出口。
///
/// 只放「与平台相关、但业务无关」的能力：
/// - 私有目录 / 临时目录解析（[AppPaths]）；
/// - Android 本地数据库初始化与生命周期（[AndroidDatabaseHost]、[PlannerLifecycleGuard]）；
/// - Android 文件选择（SAF）与备份导出/导入（[AndroidStorageChannel]、
///   [AndroidBackupTransfer]）；
/// - 原生内存压力通道（[AndroidMemoryPressureChannel]）。
///
/// 业务数据只通过 `PlannerRepository` 流动；本层不得引入第二套任务/项目模型。
library;

export 'android_backup.dart';
export 'android_database_host.dart';
export 'android_memory_channel.dart';
export 'android_storage.dart';
export 'app_paths.dart';
export 'planner_lifecycle.dart';
