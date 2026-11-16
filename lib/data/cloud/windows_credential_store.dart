/// Windows 凭据管理器实现的安全令牌存储（advapi32 + DPAPI）。
///
/// 为什么不用文件：token 等价于账号密码。这里把会话 JSON 存进系统凭据库
/// （`CRED_TYPE_GENERIC` / `CRED_PERSIST_LOCAL_MACHINE`），磁盘上不存在
/// 可直接读取的明文。任何失败都抛 [CloudException]，**绝不**降级为明文文件。
///
/// 只使用 `dart:ffi` + kernel32 的 `LocalAlloc/LocalFree` 做内存分配，
/// 不新增第三方依赖（pubspec 由集成 Agent 维护）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../core/cloud/cloud_types.dart';
import 'secure_token_store.dart';

final class _CredentialW extends Struct {
  @Uint32()
  external int flags;

  @Uint32()
  external int type;

  external Pointer<Uint16> targetName;

  external Pointer<Uint16> comment;

  @Uint64()
  external int lastWritten;

  @Uint32()
  external int credentialBlobSize;

  external Pointer<Uint8> credentialBlob;

  @Uint32()
  external int persist;

  @Uint32()
  external int attributeCount;

  external Pointer<Void> attributes;

  external Pointer<Uint16> targetAlias;

  external Pointer<Uint16> userName;
}

typedef _CredWriteNative =
    Int32 Function(Pointer<_CredentialW> credential, Uint32 flags);
typedef _CredWriteDart =
    int Function(Pointer<_CredentialW> credential, int flags);

typedef _CredReadNative =
    Int32 Function(
      Pointer<Uint16> target,
      Uint32 type,
      Uint32 flags,
      Pointer<Pointer<_CredentialW>> out,
    );
typedef _CredReadDart =
    int Function(
      Pointer<Uint16> target,
      int type,
      int flags,
      Pointer<Pointer<_CredentialW>> out,
    );

typedef _CredDeleteNative =
    Int32 Function(Pointer<Uint16> target, Uint32 type, Uint32 flags);
typedef _CredDeleteDart =
    int Function(Pointer<Uint16> target, int type, int flags);

typedef _CredFreeNative = Void Function(Pointer<Void> buffer);
typedef _CredFreeDart = void Function(Pointer<Void> buffer);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

typedef _LocalAllocNative = Pointer<Void> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocDart = Pointer<Void> Function(int flags, int bytes);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> memory);

const int _credTypeGeneric = 1;
const int _credPersistLocalMachine = 2;
const int _errorNotFound = 1168;
const int _maxCredentialBlobSize = 5 * 512;
const int _lmptr = 0x0040;

final class WindowsCredentialStore implements SecureTokenStore {
  WindowsCredentialStore({this.targetPrefix = 'JihuaTai'});

  final String targetPrefix;

  static final bool _supported = Platform.isWindows;

  static _CredWriteDart? _credWrite;
  static _CredReadDart? _credRead;
  static _CredDeleteDart? _credDelete;
  static _CredFreeDart? _credFree;
  static _GetLastErrorDart? _getLastError;
  static _LocalAllocDart? _localAlloc;
  static _LocalFreeDart? _localFree;

  @override
  bool get isAvailable => _supported;

