/// 测试用 Fake PocketBase / 同步 API（dart:io HttpServer）。
///
/// 实现 docs/sync/API_CONTRACT.md 的：
/// - `GET /api/planner/health`
/// - `POST /api/collections/users/auth-with-password`
/// - `POST /api/collections/users/auth-refresh`
/// - `POST /api/planner/sync/push`
/// - `POST /api/planner/sync/pull`
///
/// 不是生产服务器：只覆盖客户端测试需要的语义（幂等、版本冲突、墓碑、级联、
/// note 唯一、快照/增量分页、故障注入）。所有数据保存在内存，测试结束即丢弃。
library;

// ignore_for_file: use_null_aware_elements

import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class FakePlannerServer {
  FakePlannerServer._(this._server, this.pageSize);

  final HttpServer _server;
  int pageSize;

  static Future<FakePlannerServer> start({int pageSize = 200}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakePlannerServer._(server, pageSize);
    server.listen(fake._handle);
    return fake;
  }

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() async {
    await _server.close(force: true);
  }

  // -------------------------------------------------------------------------
  // 状态
  // -------------------------------------------------------------------------

  final Map<String, _Account> _accountsByEmail = <String, _Account>{};
  final Map<String, _Account> _accountsById = <String, _Account>{};
  final Map<String, _Token> _tokens = <String, _Token>{};
  final Map<String, _Entity> _entities = <String, _Entity>{};
  final Map<String, _OpLog> _ops = <String, _OpLog>{};
  final Map<String, int> _maxSeq = <String, int>{};

  bool offline = false;
  bool dropNextPushResponse = false;
  bool failNextPush = false;
  bool resetRequiredNextPull = false;
  int corruptPushPage = 0; // pull: 第 N 页塞入非法 payload
  int protocolVersionOverride = 1;
  Duration? tokenTtlOverride;

  int pushRequestCount = 0;
  int pullRequestCount = 0;
  int _tokenSequence = 0;
  final List<String?> pullCursors = <String?>[];

  void addAccount({
    required String email,
    required String password,
    required String ownerId,
    String? name,
  }) {
    final account = _Account(
      ownerId: ownerId,
      email: email,
      password: password,
      name: name,
    );
    _accountsByEmail[email.toLowerCase()] = account;
    _accountsById[ownerId] = account;
  }

  int get ownedEntityCount => _entities.length;

  int liveCount(String ownerId) =>
      _entities.values.where((e) => e.ownerId == ownerId && !e.deleted).length;

  int opLogCount(String ownerId) =>
      _ops.keys.where((key) => key.startsWith('$ownerId|')).length;

  // ignore: library_private_types_in_public_api
  _Entity? entity(String ownerId, String type, String id) =>
      _entities['$ownerId|$type|$id'];

  Map<String, Object?>? payloadOf(String ownerId, String type, String id) =>
      _entities['$ownerId|$type|$id']?.payload;

  /// 模拟另一台设备直接写入服务端（不经过客户端 push）。
  void seedEntity({
    required String ownerId,
    required String type,
    required String id,
    required Map<String, Object?> payload,
    int revision = 1,
    bool deleted = false,
  }) {
    final seq = _nextSeq(ownerId);
    _entities['$ownerId|$type|$id'] = _Entity(
      ownerId: ownerId,
      type: type,
      id: id,
      revision: revision,
      seq: seq,
      deleted: deleted,
      payload: deleted ? null : payload,
      updatedAt: _nowIso(),
    );
  }

  // -------------------------------------------------------------------------
  // HTTP 分发
  // -------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    if (offline) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/planner/health') {
        await _json(request, 200, _health());
        return;
      }
      if (request.method == 'POST' &&
          path == '/api/collections/users/auth-with-password') {
        await _authWithPassword(request);
        return;
      }
      if (request.method == 'POST' &&
          path == '/api/collections/users/auth-refresh') {
        await _authRefresh(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/planner/sync/push') {
        await _push(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/planner/sync/pull') {
        await _pull(request);
        return;
      }
      await _json(request, 404, <String, Object?>{
        'code': 'NOT_FOUND',
        'message': '路由不存在',
      });
    } on Object catch (error) {
      try {
        await _json(request, 500, <String, Object?>{
          'code': 'INTERNAL',
          'message': '$error',
          'retryable': true,
        });
      } on Object {
        // 连接已断开。
      }
    }
  }

  Map<String, Object?> _health() => <String, Object?>{
    'status': 'ok',
    'serverVersion': 'fake-pocketbase-1.0.0',
    'protocolVersion': protocolVersionOverride,
    'minSchemaVersion': 1,
    'maxSchemaVersion': 1,
    'serverTime': _nowIso(),
    'features': <String>['sync.push', 'sync.pull'],
    'limits': <String, Object?>{'maxOpsPerPush': 100, 'maxPullLimit': 500},
  };

  Future<void> _authWithPassword(HttpRequest request) async {
    final body = await _readJson(request);
    final email = (body['identity'] as String? ?? '').trim().toLowerCase();
    final password = body['password'] as String? ?? '';
    final account = _accountsByEmail[email];
    if (account == null || account.password != password) {
      await _json(request, 400, <String, Object?>{
        'code': 'AUTH_FAILED',
        'message': '账号或密码不正确',
        'retryable': false,
      });
      return;
    }
    final token = _issueToken(account.ownerId);
    await _json(request, 200, <String, Object?>{
      'token': token,
      'record': account.record,
    });
  }

  Future<void> _authRefresh(HttpRequest request) async {
    final token = _bearer(request);
    final account = _accountForToken(token);
    if (account == null) {
      await _json(request, 401, <String, Object?>{
        'code': 'TOKEN_EXPIRED',
        'message': '登录已过期',
        'retryable': false,
      });
      return;
    }
    _tokens.remove(token);
    await _json(request, 200, <String, Object?>{
      'token': _issueToken(account.ownerId),
      'record': account.record,
    });
  }

  // -------------------------------------------------------------------------
  // push
  // -------------------------------------------------------------------------

  Future<void> _push(HttpRequest request) async {
    pushRequestCount++;
    final account = _accountForToken(_bearer(request));
    if (account == null) {
      await _json(request, 401, _authError());
      return;
    }
    final body = await _readJson(request);
    final ownerId = account.ownerId;
    final bodyOwner = body['ownerId'];
    if (bodyOwner != null && bodyOwner != ownerId) {
      await _json(request, 403, <String, Object?>{
        'code': 'OWNER_MISMATCH',
        'message': 'ownerId 与登录账号不一致',
        'retryable': false,
      });
      return;
    }
    final ops = (body['ops'] as List<Object?>? ?? const <Object?>[]);
    if (ops.length > 100) {
      await _json(request, 400, <String, Object?>{
        'code': 'TOO_MANY_OPS',
        'message': '单批最多 100 条',
        'retryable': false,
      });
      return;
    }
    final deviceId = body['deviceId'] as String? ?? '';
    final results = <Map<String, Object?>>[];
    for (final raw in ops) {
      results.add(
        _applyOp(
          ownerId: ownerId,
          deviceId: deviceId,
          op: Map<String, Object?>.from(raw! as Map<Object?, Object?>),
        ),
      );
    }

    if (failNextPush) {
      failNextPush = false;
      await _json(request, 503, <String, Object?>{
        'code': 'MAINTENANCE',
        'message': '维护中',
        'retryable': true,
      });
      return;
    }
    if (dropNextPushResponse) {
      dropNextPushResponse = false;
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    await _json(request, 200, <String, Object?>{
      'protocolVersion': 1,
      'schemaVersion': 1,
      'ownerId': ownerId,
      'serverTime': _nowIso(),
      'results': results,
    });
  }

  Map<String, Object?> _applyOp({
    required String ownerId,
    required String deviceId,
    required Map<String, Object?> op,
  }) {
    final opId = op['opId'] as String? ?? '';
    final type = op['entityType'] as String? ?? '';
    final id = op['entityId'] as String? ?? '';
    final opType = op['opType'] as String? ?? '';
    final base = (op['baseRevision'] as num?)?.toInt() ?? -1;
    final payload = op['payload'] == null
        ? null
        : Map<String, Object?>.from(op['payload']! as Map<Object?, Object?>);
    final logKey = '$ownerId|$opId';
    final requestHash = _hash(<String, Object?>{
      'type': type,
      'id': id,
      'op': opType,
      'base': base,
      'payload': payload,
    });
    final existing = _ops[logKey];
    if (existing != null) {
      if (existing.requestHash == requestHash) {
        return <String, Object?>{
          ...existing.result,
          'status': 'duplicate',
          'duplicateOf': opId,
        };
      }
      return _result(opId, type, id, status: 'rejected', error: <String, Object?>{
        'code': 'OP_ID_REUSED',
        'message': '同一 opId 的内容不同',
        'retryable': false,
      });
    }

    final key = '$ownerId|$type|$id';
    final current = _entities[key];
    Map<String, Object?> result;

    if (opType == 'create') {
      if (current != null && !current.deleted) {
        result = _conflictResult(
          opId,
          type,
          id,
          current,
          kind: 'CREATE_EXISTS',
        );
      } else if (current != null && current.deleted) {
        result = _result(
          opId,
          type,
          id,
          status: 'rejected',
          error: <String, Object?>{
            'code': 'ENTITY_DELETED',
            'message': '实体已被删除，禁止复活',
            'retryable': false,
          },
        );
      } else if (payload == null) {
        result = _badPayload(opId, type, id);
      } else {
        final reference = _checkReferences(ownerId, type, payload, current: null);
        if (reference != null) {
          result = _result(opId, type, id, status: 'rejected', error: reference);
        } else if (type == 'note' && _noteDateTaken(ownerId, payload, id)) {
          result = _result(
            opId,
            type,
            id,
            status: 'conflict',
            conflict: <String, Object?>{
              'kind': 'NOTE_DATE_TAKEN',
              'serverRevision': 0,
              'serverDeleted': false,
              'serverPayload': null,
            },
          );
        } else {
          final seq = _nextSeq(ownerId);
          _entities[key] = _Entity(
            ownerId: ownerId,
            type: type,
            id: id,
            revision: 1,
            seq: seq,
            deleted: false,
            payload: payload,
            updatedAt: _nowIso(),
            deviceId: deviceId,
          );
          result = _result(
            opId,
            type,
            id,
            status: 'applied',
            revision: 1,
            seq: seq,
          );
        }
      }
    } else if (opType == 'update') {
      if (current == null) {
        result = _result(
          opId,
          type,
          id,
          status: 'rejected',
          error: <String, Object?>{
            'code': 'ENTITY_NOT_FOUND',
            'message': '实体不存在',
            'retryable': false,
          },
        );
      } else if (current.deleted) {
        result = _conflictResult(
          opId,
          type,
          id,
          current,
          kind: 'UPDATE_DELETE',
        );
      } else if (base != current.revision) {
        result = _conflictResult(
          opId,
          type,
          id,
          current,
          kind: 'UPDATE_UPDATE',
        );
      } else if (payload == null) {
        result = _badPayload(opId, type, id);
      } else {
        final reference = _checkReferences(ownerId, type, payload, current: current);
        if (reference != null) {
          result = _result(opId, type, id, status: 'rejected', error: reference);
        } else if (type == 'note' && _noteDateTaken(ownerId, payload, id)) {
          result = _conflictResult(
            opId,
            type,
            id,
            current,
            kind: 'NOTE_DATE_TAKEN',
          );
        } else if (_samePayload(current.payload, payload)) {
          result = _result(
            opId,
            type,
            id,
            status: 'applied',
            revision: current.revision,
            seq: current.seq,
            noOp: true,
          );
        } else {
          final seq = _nextSeq(ownerId);
          _entities[key] = _Entity(
            ownerId: ownerId,
            type: type,
            id: id,
            revision: current.revision + 1,
            seq: seq,
            deleted: false,
            payload: payload,
            updatedAt: _nowIso(),
            deviceId: deviceId,
          );
          result = _result(
            opId,
            type,
            id,
            status: 'applied',
            revision: current.revision + 1,
            seq: seq,
          );
        }
      }
    } else if (opType == 'delete') {
      if (current == null || current.deleted) {
        result = _result(
          opId,
          type,
          id,
          status: 'applied',
          revision: current?.revision ?? 0,
          seq: current?.seq ?? 0,
          noOp: true,
        );
      } else if (base != current.revision) {
        result = _conflictResult(
          opId,
          type,
          id,
          current,
          kind: 'DELETE_UPDATE',
        );
      } else {
        final seq = _nextSeq(ownerId);
        _entities[key] = _Entity(
          ownerId: ownerId,
          type: type,
          id: id,
          revision: current.revision + 1,
          seq: seq,
          deleted: true,
          payload: null,
          updatedAt: _nowIso(),
          deletedAt: _nowIso(),
          deviceId: deviceId,
        );
        _cascade(ownerId, type, id, deviceId);
        result = _result(
          opId,
          type,
          id,
          status: 'applied',
          revision: current.revision + 1,
          seq: seq,
        );
      }
    } else {
      result = _result(
        opId,
        type,
        id,
        status: 'rejected',
        error: <String, Object?>{
          'code': 'INVALID_OP_TYPE',
          'message': '未知 opType',
          'retryable': false,
        },
      );
    }

    _ops[logKey] = _OpLog(requestHash: requestHash, result: result);
    return result;
  }

  void _cascade(String ownerId, String type, String id, String deviceId) {
    if (type == 'project') {
      for (final entry in _entities.entries.toList()) {
        final entity = entry.value;
        if (entity.ownerId != ownerId || entity.deleted) continue;
        if (entity.type == 'span' && entity.payload?['projectId'] == id) {
          _tombstone(entity, deviceId);
        }
        if (entity.type == 'task' && entity.payload?['projectId'] == id) {
          _tombstone(entity, deviceId);
        }
      }
    } else if (type == 'span') {
      for (final entry in _entities.entries.toList()) {
        final entity = entry.value;
        if (entity.ownerId != ownerId || entity.deleted) continue;
        if (entity.type != 'task') continue;
        if (entity.payload?['spanId'] != id) continue;
        final nextSeq = _nextSeq(ownerId);
        final nextPayload = Map<String, Object?>.from(entity.payload!)
          ..['spanId'] = null;
        _entities[entry.key] = _Entity(
          ownerId: ownerId,
          type: 'task',
          id: entity.id,
          revision: entity.revision + 1,
          seq: nextSeq,
          deleted: false,
          payload: nextPayload,
          updatedAt: _nowIso(),
          deviceId: deviceId,
        );
      }
    }
  }

  void _tombstone(_Entity entity, String deviceId) {
    final seq = _nextSeq(entity.ownerId);
    _entities['${entity.ownerId}|${entity.type}|${entity.id}'] = _Entity(
      ownerId: entity.ownerId,
      type: entity.type,
      id: entity.id,
      revision: entity.revision + 1,
      seq: seq,
      deleted: true,
      payload: null,
      updatedAt: _nowIso(),
      deletedAt: _nowIso(),
      deviceId: deviceId,
    );
  }

  Map<String, Object?>? _checkReferences(
    String ownerId,
    String type,
    Map<String, Object?> payload, {
    required _Entity? current,
  }) {
    if (type == 'span') {
      final projectId = payload['projectId'];
      if (projectId is! String ||
          _entities['$ownerId|project|$projectId']?.deleted != false) {
        return <String, Object?>{
          'code': 'MISSING_REFERENCE',
          'message': '项目不存在',
          'retryable': false,
        };
      }
    }
    if (type == 'task') {
      final projectId = payload['projectId'];
      final spanId = payload['spanId'];
      if (projectId != null) {
        final project = _entities['$ownerId|project|$projectId'];
        if (project == null || project.deleted) {
          return <String, Object?>{
            'code': 'MISSING_REFERENCE',
            'message': '项目不存在',
            'retryable': false,
          };
        }
      }
      if (spanId != null) {
        final span = _entities['$ownerId|span|$spanId'];
        if (span == null ||
            span.deleted ||
            span.payload?['projectId'] != projectId) {
          return <String, Object?>{
            'code': 'MISSING_REFERENCE',
            'message': '阶段不存在或不属于该项目',
            'retryable': false,
          };
        }
      }
    }
    return null;
  }

  bool _noteDateTaken(
    String ownerId,
    Map<String, Object?> payload,
    String selfId,
  ) {
    final date = payload['date'];
    for (final entity in _entities.values) {
      if (entity.ownerId != ownerId ||
          entity.type != 'note' ||
          entity.deleted ||
          entity.id == selfId) {
        continue;
      }
      if (entity.payload?['date'] == date) return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // pull
  // -------------------------------------------------------------------------

  Future<void> _pull(HttpRequest request) async {
    pullRequestCount++;
    final account = _accountForToken(_bearer(request));
    if (account == null) {
      await _json(request, 401, _authError());
      return;
    }
    final body = await _readJson(request);
    final ownerId = account.ownerId;
    final mode = body['mode'] as String? ?? 'incremental';
    final snapshot = mode == 'snapshot';
    final requestedCursor = body['cursor'] as String?;
    pullCursors.add(requestedCursor);
    final limit = ((body['limit'] as num?)?.toInt() ?? 200).clamp(1, 500);
    final effectiveLimit = limit < pageSize ? limit : pageSize;

    if (resetRequiredNextPull) {
      resetRequiredNextPull = false;
      await _json(request, 409, <String, Object?>{
        'code': 'RESET_REQUIRED',
        'message': '游标不可用，必须重新快照',
        'retryable': false,
      });
      return;
    }

    final snapshotSeq = snapshot
        ? ((body['snapshotSeq'] as num?)?.toInt() ?? _maxSeq[ownerId] ?? 0)
        : null;
    final cursorSeq = _parseCursor(requestedCursor);
    final candidates = _entities.values
        .where((entity) => entity.ownerId == ownerId)
        .where((entity) => entity.seq > cursorSeq)
        .where(
          (entity) => !snapshot || entity.seq <= (snapshotSeq ?? 0),
        )
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));

    final page = candidates.take(effectiveLimit).toList(growable: false);
    final hasMore = candidates.length > page.length;
    final changes = <Map<String, Object?>>[];
    for (final entity in page) {
      changes.add(<String, Object?>{
        'entityType': entity.type,
        'entityId': entity.id,
        'schemaVersion': 1,
        'ownerId': ownerId,
        'serverRevision': entity.revision,
        'serverCursor': _cursor(entity.seq),
        'deleted': entity.deleted,
        'deletedAt': entity.deletedAt,
        'payload': entity.payload,
        'serverUpdatedAt': entity.updatedAt,
        'updatedByDevice': entity.deviceId ?? '',
      });
    }

    // 故障注入：让第 N 页出现非法实体，验证"整页回滚、游标不动"。
    if (corruptPushPage > 0 && pullRequestCount == corruptPushPage) {
      changes.add(<String, Object?>{
        'entityType': 'task',
        'entityId': 'corrupt',
        'serverRevision': 1,
        'serverCursor': _cursor(999999),
        'deleted': false,
        'payload': <String, Object?>{'title': '缺少必填字段'},
      });
    }

    final lastSeq = page.isEmpty
        ? cursorSeq
        : page.last.seq;
    final nextCursor = _cursor(lastSeq);
    await _json(request, 200, <String, Object?>{
      'protocolVersion': 1,
      'schemaVersion': 1,
      'ownerId': ownerId,
      'serverTime': _nowIso(),
      'mode': mode,
      'snapshot': snapshot,
      'snapshotSeq': snapshotSeq,
      'changes': changes,
      'nextCursor': nextCursor,
      'hasMore': hasMore,
      'resetRequired': false,
    });
  }

  // -------------------------------------------------------------------------
  // 结果构造
  // -------------------------------------------------------------------------

  Map<String, Object?> _result(
    String opId,
    String type,
    String id, {
    required String status,
    int? revision,
    int? seq,
    bool noOp = false,
    Map<String, Object?>? conflict,
    Map<String, Object?>? error,
  }) => <String, Object?>{
    'opId': opId,
    'entityType': type,
    'entityId': id,
    'status': status,
    if (revision != null) 'serverRevision': revision,
    if (seq != null) 'serverCursor': _cursor(seq),
    if (noOp) 'noOp': true,
    if (conflict != null) 'conflict': conflict,
    if (error != null) 'error': error,
    'appliedAt': _nowIso(),
  };

  Map<String, Object?> _conflictResult(
    String opId,
    String type,
    String id,
    _Entity current, {
    required String kind,
  }) => _result(
    opId,
    type,
    id,
    status: 'conflict',
    revision: current.revision,
    seq: current.seq,
    conflict: <String, Object?>{
      'kind': kind,
      'serverRevision': current.revision,
      'serverDeleted': current.deleted,
      'serverPayload': current.payload,
      'serverUpdatedAt': current.updatedAt,
      'serverUpdatedByDevice': current.deviceId,
      'serverCursor': _cursor(current.seq),
    },
  );

  Map<String, Object?> _badPayload(String opId, String type, String id) =>
      _result(
        opId,
        type,
        id,
        status: 'rejected',
        error: <String, Object?>{
          'code': 'VALIDATION_FAILED',
          'message': 'payload 缺失或非法',
          'retryable': false,
        },
      );

  // -------------------------------------------------------------------------
  // 辅助
  // -------------------------------------------------------------------------

  String _issueToken(String ownerId, {Duration? ttl}) {
    final expires = DateTime.now()
        .toUtc()
        .add(ttl ?? tokenTtlOverride ?? const Duration(hours: 2));
    final header = _b64(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'});
    final payload = _b64(<String, Object?>{
      'sub': ownerId,
      'exp': expires.millisecondsSinceEpoch ~/ 1000,
      'jti': _tokenSequence++,
    });
    final token = '$header.$payload.signature';
    _tokens[token] = _Token(ownerId: ownerId, expiresAt: expires);
    return token;
  }

  String? _bearer(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring(7);
  }

  _Account? _accountForToken(String? token) {
    if (token == null) return null;
    final stored = _tokens[token];
    if (stored == null) return null;
    if (DateTime.now().toUtc().isAfter(stored.expiresAt)) return null;
    return _accountsById[stored.ownerId];
  }

  Map<String, Object?> _authError() => <String, Object?>{
    'code': 'AUTH_REQUIRED',
    'message': '请先登录',
    'retryable': false,
  };

  int _nextSeq(String ownerId) {
    final next = (_maxSeq[ownerId] ?? 0) + 1;
    _maxSeq[ownerId] = next;
    return next;
  }

  String _cursor(int seq) => 'c1_${seq.toString().padLeft(16, '0')}';

  int _parseCursor(String? cursor) {
    if (cursor == null) return 0;
    final text = cursor.startsWith('c1_') ? cursor.substring(3) : cursor;
    return int.tryParse(text) ?? 0;
  }

  static Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return <String, Object?>{};
    final decoded = jsonDecode(text);
    return decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : <String, Object?>{};
  }

  static Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  static String _b64(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  static bool _samePayload(
    Map<String, Object?>? a,
    Map<String, Object?> b,
  ) {
    if (a == null) return false;
    final left = jsonEncode(_sorted(a));
    final right = jsonEncode(_sorted(b));
    return left == right;
  }

  static Object? _sorted(Object? value) {
    if (value is Map<Object?, Object?>) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _sorted(value[key]),
      };
    }
    if (value is List<Object?>) return value.map(_sorted).toList();
    return value;
  }

  static String _hash(Map<String, Object?> value) =>
      jsonEncode(_sorted(value));
}

final class _Account {
  const _Account({
    required this.ownerId,
    required this.email,
    required this.password,
    this.name,
  });

  final String ownerId;
  final String email;
  final String password;
  final String? name;

  Map<String, Object?> get record => <String, Object?>{
    'id': ownerId,
    'email': email,
    'name': name,
    'verified': true,
  };
}

final class _Token {
  const _Token({required this.ownerId, required this.expiresAt});

  final String ownerId;
  final DateTime expiresAt;
}

final class _Entity {
  const _Entity({
    required this.ownerId,
    required this.type,
    required this.id,
    required this.revision,
    required this.seq,
    required this.deleted,
    required this.payload,
    required this.updatedAt,
    this.deletedAt,
    this.deviceId,
  });

  final String ownerId;
  final String type;
  final String id;
  final int revision;
  final int seq;
  final bool deleted;
  final Map<String, Object?>? payload;
  final String updatedAt;
  final String? deletedAt;
  final String? deviceId;
}

final class _OpLog {
  const _OpLog({required this.requestHash, required this.result});

  final String requestHash;
  final Map<String, Object?> result;
}
