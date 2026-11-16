/// 同步协议客户端：健康握手、push、pull。
///
/// 端点与信封严格按 docs/sync/API_CONTRACT.md（`/api/planner/...`）。
/// 这里只做协议映射与解析；重试、outbox、冲突策略都在 `SqliteCloudSyncService`。
library;

import '../../core/cloud/cloud_types.dart';
import '../entity_codec.dart';
import 'http_json.dart';

/// 协议版本与载荷 schema 版本（冻结）。
const int kProtocolVersion = 1;
const int kPayloadSchemaVersion = 1;

// ---------------------------------------------------------------------------
// push
// ---------------------------------------------------------------------------

final class PushOp {
  const PushOp({
    required this.opId,
    required this.entityType,
    required this.entityId,
    required this.opType,
    required this.baseRevision,
    required this.clientRevision,
    required this.clientUpdatedAt,
    this.payload,
  });

  final String opId;
  final CloudEntityType entityType;
  final String entityId;

  /// create / update / delete。
  final String opType;
  final int baseRevision;
  final int clientRevision;
  final DateTime clientUpdatedAt;

  /// create/update 必填；delete 为 null。
  final Map<String, Object?>? payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'opId': opId,
    'entityType': entityType.wireName,
    'entityId': entityId,
    'opType': opType,
    'baseRevision': baseRevision,
    'clientRevision': clientRevision,
    'clientUpdatedAt': encodeInstant(clientUpdatedAt),
    if (payload != null) 'payload': payload,
  };
}

final class OpError {
  const OpError({required this.code, required this.message, required this.retryable});

  final String code;
  final String message;
  final bool retryable;

  factory OpError.fromJson(Map<String, Object?> json) => OpError(
    code: json['code'] as String? ?? 'UNKNOWN',
    message: json['message'] as String? ?? '服务器拒绝了该操作',
    retryable: json['retryable'] == true,
  );
}

final class OpConflict {
  const OpConflict({
    required this.kind,
    required this.serverRevision,
    required this.serverDeleted,
    this.serverPayload,
    this.serverUpdatedAt,
    this.serverUpdatedByDevice,
    this.serverCursor,
  });

  final String kind;
  final int serverRevision;
  final bool serverDeleted;
  final Map<String, Object?>? serverPayload;
  final DateTime? serverUpdatedAt;
  final String? serverUpdatedByDevice;
  final String? serverCursor;

  factory OpConflict.fromJson(Map<String, Object?> json) => OpConflict(
    kind: json['kind'] as String? ?? 'UNKNOWN',
    serverRevision: (json['serverRevision'] as num?)?.toInt() ?? 0,
    serverDeleted: json['serverDeleted'] == true,
    serverPayload: json['serverPayload'] == null
        ? null
        : Map<String, Object?>.from(
            json['serverPayload']! as Map<Object?, Object?>,
          ),
    serverUpdatedAt: _optionalInstant(json['serverUpdatedAt']),
    serverUpdatedByDevice: json['serverUpdatedByDevice'] as String?,
    serverCursor: json['serverCursor'] as String?,
  );
}

final class OpResult {
  const OpResult({
    required this.opId,
    required this.status,
    this.serverRevision,
    this.serverCursor,
    this.noOp = false,
    this.conflict,
    this.error,
  });

  final String opId;

  /// applied / duplicate / conflict / rejected。
  final String status;
  final int? serverRevision;
  final String? serverCursor;
  final bool noOp;
  final OpConflict? conflict;
  final OpError? error;

  bool get isApplied => status == 'applied';

  bool get isDuplicate => status == 'duplicate';

  bool get isSuccess => isApplied || isDuplicate;

