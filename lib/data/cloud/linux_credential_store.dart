/// Linux 安全令牌存储：通过 Secret Service（GNOME Keyring / KWallet）保存登录令牌。
///
/// **实现方式**：调用 libsecret 官方 CLI `secret-tool`（Debian/Ubuntu 包：
/// `libsecret-tools`）。token 通过 stdin 交给 `secret-tool store`，不经过命令行参数、
/// 不写明文文件、不写 SQLite/JSON/日志，读取时把 secret 从 stdout 取回。
///
/// **为什么不用 dart:ffi 直连 libsecret**：libsecret 的高层密码 API
/// （`secret_password_store_sync` / `secret_password_lookup_sync`）是 C 可变参数函数，
/// `dart:ffi` 不支持调用可变参数；改用底层 GDBus 需要自行实现 Secret Service 的
/// 会话密钥、unlock/prompt 流程，代码量与失败面远大于本阶段需要。
/// `secret-tool` 是 libsecret 官方工具，行为等价、无新增 pub 依赖，
/// 并且可以把进程执行器注入成 runner，使本文件在任意宿主机（含 Windows CI）都能做单测。
///
/// **安全契约**（docs/sync/SECURITY.md、secure_token_store.dart）：
/// 任何失败都必须抛 [CloudException]；**绝不**降级为明文文件或内存替代。
///
/// Linux 运行期依赖：
///   sudo apt-get install libsecret-tools gnome-keyring
/// 并确保桌面会话已解锁密钥环（GNOME 登录后自动解锁；KDE 用 KWallet
/// 的 Secret Service 兼容层）。无 keyring 时本实现只报错，不落盘。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/cloud/cloud_types.dart';
import 'secure_token_store.dart';

/// 可注入的 `secret-tool` 执行器：参数 + 可选 stdin 文本，返回进程结果。
typedef SecretToolRunner = Future<ProcessResult> Function(
  List<String> arguments,
  String? stdinText,
);

/// 默认执行器：secret 通过 stdin 传给 `secret-tool store`，
/// 不出现在命令行参数、环境变量或临时文件里。
Future<ProcessResult> _defaultRunner(
  List<String> arguments,
  String? stdinText,
) async {
  final process = await Process.start('secret-tool', arguments);
  if (stdinText != null) {
    process.stdin.write(stdinText);
  }
  await process.stdin.close();
  final stdoutText = await process.stdout.transform(utf8.decoder).join();
  final stderrText = await process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;
  return ProcessResult(process.pid, exitCode, stdoutText, stderrText);
}

/// Linux 平台的安全令牌存储实现。
final class LinuxCredentialStore implements SecureTokenStore {
  LinuxCredentialStore({SecretToolRunner? runner, this.service = 'jihuatai'})
    : _runner = runner ?? _defaultRunner;

  final SecretToolRunner _runner;

  /// Secret Service 的属性命名空间，避免与其它应用冲突。
  final String service;

  bool _available = true;

  /// 只有确认 `secret-tool` 不存在时才会变为 false；keyring 锁定等
  /// 临时故障不会永久失能（解锁后重试即可）。
  @override
  bool get isAvailable => _available;

  @override
  Future<String?> read(String key) async {
    final result = await _run(<String>[
      'lookup',
      ..._attributes(key),
    ], null);
    // secret-tool lookup：找到返回 0 并输出 secret；找不到返回 1、无输出。
    if (result.exitCode == 1) {
      final out = _text(result.stdout);
      if (out.trim().isEmpty) return null;
    }
    _ensureSuccess(result, '读取');
    // secret-tool 输出 secret 后会带一个换行；去掉行尾空白，避免污染会话 JSON 校验。
    final secret = _text(result.stdout).trimRight();
    return secret.isEmpty ? null : secret;
  }

  @override
  Future<void> write(String key, String value) async {
    final result = await _run(<String>[
      'store',
      '--label',
      '计划台 云同步令牌',
      ..._attributes(key),
    ], value);
    _ensureSuccess(result, '保存');
  }

  @override
  Future<void> delete(String key) async {
    final result = await _run(<String>[
      'clear',
      ..._attributes(key),
    ], null);
    // 不存在时 secret-tool clear 也返回 0；个别版本返回 1，同样视为已删除。
    if (result.exitCode == 0 || result.exitCode == 1) return;
    _ensureSuccess(result, '删除');
  }

  List<String> _attributes(String key) => <String>[
    'service',
    service,
    'key',
    key,
  ];

  Future<ProcessResult> _run(List<String> arguments, String? stdinText) async {
    if (!_available) throw _missingToolError();
    try {
      return await _runner(arguments, stdinText);
    } on ProcessException catch (error) {
      _available = false;
      throw _missingToolError(cause: error);
    }
  }

  void _ensureSuccess(ProcessResult result, String action) {
    if (result.exitCode == 0) return;
    final detail = _text(result.stderr).trim();
    final suffix = detail.isEmpty ? '' : '（$detail）';
    throw CloudException(
      CloudErrorKind.unknown,
      '无法$action云同步令牌：Secret Service 不可用$suffix。'
      '请安装并解锁系统密钥环（GNOME Keyring / KWallet），'
      '例如执行 sudo apt install libsecret-tools gnome-keyring 后重新登录桌面会话。',
    );
  }

  CloudException _missingToolError({Object? cause}) => CloudException(
    CloudErrorKind.unknown,
    '未检测到 secret-tool，无法安全保存云同步令牌。'
    '请安装：sudo apt install libsecret-tools gnome-keyring，'
    '并确保桌面会话已启动且解锁了密钥环。',
    cause: cause,
  );

  String _text(Object? value) => value is String ? value : '';
}
