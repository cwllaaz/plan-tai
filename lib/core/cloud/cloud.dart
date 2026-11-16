/// 云同步公共契约的唯一入口。
///
/// UI / 测试只 import 这个文件，不直接依赖任何 HTTP、PocketBase 或 SQLite 实现。
library;

export 'cloud_services.dart';
export 'cloud_types.dart';
export 'fake_cloud_services.dart';
