import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/planner_paths.dart';

/// 各平台「用户级应用数据基目录」与「临时目录」的解析入口（平台适配层，**接口已冻结**）。
///
/// 桌面端沿用 [PlannerPaths.defaultBaseDirectory]（`%APPDATA%\计划台` 等），
/// 行为与 V1/V2 完全一致；Android 上应用私有目录只能通过平台通道异步获取，
/// 因此新增 [resolveBaseDirectory] 这一异步入口。
///
/// 约定：
/// - 只返回**基目录**（不含 `data` 子目录）；数据子目录由 [PlannerPaths] 拼接，
///   这样桌面端与移动端目录结构保持同构：`<base>/data/app.db`、`<base>/data/backups`。
/// - Android 使用 `getApplicationSupportDirectory()`（应用私有、无需存储权限、
///   卸载即清除、**不会被系统当作缓存清理**）。**不要**改用外部存储或缓存目录：
///   前者需要权限且会被用户清理，后者会被系统随时回收。
/// - 解析失败必须抛出可读异常，不得静默退回临时目录。
/// - 临时目录（[resolveScratchDirectory]）只用于**一次性的导入副本 / 导出中转**，
///   绝不能用于存放数据库或备份原件。
abstract final class AppPaths {
  /// Android 上 `getApplicationSupportDirectory()` 对应的私有文件目录名（仅诊断用）。
  static const String androidFilesDirectoryLabel = 'filesDir';

  /// 解析当前平台的基目录。调用方随后应执行
  /// `PlannerPaths.useBaseDirectory(await AppPaths.resolveBaseDirectory())`。
  static Future<String> resolveBaseDirectory() async {
    if (Platform.isAndroid) return _resolveAndroidBaseDirectory();
    return PlannerPaths.defaultBaseDirectory();
  }

  /// 临时中转目录（缓存）：
  /// - Android：`getTemporaryDirectory()`（`/data/.../cache`，系统可回收）；
  /// - 桌面/测试：系统临时目录下的 `jihuatai-scratch`。
  ///
  /// 只允许放「导入备份的副本」「待导出字节」这类**可随时丢弃**的文件。
  static Future<String> resolveScratchDirectory() async {
    final Directory temp;
    if (Platform.isAndroid) {
      temp = await getTemporaryDirectory();
    } else {
      temp = Directory.systemTemp;
    }
    final directory = Directory(p.join(temp.path, 'jihuatai-scratch'));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return directory.path;
  }

  /// 判断某个目录是否属于「系统可回收 / 缓存」位置。
  ///
  /// 用于在打开数据库前做最后一道防线：Android 上如果基目录落在 cache/temp 里，
  /// 说明注入逻辑被改坏了，必须直接失败而不是把用户数据写进会被清理的目录。
  /// 该方法只做纯路径判断，可在任意平台单测。
  static bool isEphemeralDirectory(String directoryPath) {
    final trimmed = directoryPath.trim();
    if (trimmed.isEmpty) return true;
    final normalized = p.normalize(trimmed);
    if (normalized.isEmpty || normalized == '.') return true;
    // 同时按 Windows 反斜杠与 POSIX 斜杠切分：该判断需要在任意平台上
    // 对任意平台的路径串给出稳定结果（测试会喂 Windows 路径给 Linux 运行）。
    final segments = normalized
        .split(RegExp(r'[\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .map((segment) => segment.toLowerCase())
        .toList(growable: false);
    const ephemeralSegments = <String>{
      'cache',
      'caches',
      'cache2',
      'code_cache',
      'temp',
      'tmp',
      'no_backup',
    };
    if (segments.any(ephemeralSegments.contains)) return true;
    // Android 的外部缓存目录（/storage/emulated/0/Android/data/<pkg>/cache）
    if (normalized.toLowerCase().contains('/android/data/')) return true;
    return false;
  }

  static Future<String> _resolveAndroidBaseDirectory() async {
    try {
      final directory = await getApplicationSupportDirectory();
      if (directory.path.trim().isEmpty) {
        throw StateError('应用私有目录返回了空路径');
      }
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      return directory.path;
    } on Object catch (error) {
      throw StateError('无法获取 Android 应用私有目录：$error');
    }
  }
}