  factory OpResult.fromJson(Map<String, Object?> json) => OpResult(
    opId: json['opId']! as String,
    status: json['status'] as String? ?? 'rejected',
    serverRevision: (json['serverRevision'] as num?)?.toInt(),
    serverCursor: json['serverCursor'] as String?,
    noOp: json['noOp'] == true,
    conflict: json['conflict'] == null
        ? null
        : OpConflict.fromJson(
            Map<String, Object?>.from(
              json['conflict']! as Map<Object?, Object?>,
            ),
          ),
    error: json['error'] == null
        ? null
        : OpError.fromJson(
            Map<String, Object?>.from(json['error']! as Map<Object?, Object?>),
          ),
  );
}

final class PushResponse {
  const PushResponse({required this.results});

  final List<OpResult> results;

  factory PushResponse.fromJson(Map<String, Object?> json) {
    final raw = json['results'];
    if (raw is! List<Object?>) {
      throw const CloudException(
        CloudErrorKind.protocol,
        'push 响应缺少 results 数组',
      );
    }
    return PushResponse(
      results: raw
          .map(
            (item) => OpResult.fromJson(
              Map<String, Object?>.from(item! as Map<Object?, Object?>),
            ),
          )
          .toList(growable: false),
    );
  }
}

// ---------------------------------------------------------------------------
// pull
// ---------------------------------------------------------------------------

final class PullChange {
  const PullChange({
    required this.entityType,
    required this.entityId,
    required this.serverRevision,
    required this.serverCursor,
    required this.deleted,
    this.deletedAt,
    this.payload,
    this.serverUpdatedAt,
    this.updatedByDevice,
  });

  final CloudEntityType entityType;
  final String entityId;
  final int serverRevision;
  final String serverCursor;
  final bool deleted;
  final DateTime? deletedAt;
  final Map<String, Object?>? payload;
  final DateTime? serverUpdatedAt;
  final String? updatedByDevice;

  factory PullChange.fromJson(Map<String, Object?> json) {
    final type = CloudEntityType.tryParse(json['entityType'] as String? ?? '');
    if (type == null) {
      throw CloudException(
        CloudErrorKind.protocol,
        '未知实体类型：${json['entityType']}',
      );
    }
    return PullChange(
      entityType: type,
      entityId: json['entityId']! as String,
      serverRevision: (json['serverRevision'] as num).toInt(),
      serverCursor: json['serverCursor'] as String? ?? '',
      deleted: json['deleted'] == true,
      deletedAt: _optionalInstant(json['deletedAt']),
      payload: json['payload'] == null
          ? null
          : Map<String, Object?>.from(
              json['payload']! as Map<Object?, Object?>,
            ),
      serverUpdatedAt: _optionalInstant(json['serverUpdatedAt']),
      updatedByDevice: json['updatedByDevice'] as String?,
    );
  }
}

final class PullResponse {
  const PullResponse({
    required this.changes,
    required this.hasMore,
    this.nextCursor,
    this.snapshot = false,
    this.snapshotSeq,
    this.resetRequired = false,
  });

  final List<PullChange> changes;
  final bool hasMore;
  final String? nextCursor;
  final bool snapshot;
  final int? snapshotSeq;
  final bool resetRequired;

  factory PullResponse.fromJson(Map<String, Object?> json) {
    final raw = json['changes'];
    if (raw is! List<Object?>) {
      throw const CloudException(
        CloudErrorKind.protocol,
        'pull 响应缺少 changes 数组',
      );
    }
    return PullResponse(
      changes: raw
          .map(
            (item) => PullChange.fromJson(
              Map<String, Object?>.from(item! as Map<Object?, Object?>),
            ),
          )
          .toList(growable: false),
      hasMore: json['hasMore'] == true,
      nextCursor: json['nextCursor'] as String?,
      snapshot: json['snapshot'] == true || json['mode'] == 'snapshot',
      snapshotSeq: (json['snapshotSeq'] as num?)?.toInt(),
      resetRequired: json['resetRequired'] == true,
    );
  }
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

final class PlannerApi {
  PlannerApi({JsonHttpClient? http, this.clientVersion = '2.0.0'})
    : _http = http ?? JsonHttpClient();

  final JsonHttpClient _http;
  final String clientVersion;

