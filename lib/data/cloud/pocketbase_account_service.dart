/// PocketBase 账号服务（实现冻结的 [CloudAccountService]）。
///
/// 端点：
/// - `GET  /api/planner/health`
/// - `POST /api/collections/users/auth-with-password`
/// - `POST /api/collections/users/auth-refresh`
///
/// 安全要求：
/// - 密码只存在于本次调用的局部变量，不写数据库/配置/日志；
/// - token 只写系统安全存储（[SecureTokenStore]），不进 SQLite；
/// - 正式环境强制 HTTPS（仅 loopback 允许 http），不提供关闭证书校验的开关。
library;

import 'dart:async';
import 'dart:convert';

import '../../core/cloud/cloud_services.dart';
import '../../core/cloud/cloud_types.dart';
import 'cloud_credentials.dart';
import 'http_json.dart';
import 'planner_api.dart';
import 'secure_token_store.dart';

/// 是否为本机回环地址。
bool _isLoopback(String host) {
  final value = host.toLowerCase();
  return value == 'localhost' ||
      value == '127.0.0.1' ||
      value == '::1' ||
      value == '[::1]' ||
      value.endsWith('.localhost');
}

/// 校验服务器地址：正式环境必须 HTTPS。
Uri validateServerUrl(Uri baseUrl) {
  if (baseUrl.host.isEmpty) {
    throw const CloudException(CloudErrorKind.protocol, '服务器地址格式不正确');
  }
  if (baseUrl.scheme != 'http' && baseUrl.scheme != 'https') {
    throw const CloudException(
      CloudErrorKind.protocol,
      '服务器地址只支持 http / https',
    );
  }
  if (baseUrl.scheme == 'http' && !_isLoopback(baseUrl.host)) {
    throw const CloudException(
      CloudErrorKind.protocol,
      '出于安全考虑，非本机服务器必须使用 HTTPS（程序不会关闭证书校验）',
    );
  }
  if (baseUrl.userInfo.isNotEmpty || baseUrl.hasQuery || baseUrl.hasFragment) {
    throw const CloudException(
      CloudErrorKind.protocol,
      '服务器地址不能包含用户名、参数或锚点',
    );
  }
  final path = baseUrl.path.endsWith('/')
      ? baseUrl.path.substring(0, baseUrl.path.length - 1)
      : baseUrl.path;
  return baseUrl.replace(path: path);
}

