import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/features/cloud_account/util/conflict_presenter.dart';

import 'support/cloud_harness.dart';

void main() {
  group('冲突视图翻译', () {
    test('任务冲突：标题、类型、版本与字段差异', () {
      final data = ConflictViewData.from(demoConflict());

      expect(data.entityLabel, '任务');
      expect(data.title, '整理季度汇报材料');
      expect(data.kindLabel, '本机与云端都修改了同一条记录');
      expect(data.localVersionLabel, 'v3');
      expect(data.serverVersionLabel, 'v4');
      expect(data.localDeleted, isFalse);
      expect(data.serverDeleted, isFalse);

      final byField = <String, ConflictFieldDiff>{
        for (final diff in data.diffs) diff.field: diff,
      };
      expect(byField.keys, containsAll(<String>['title', 'timeSlot', 'notes']));
      expect(byField.keys, isNot(contains('scheduledDate')));
      expect(byField['timeSlot']!.localValue, '09:00–10:00');
      expect(byField['timeSlot']!.serverValue, '10:00–11:00');
      expect(byField['title']!.label, '标题');
      expect(byField['notes']!.localValue, '本机写的备注');
      expect(byField['notes']!.serverValue, '云端写的备注');
    });

    test('只有元数据不同时不算字段差异', () {
      final conflict = SyncConflict(
        id: 'conflict-same',
        entityType: CloudEntityType.task,
        entityId: 'task-0002',
        baseRevision: 1,
        serverRevision: 2,
        kind: ConflictKind.createExists,
        detectedAt: kCloudTestNow,
        localPayload: <String, Object?>{
          'id': 'task-0002',
          'title': '同一个标题',
          'revision': 1,
          'updatedAt': '2026-11-15T05:00:00Z',
        },
        serverPayload: <String, Object?>{
          'id': 'task-0002',
          'title': '同一个标题',
          'revision': 2,
          'updatedAt': '2026-11-15T05:05:00Z',
        },
      );
      final data = ConflictViewData.from(conflict);
      expect(data.diffs, isEmpty);
      expect(data.emptyDiffHint, contains('版本号'));
    });

    test('删除意图：缺失载荷显示为已删除', () {
      final conflict = SyncConflict(
        id: 'conflict-delete',
        entityType: CloudEntityType.task,
        entityId: 'task-0003',
        baseRevision: 2,
        serverRevision: 3,
        kind: ConflictKind.updateDelete,
        detectedAt: kCloudTestNow,
        localPayload: <String, Object?>{'title': '本机还想保留的任务'},
        serverPayload: null,
        serverDeleted: true,
      );
      final data = ConflictViewData.from(conflict);
      expect(data.serverDeleted, isTrue);
      expect(data.serverVersionLabel, '已删除');
      expect(data.diffs.any((diff) => diff.serverValue == '（已删除）'), isTrue);
    });

    test('备注冲突的标题带日期', () {
      final conflict = SyncConflict(
        id: 'conflict-note',
        entityType: CloudEntityType.note,
        entityId: 'note-1',
        baseRevision: 1,
        serverRevision: 2,
        kind: ConflictKind.noteDateTaken,
        detectedAt: kCloudTestNow,
        localPayload: <String, Object?>{'date': '2026-11-15', 'body': '今天的重点'},
        serverPayload: <String, Object?>{'date': '2026-11-15', 'body': '云端的重点'},
      );
      final data = ConflictViewData.from(conflict);
      expect(data.entityLabel, '每日备注');
      expect(data.title, contains('2026-11-15 备注'));
    });
  });
}
