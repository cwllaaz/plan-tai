/// HTTP JSON 传输（dart:io HttpClient）。
///
/// 统一超时、错误分类与协议错误码解析；**不提供关闭证书校验的开关**
/// （HttpClient 默认严格校验，正式环境必须 https）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/cloud/cloud_types.dart';

/// 服务端错误信封里的稳定错误码（API_CONTRACT §1.2）。
final class ApiErrorInfo {
  const ApiErrorInfo(this.code);

  final String code;
}

final class JsonResponse {
  const JsonResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

final class JsonHttpClient {
  JsonHttpClient({
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 20),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration timeout;

  Future<JsonResponse> send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Map<String, Object?>? body,
  }) async {
    final client = _clientFactory();
    client.connectionTimeout = timeout;
    HttpClientRequest? request;
    try {
      request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      headers?.forEach(request.headers.set);
      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = encoded.length;
        request.add(encoded);
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = text.trim().isEmpty ? null : jsonDecode(text);
      final map = decoded is Map<Object?, Object?>
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _errorFrom(response.statusCode, map);
      }
      return JsonResponse(statusCode: response.statusCode, body: map);
    } on TimeoutException catch (error) {
      throw CloudException(
        CloudErrorKind.timeout,
        '连接服务器超时（${timeout.inSeconds} 秒）',
        retryable: true,
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw CloudException(
        CloudErrorKind.network,
        'HTTPS 证书校验失败，已停止连接（不会降级为不校验证书）：${error.message}',
        retryable: false,
        cause: error,
      );
    } on SocketException catch (error) {
      throw CloudException(
        CloudErrorKind.network,
        '无法连接服务器：${error.message}',
        retryable: true,
        cause: error,
      );
    } on HttpException catch (error) {
      throw CloudException(
        CloudErrorKind.network,
        '网络请求失败：${error.message}',
        retryable: true,
        cause: error,
      );
    } on FormatException catch (error) {
      throw CloudException(
        CloudErrorKind.protocol,
        '服务器返回了非法 JSON',
        cause: error,
      );
    } finally {
      client.close(force: true);
    }
  }

  static CloudException _errorFrom(
    int statusCode,
    Map<String, Object?> body,
  ) {
    final code = body['code'] is String ? body['code'] as String : '';
    final message = body['message'] is String
        ? (body['message'] as String).trim()
        : '';
    final retryable = body['retryable'] == true;
    final kind = switch (statusCode) {
      400 => CloudErrorKind.protocol,
      401 => CloudErrorKind.unauthorized,
      403 => CloudErrorKind.forbidden,
      404 => CloudErrorKind.notFound,
      409 => code == 'RESET_REQUIRED' || code == 'CURSOR_INVALID'
          ? CloudErrorKind.conflict
          : CloudErrorKind.conflict,
      413 => CloudErrorKind.protocol,
      429 => CloudErrorKind.rateLimited,
      >= 500 => CloudErrorKind.server,
      _ => CloudErrorKind.unknown,
    };
    return CloudException(
      kind,
      message.isEmpty ? '服务器返回 $statusCode' : message,
      retryable: retryable || kind == CloudErrorKind.server,
      statusCode: statusCode,
      cause: code.isEmpty ? null : ApiErrorInfo(code),
    );
  }
}
