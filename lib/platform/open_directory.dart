/// 打开系统文件管理器并定位到指定目录（跨平台）。
///
/// Windows 用 `explorer.exe`、macOS 用 `open`、Linux 用 `xdg-open`（XDG 标准，
/// GNOME / KDE / XFCE 桌面环境均提供）。命令与平台判断集中在这里，
/// 业务对话框不再硬编码 `explorer.exe`。
///
/// 失败（命令不存在、没有图形会话、权限不足）时由底层抛出异常，
/// 调用方负责给出用户可读提示；本函数不吞异常。
library;

import 'dart:io';

/// 可注入的进程执行器，便于单测在没有对应平台命令时也能验证分支。
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<ProcessResult> _defaultRunner(
  String executable,
  List<String> arguments,
) => Process.run(executable, arguments);

/// 返回指定操作系统打开目录所用的命令名。
///
/// 参数使用 `Platform.operatingSystem` 的取值（`windows`/`macos`/`linux`）。
String directoryOpenerCommand(String operatingSystem) {
  switch (operatingSystem) {
    case 'windows':
      return 'explorer.exe';
    case 'macos':
      return 'open';
    case 'linux':
      return 'xdg-open';
    default:
      throw UnsupportedError('当前平台不支持打开文件夹：$operatingSystem');
  }
}

/// 打开 [path] 所在目录。
///
/// [runner] / [operatingSystem] 仅用于测试注入；生产调用不传。
Future<ProcessResult> openDirectory(
  String path, {
  ProcessRunner? runner,
  String? operatingSystem,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final command = directoryOpenerCommand(os);
  return (runner ?? _defaultRunner)(command, <String>[path]);
}