  /// 健康检查 + 协议兼容校验（API_CONTRACT §2）。
  Future<ServerHandshake> health(Uri baseUrl) async {
    final response = await _http.send('GET', _endpoint(baseUrl, '/health'));
    final body = response.body;
    final featuresRaw = body['features'];
    final features = featuresRaw is List<Object?>
        ? featuresRaw.whereType<String>().toList(growable: false)
        : const <String>[];
    final protocol = (body['protocolVersion'] as num?)?.toInt() ?? 0;
    final minSchema = (body['minSchemaVersion'] as num?)?.toInt() ?? 0;
    final maxSchema = (body['maxSchemaVersion'] as num?)?.toInt() ?? 0;
    final status = body['status'] as String? ?? '';
    if (status != 'ok') {
      throw CloudException(CloudErrorKind.protocol, '服务器未就绪（status=$status）');
    }
    if (protocol != kProtocolVersion) {
      throw CloudException(
        CloudErrorKind.protocol,
        '服务器协议版本 $protocol 与客户端 $kProtocolVersion 不兼容',
      );
    }
    if (!(minSchema <= kPayloadSchemaVersion &&
        kPayloadSchemaVersion <= maxSchema)) {
      throw CloudException(
        CloudErrorKind.protocol,
        '服务器数据版本范围 $minSchema..$maxSchema 不支持客户端 $kPayloadSchemaVersion',
      );
    }
    if (!features.contains('sync.push') || !features.contains('sync.pull')) {
      throw const CloudException(
        CloudErrorKind.protocol,
        '服务器未启用同步能力（缺少 sync.push / sync.pull）',
      );
    }
    return ServerHandshake(
      baseUrl: baseUrl,
      serverVersion: body['serverVersion'] as String? ?? 'unknown',
      protocolVersion: protocol,
      minSchemaVersion: minSchema,
      maxSchemaVersion: maxSchema,
      serverTime: _optionalInstant(body['serverTime']) ?? DateTime.now().toUtc(),
      features: features,
    );
  }

  Future<PushResponse> push({
    required Uri baseUrl,
    required String token,
    required String deviceId,
    required String ownerId,
    required List<PushOp> ops,
  }) async {
    if (ops.isEmpty) return const PushResponse(results: <OpResult>[]);
    final response = await _http.send(
      'POST',
      _endpoint(baseUrl, '/sync/push'),
      headers: _headers(token, deviceId),
      body: <String, Object?>{
        'protocolVersion': kProtocolVersion,
        'schemaVersion': kPayloadSchemaVersion,
        'deviceId': deviceId,
        'clientVersion': clientVersion,
        'ownerId': ownerId,
        'sentAt': encodeInstant(DateTime.now().toUtc()),
        'ops': ops.map((op) => op.toJson()).toList(growable: false),
      },
    );
    return PushResponse.fromJson(response.body);
  }

  Future<PullResponse> pull({
    required Uri baseUrl,
    required String token,
    required String deviceId,
    required bool snapshot,
    required int limit,
    String? cursor,
    int? snapshotSeq,
  }) async {
    final body = <String, Object?>{
      'protocolVersion': kProtocolVersion,
      'schemaVersion': kPayloadSchemaVersion,
      'deviceId': deviceId,
      'mode': snapshot ? 'snapshot' : 'incremental',
      'limit': limit,
    };
    if (cursor != null) body['cursor'] = cursor;
    if (snapshotSeq != null) body['snapshotSeq'] = snapshotSeq;
    final response = await _http.send(
      'POST',
      _endpoint(baseUrl, '/sync/pull'),
      headers: _headers(token, deviceId),
      body: body,
    );
    return PullResponse.fromJson(response.body);
  }

  Map<String, String> _headers(String token, String deviceId) =>
      <String, String>{
        'Authorization': 'Bearer $token',
        'X-Device-Id': deviceId,
        'X-Client-Version': clientVersion,
      };

  Uri _endpoint(Uri baseUrl, String path) {
    final prefix = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(path: '$prefix/api/planner$path');
  }
}

DateTime? _optionalInstant(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
