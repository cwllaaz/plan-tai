/// 服务器地址输入的本地校验与规范化。
///
/// 真正的策略由 `CloudAccountService.connectServer` 强制（https，或本机 http），
/// 这里只做**即时反馈**，让用户在点「连接并登录」之前就能看懂哪里不对。
/// 两条规则刻意保持一致，避免"界面放行、服务层拒绝"的割裂。
library;

/// 本机回环地址：只有这些主机允许 HTTP 明文调试（与冻结契约一致）。
bool isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '[::1]' ||
      normalized.endsWith('.localhost');
}

/// 地址解析结果：成功时 [uri] 非空且已规范化；失败时 [error] 是给用户看的一句话。
class ServerAddressParseResult {
  const ServerAddressParseResult.ok(Uri this.uri) : error = null;

  const ServerAddressParseResult.invalid(String this.error) : uri = null;

  final Uri? uri;
  final String? error;

  bool get ok => uri != null;
}

/// 解析用户输入的服务器地址。
///
/// - 空串 → 「请填写服务器地址」；
/// - 没写协议时默认补 `https://`（用户通常只填域名）；
/// - 只接受 `https://`，或本机回环地址的 `http://`；
/// - 丢掉路径/查询/片段，只保留 `scheme://host[:port]`，避免把接口路径当地址。
ServerAddressParseResult parseServerAddressInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const ServerAddressParseResult.invalid('请填写服务器地址');
  }
  if (RegExp(r'\s').hasMatch(text)) {
    return const ServerAddressParseResult.invalid(
      '服务器地址不能包含空格，示例：https://sync.example.com',
    );
  }

  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(text);
  final candidate = hasScheme ? text : 'https://$text';

  final Uri? parsed;
  try {
    parsed = Uri.tryParse(candidate);
  } on FormatException {
    return const ServerAddressParseResult.invalid(
      '服务器地址格式不正确，示例：https://sync.example.com',
    );
  }
  if (parsed == null || parsed.host.isEmpty) {
    return const ServerAddressParseResult.invalid(
      '服务器地址格式不正确，示例：https://sync.example.com',
    );
  }
  if (parsed.scheme != 'https' && parsed.scheme != 'http') {
    return const ServerAddressParseResult.invalid(
      '只支持 https:// 地址；本机调试可用 http://localhost',
    );
  }
  if (parsed.hasPort && (parsed.port < 1 || parsed.port > 65535)) {
    return const ServerAddressParseResult.invalid('端口号需要在 1–65535 之间');
  }
  if (parsed.userInfo.isNotEmpty) {
    return const ServerAddressParseResult.invalid('地址里不要包含账号密码，请分别填写');
  }
  if (parsed.hasQuery || parsed.hasFragment) {
    return const ServerAddressParseResult.invalid('地址不要带查询参数或片段');
  }
  if (parsed.scheme == 'http' && !isLoopbackHost(parsed.host)) {
    return const ServerAddressParseResult.invalid(
      '正式连接必须使用 HTTPS；只有本机 localhost / 127.0.0.1 允许 HTTP 调试',
    );
  }

  // 规范化为 origin：去掉尾部斜杠、路径、查询与片段。
  final normalized = Uri(
    scheme: parsed.scheme,
    host: parsed.host.toLowerCase(),
    port: parsed.hasPort ? parsed.port : null,
  );
  return ServerAddressParseResult.ok(normalized);
}
