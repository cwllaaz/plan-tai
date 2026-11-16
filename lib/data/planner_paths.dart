import 'dart:io';

import 'package:path/path.dart' as p;

import 'data_exception.dart';

/// 正式数据的落盘位置规则（见 docs/DATA_CONTRACT.md §10）。
///
/// 规则：**永远不写工作目录、不写临时目录、不写安装目录**（安装目录会被升级
/// 覆盖）。Windows 上固定为
/// `%APPDATA%\计划台\data\app.db`，备份放在同级 `backups\`。
///
/// 需要便携模式或测试隔离时，用环境变量 `JIHUATAI_DATA_DIR` 覆盖基目录，
/// 或者直接给 [PlannerDatabase.open] 传 `path`。
abstract final class PlannerPaths {
  /// 用户应用数据目录下的应用文件夹名（与窗口标题、产品名一致）。
  static const String appFolder = '计划台';

  /// 数据子目录。
  static const String dataFolder = 'data';

  /// 数据库文件名。
  static const String databaseFileName = 'app.db';

  /// 备份子目录名。
  static const String backupsFolder = 'backups';

  /// 覆盖基目录的环境变量（便携模式 / 自动化测试）。
  static const String dataDirectoryOverrideVariable = 'JIHUATAI_DATA_DIR';

  /// 运行期注入的基目录。
  ///
  /// 移动端（Android）没有 `%APPDATA%` 这类环境变量，应用私有目录只能异步
  /// 通过平台通道拿到（`path_provider`）。启动时先解析、再调用
  /// [useBaseDirectory] 注入，之后所有同步 API（数据库、备份、设置页）
  /// 都能照常工作。
  ///
  /// 优先级：环境变量 > 运行期注入 > 平台默认位置。只应在打开数据库前设置一次。
  static String? _baseDirectoryOverride;

  /// 注入基目录；传 null 清除。返回是否发生了变化。
  static bool useBaseDirectory(String? path) {
    final normalized = _firstNonEmpty(<String?>[path]);
    if (_baseDirectoryOverride == normalized) return false;
    _baseDirectoryOverride = normalized;
    return true;
  }

  /// 当前运行期注入的基目录（仅供诊断/测试）。
  static String? get baseDirectoryOverride => _baseDirectoryOverride;

  /// 用户级应用数据基目录（不含 `data` 子目录）。
  ///
  /// 顺序：`JIHUATAI_DATA_DIR` → [useBaseDirectory] 注入值 → 平台默认位置。
  /// 取不到时**抛异常而不是退到临时目录**，避免真实数据落进会被清理的位置。
  static String defaultBaseDirectory({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final override = _firstNonEmpty(<String?>[
      env[dataDirectoryOverrideVariable],
    ]);
    if (override != null) return p.normalize(override);

    final injected = _firstNonEmpty(<String?>[_baseDirectoryOverride]);
    if (injected != null) return p.normalize(injected);

    if (Platform.isWindows) {
      final appData = _firstNonEmpty(<String?>[
        env['APPDATA'],
        env['LOCALAPPDATA'],
      ]);
      if (appData != null) return p.join(appData, appFolder);
      final profile = _firstNonEmpty(<String?>[env['USERPROFILE']]);
      if (profile != null) {
        return p.join(profile, 'AppData', 'Roaming', appFolder);
      }
    } else if (Platform.isMacOS) {
      final home = _firstNonEmpty(<String?>[env['HOME']]);
      if (home != null) {
        return p.join(home, 'Library', 'Application Support', appFolder);
      }
    } else if (Platform.isLinux) {
      final xdg = _firstNonEmpty(<String?>[env['XDG_DATA_HOME']]);
      if (xdg != null) return p.join(xdg, appFolder);
      final home = _firstNonEmpty(<String?>[env['HOME']]);
      if (home != null) return p.join(home, '.local', 'share', appFolder);
    } else if (Platform.isAndroid) {
      // Android 的私有目录必须由 path_provider 异步取得，这里拿不到就明确失败，
      // 绝不猜测路径或退回临时目录（会被系统清理）。
      throw const LocalDatabaseException(
        'Android 上尚未初始化应用私有目录：请在启动时先调用 '
        'AppPaths.resolveBaseDirectory() 再调用 '
        'PlannerPaths.useBaseDirectory(...)，然后打开数据库。',
      );
    }

    throw const LocalDatabaseException(
      '无法确定本机的用户应用数据目录，已停止创建数据库。'
      '请设置环境变量 ${PlannerPaths.dataDirectoryOverrideVariable} 后重试。',
    );
  }

  /// `%APPDATA%\计划台\data`。
  static String defaultDataDirectory({Map<String, String>? environment}) =>
      p.join(defaultBaseDirectory(environment: environment), dataFolder);

  /// `%APPDATA%\计划台\data\app.db`。
  static String defaultDatabasePath({Map<String, String>? environment}) =>
      p.join(defaultDataDirectory(environment: environment), databaseFileName);

  /// `%APPDATA%\计划台\data\backups`。
  static String defaultBackupDirectory({Map<String, String>? environment}) =>
      p.join(defaultDataDirectory(environment: environment), backupsFolder);

  /// 创建目录（含父级）并返回路径。
  static String ensureDirectory(String directoryPath) {
    Directory(directoryPath).createSync(recursive: true);
    return directoryPath;
  }

  /// 创建文件所在目录（含父级）并返回文件路径。
  static String ensureParentOf(String filePath) {
    Directory(p.dirname(filePath)).createSync(recursive: true);
    return filePath;
  }

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }
}
