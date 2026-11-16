import 'dart:math';
import 'dart:typed_data';

import 'planner_exception.dart';

/// 稳定唯一 ID 的生成与校验。
///
/// 统一使用 RFC 9562 **UUIDv7**：前 48 位是毫秒时间戳，天然按创建时间排序，
/// 适合未来做增量同步与分页；客户端可离线生成，不依赖数据库自增。
/// 详见 docs/DATA_CONTRACT.md。
abstract final class Ids {
  static final Random _random = Random.secure();
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// 生成一个新的 UUIDv7。
  ///
  /// [now] 仅用于测试注入固定时刻；正式调用不传。
  static String newId({DateTime? now}) {
    final millis = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final bytes = Uint8List(16);

    // 48 bit 毫秒时间戳（大端）
    for (var i = 0; i < 6; i++) {
      bytes[i] = (millis >> (8 * (5 - i))) & 0xFF;
    }
    // 74 bit 随机量
    for (var i = 6; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    // version = 7
    bytes[6] = (bytes[6] & 0x0F) | 0x70;
    // variant = 10xx
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      if (i == 3 || i == 5 || i == 7 || i == 9) hex.write('-');
    }
    return hex.toString();
  }

  /// 校验是否为合法的小写 UUIDv7。外部输入（导入备份、同步载荷）先用它把关。
  static bool isValid(String value) => _uuidPattern.hasMatch(value);

  /// 校验任意 UUID 形状（含 v4 等历史数据），仅用于宽松场景。
  static bool isValidAnyVersion(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(value);

  /// 断言型校验，失败抛 [PlannerValidationException]。
  static String requireValid(String value, {String field = 'ID'}) {
    if (!isValidAnyVersion(value)) {
      throw PlannerValidationException('$field 不是合法的 UUID：$value');
    }
    return value;
  }
}
