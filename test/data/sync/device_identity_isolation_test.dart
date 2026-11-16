import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/data/sync/device_identity.dart';
import 'package:path/path.dart' as p;

/// 验证“设备标识跟随数据目录”的契约：
/// Linux 使用自己的数据目录（`~/.local/share/计划台`）时会生成**独立**的 device.json，
/// 不会复制或复用 Windows 的 device ID。
void main() {
  test('不同数据目录生成不同设备标识，同目录保持稳定', () {
    final dirA = Directory.systemTemp.createTempSync('jihuatai_device_a_');
    final dirB = Directory.systemTemp.createTempSync('jihuatai_device_b_');
    try {
      final idA = DeviceIdentityStore.forDirectory(dirA.path).deviceId;
      final idB = DeviceIdentityStore.forDirectory(dirB.path).deviceId;

      expect(idA, isNotEmpty);
      expect(idB, isNotEmpty);
      expect(idA, isNot(idB), reason: '两个数据目录（模拟 Windows/Linux 各自安装）不能共用设备标识');

      // 同一目录再次读取必须稳定（进程重启后从 device.json 读取）
      expect(DeviceIdentityStore.forDirectory(dirA.path).deviceId, idA);
      expect(DeviceIdentityStore.forDirectory(dirB.path).deviceId, idB);

      final json =
          jsonDecode(File(p.join(dirA.path, 'device.json')).readAsStringSync())
              as Map<String, Object?>;
      expect(json['deviceId'], idA);
      expect(json['platform'], Platform.operatingSystem);
      expect(json['createdAt'], isA<String>());
    } finally {
      dirA.deleteSync(recursive: true);
      dirB.deleteSync(recursive: true);
    }
  });

  test('device.json 不包含 token/账号等敏感字段（只放设备身份）', () {
    final dir = Directory.systemTemp.createTempSync('jihuatai_device_fields_');
    try {
      DeviceIdentityStore.forDirectory(dir.path).deviceId;
      final json =
          jsonDecode(File(p.join(dir.path, 'device.json')).readAsStringSync())
              as Map<String, Object?>;
      expect(json.keys, containsAll(<String>['deviceId', 'createdAt', 'platform']));
      expect(json.keys, isNot(contains('token')));
      expect(json.keys, isNot(contains('email')));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