final class PocketBaseAccountService
    implements CloudAccountService, CloudCredentialsProvider {
  PocketBaseAccountService({
    required SecureTokenStore tokenStore,
    JsonHttpClient? http,
    PlannerApi? api,
    DateTime Function()? clock,
  }) : _store = tokenStore,
       _http = http ?? JsonHttpClient(),
       _api = api ?? PlannerApi(http: http),
       _clock = clock ?? DateTime.now;

  static const String _storageKey = 'JihuaTai/cloud-session';

  final SecureTokenStore _store;
  final JsonHttpClient _http;
  final PlannerApi _api;
  final DateTime Function() _clock;

  final StreamController<CloudAccount?> _accountChanges =
      StreamController<CloudAccount?>.broadcast();

  CloudAccount? _account;
  String? _token;
  DateTime? _expiresAt;
  Uri? _baseUrl;
  String? _serverVersion;
  bool _closed = false;

  // ---------------------------------------------------------------------------
  // CloudAccountService
  // ---------------------------------------------------------------------------

  @override
  Stream<CloudAccount?> observeAccount() => Stream<CloudAccount?>.multi((
    controller,
  ) {
    controller.add(_account);
    final subscription = _accountChanges.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });

  @override
  CloudAccount? currentAccount() => _account;

  @override
  Future<ServerHandshake> connectServer(Uri baseUrl) async {
    _ensureOpen();
    final uri = validateServerUrl(baseUrl);
    final handshake = await _api.health(uri);
    _baseUrl = uri;
    _serverVersion = handshake.serverVersion;
    return handshake;
  }

  @override
  Future<CloudAccount> login({
    required String username,
    required String password,
  }) async {
    _ensureOpen();
    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '请先连接服务器并确认协议兼容',
      );
    }
    final trimmed = username.trim();
    if (trimmed.isEmpty || password.isEmpty) {
      throw const CloudException(CloudErrorKind.unauthorized, '请输入账号和密码');
    }
    final JsonResponse response;
    try {
      response = await _http.send(
        'POST',
        _authEndpoint(baseUrl, 'auth-with-password'),
        body: <String, Object?>{'identity': trimmed, 'password': password},
      );
    } on CloudException catch (error) {
      if (error.statusCode == 400 || error.statusCode == 401) {
        throw const CloudException(
          CloudErrorKind.unauthorized,
          '账号或密码不正确',
        );
      }
      rethrow;
    }
    final token = response.body['token'];
    if (token is! String || token.isEmpty) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '服务器登录响应缺少 token',
      );
    }
    final record = response.body['record'];
    final map = record is Map<Object?, Object?>
        ? Map<String, Object?>.from(record)
        : const <String, Object?>{};
    final ownerId = map['id'] as String? ?? '';
    final email = (map['email'] as String?) ?? trimmed;
    if (ownerId.isEmpty || email.isEmpty) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '服务器登录响应缺少账号信息',
      );
    }
    final account = CloudAccount(
      ownerId: ownerId,
      email: email,
      displayName: map['name'] as String?,
      serverUrl: baseUrl,
      authenticatedAt: _clock().toUtc(),
    );
    await _persist(
      account: account,
      token: token,
      expiresAt: _expiryOf(token),
    );
    return account;
  }

  @override
  Future<CloudAccount?> restoreSession() async {
    _ensureOpen();
    if (!_store.isAvailable) {
      throw const CloudException(
        CloudErrorKind.unknown,
        '系统安全存储不可用，无法恢复登录状态，请重新登录',
      );
    }
    final raw = await _store.read(_storageKey);
    if (raw == null || raw.trim().isEmpty) return null;
    final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(raw);
      json = Map<String, Object?>.from(decoded! as Map<Object?, Object?>);
    } on Object {
      await _store.delete(_storageKey);
      return null;
    }
    final ownerId = json['ownerId'] as String?;
    final email = json['email'] as String?;
    final serverUrl = json['serverUrl'] as String?;
    final token = json['token'] as String?;
    if (ownerId == null ||
        email == null ||
        serverUrl == null ||
        token == null ||
        token.isEmpty) {
      await _store.delete(_storageKey);
      return null;
    }
    final baseUrl = Uri.tryParse(serverUrl);
    if (baseUrl == null) {
      await _store.delete(_storageKey);
      return null;
    }
    _baseUrl = baseUrl;
    _serverVersion = json['serverVersion'] as String?;
    _token = token;
    _expiresAt = DateTime.tryParse(json['expiresAt'] as String? ?? '')?.toUtc();
    final account = CloudAccount(
      ownerId: ownerId,
      email: email,
      displayName: json['displayName'] as String?,
      serverUrl: baseUrl,
      authenticatedAt:
          DateTime.tryParse(json['authenticatedAt'] as String? ?? '')?.toUtc() ??
          _clock().toUtc(),
    );
    _account = account;
    _emitAccount();

    if (_isExpired) {
      try {
        await refreshToken();
      } on CloudException catch (error) {
        if (error.kind == CloudErrorKind.unauthorized) {
          await _clear();
          return null;
        }
        // 网络失败：保留账号让本地功能可用，token 会在真正同步时再刷新。
        if (error.kind != CloudErrorKind.network &&
            error.kind != CloudErrorKind.timeout) {
          rethrow;
        }
      }
    }
    return _account;
  }

  @override
  Future<void> logout({bool revokeRemoteSession = true}) async {
    _ensureOpen();
    // PocketBase token 无状态；API_CONTRACT §3.3 明确 V2 不要求远程撤销。
    await _clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _accountChanges.close();
  }

  // ---------------------------------------------------------------------------
  // CloudCredentialsProvider
  // ---------------------------------------------------------------------------

  @override
  Uri get baseUrl {
    final account = _account;
    final url = _baseUrl ?? account?.serverUrl;
    if (url == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录云端账号');
    }
    return url;
  }

  @override
  Future<String> requireToken() async {
    final token = _token;
    if (_account == null || token == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录云端账号');
    }
    if (_isExpired) return refreshToken();
    return token;
  }

  @override
  Future<String> refreshToken() async {
    final currentToken = _token;
    if (currentToken == null || _account == null) {
      throw const CloudException(CloudErrorKind.unauthorized, '请先登录云端账号');
    }
    final JsonResponse response;
    try {
      response = await _http.send(
        'POST',
        _authEndpoint(baseUrl, 'auth-refresh'),
        headers: <String, String>{
          'Authorization': 'Bearer $currentToken',
        },
      );
    } on CloudException catch (error) {
      if (error.kind == CloudErrorKind.unauthorized ||
          error.kind == CloudErrorKind.forbidden) {
        await _clear();
        throw const CloudException(
          CloudErrorKind.unauthorized,
          '登录已过期，请重新登录',
        );
      }
      rethrow;
    }
    final token = response.body['token'];
    if (token is! String || token.isEmpty) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '刷新登录状态失败：响应缺少 token',
      );
    }
    final record = response.body['record'];
    final map = record is Map<Object?, Object?>
        ? Map<String, Object?>.from(record)
        : const <String, Object?>{};
    final account = _account!;
    final refreshed = CloudAccount(
      ownerId: map['id'] as String? ?? account.ownerId,
      email: map['email'] as String? ?? account.email,
      displayName: map['name'] as String? ?? account.displayName,
      serverUrl: account.serverUrl,
      authenticatedAt: account.authenticatedAt,
    );
    await _persist(
      account: refreshed,
      token: token,
      expiresAt: _expiryOf(token),
    );
    return token;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  bool get _isExpired {
    final expires = _expiresAt;
    if (expires == null) return false;
    return _clock().toUtc().isAfter(
      expires.subtract(const Duration(seconds: 30)),
    );
  }

  DateTime _expiryOf(String token) {
    final fromJwt = _jwtExpiry(token);
    if (fromJwt != null) return fromJwt;
    return _clock().toUtc().add(const Duration(days: 14));
  }

  Future<void> _persist({
    required CloudAccount account,
    required String token,
    required DateTime expiresAt,
  }) async {
    if (!_store.isAvailable) {
      throw const CloudException(
        CloudErrorKind.unknown,
        '系统安全存储不可用，无法安全保存登录令牌',
      );
    }
    await _store.write(
      _storageKey,
      jsonEncode(<String, Object?>{
        'token': token,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'ownerId': account.ownerId,
        'email': account.email,
        'displayName': account.displayName,
        'serverUrl': account.serverUrl.toString(),
        'serverVersion': _serverVersion,
        'authenticatedAt': account.authenticatedAt.toUtc().toIso8601String(),
      }),
    );
    _token = token;
    _expiresAt = expiresAt;
    _account = account;
    _emitAccount();
  }

  Future<void> _clear() async {
    await _store.delete(_storageKey);
    _token = null;
    _expiresAt = null;
    _account = null;
    _emitAccount();
  }

  void _emitAccount() {
    if (!_accountChanges.isClosed) _accountChanges.add(_account);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('PocketBaseAccountService 已关闭');
  }

  static Uri _authEndpoint(Uri baseUrl, String action) {
    final prefix = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(
      path: '$prefix/api/collections/users/$action',
    );
  }

  static DateTime? _jwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      final padded = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
      final decoded = utf8.decode(base64.decode(padded));
      final json = jsonDecode(decoded);
      if (json is! Map<String, Object?>) return null;
      final exp = json['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (exp * 1000).round(),
        isUtc: true,
      );
    } on Object {
      return null;
    }
  }
}