  static void _ensureBindings() {
    if (_credWrite != null) return;
    final advapi32 = DynamicLibrary.open('advapi32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _credWrite = advapi32
        .lookupFunction<_CredWriteNative, _CredWriteDart>('CredWriteW');
    _credRead = advapi32
        .lookupFunction<_CredReadNative, _CredReadDart>('CredReadW');
    _credDelete = advapi32
        .lookupFunction<_CredDeleteNative, _CredDeleteDart>('CredDeleteW');
    _credFree = advapi32
        .lookupFunction<_CredFreeNative, _CredFreeDart>('CredFree');
    _getLastError = kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
    _localAlloc = kernel32
        .lookupFunction<_LocalAllocNative, _LocalAllocDart>('LocalAlloc');
    _localFree = kernel32
        .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
  }

  @override
  Future<String?> read(String key) async {
    _ensureSupported();
    _ensureBindings();
    final targetPtr = _toNativeUint16(_targetName(key));
    final out = _allocate<Pointer<_CredentialW>>(sizeOf<Pointer<_CredentialW>>());
    try {
      final ok = _credRead!(targetPtr, _credTypeGeneric, 0, out);
      if (ok == 0) {
        final error = _getLastError!();
        if (error == _errorNotFound) return null;
        throw CloudException(
          CloudErrorKind.unknown,
          '读取系统安全存储失败（错误码 $error）',
        );
      }
      final credentialPtr = out.value;
      try {
        final credential = credentialPtr.ref;
        final size = credential.credentialBlobSize;
        if (size <= 0) return null;
        final bytes = Uint8List.fromList(
          credential.credentialBlob.asTypedList(size),
        );
        return _decodeBlob(bytes);
      } finally {
        _credFree!(credentialPtr.cast<Void>());
      }
    } finally {
      _free(targetPtr.cast<Void>());
      _free(out.cast<Void>());
    }
  }

  @override
  Future<void> write(String key, String value) async {
    _ensureSupported();
    _ensureBindings();
    final bytes = _encodeBlob(value);
    if (bytes.length > _maxCredentialBlobSize) {
      throw const CloudException(
        CloudErrorKind.unknown,
        '登录信息过大，无法写入系统凭据管理器',
      );
    }
    final targetPtr = _toNativeUint16(_targetName(key));
    final blobPtr = _allocate<Uint8>(bytes.length);
    final credentialPtr = _allocate<_CredentialW>(sizeOf<_CredentialW>());
    try {
      blobPtr.asTypedList(bytes.length).setAll(0, bytes);
      credentialPtr.ref
        ..flags = 0
        ..type = _credTypeGeneric
        ..targetName = targetPtr
        ..comment = nullptr
        ..lastWritten = 0
        ..credentialBlobSize = bytes.length
        ..credentialBlob = blobPtr
        ..persist = _credPersistLocalMachine
        ..attributeCount = 0
        ..attributes = nullptr
        ..targetAlias = nullptr
        ..userName = nullptr;
      final ok = _credWrite!(credentialPtr, 0);
      if (ok == 0) {
        final error = _getLastError!();
        throw CloudException(
          CloudErrorKind.unknown,
          '写入系统安全存储失败（错误码 $error）',
        );
      }
    } finally {
      _free(targetPtr.cast<Void>());
      _free(blobPtr.cast<Void>());
      _free(credentialPtr.cast<Void>());
    }
  }

  @override
  Future<void> delete(String key) async {
    _ensureSupported();
    _ensureBindings();
    final targetPtr = _toNativeUint16(_targetName(key));
    try {
      final ok = _credDelete!(targetPtr, _credTypeGeneric, 0);
      if (ok == 0) {
        final error = _getLastError!();
        if (error != _errorNotFound) {
          throw CloudException(
            CloudErrorKind.unknown,
            '删除系统安全存储失败（错误码 $error）',
          );
        }
      }
    } finally {
      _free(targetPtr.cast<Void>());
    }
  }

  String _targetName(String key) => '$targetPrefix/$key';

  void _ensureSupported() {
    if (!_supported) {
      throw const CloudException(
        CloudErrorKind.unknown,
        '当前平台不支持 Windows 凭据管理器，无法安全保存登录令牌',
      );
    }
  }

  static Pointer<T> _allocate<T extends NativeType>(int bytes) {
    final raw = _localAlloc!(_lmptr, bytes);
    if (raw == nullptr) {
      throw const CloudException(
        CloudErrorKind.unknown,
        '系统内存分配失败，无法访问凭据管理器',
      );
    }
    return raw.cast<T>();
  }

  static void _free(Pointer<Void> pointer) {
    if (pointer != nullptr) _localFree!(pointer);
  }

  static Pointer<Uint16> _toNativeUint16(String value) {
    final units = value.codeUnits;
    final pointer = _allocate<Uint16>((units.length + 1) * 2);
    final list = pointer.asTypedList(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      list[i] = units[i];
    }
    list[units.length] = 0;
    return pointer.cast<Uint16>();
  }

  static Uint8List _encodeBlob(String value) {
    final utf8Bytes = utf8.encode(value);
    if (utf8Bytes.length <= _maxCredentialBlobSize - 64) {
      return Uint8List.fromList(utf8Bytes);
    }
    return Uint8List.fromList(gzip.encode(utf8Bytes));
  }

  static String _decodeBlob(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return utf8.decode(gzip.decode(bytes));
    }
    return utf8.decode(bytes);
  }
}
