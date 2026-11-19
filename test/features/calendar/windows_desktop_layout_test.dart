import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/app/app_scope.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/features/calendar/day_cell.dart';
import 'package:jihuatai/features/calendar/month_grid.dart';
import 'package:jihuatai/features/day_detail/day_detail_panel.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('六周密集月历和长列表在逻辑窗口、DPR 变化后仍可点选和保存', (tester) async {
    await _loadEvidenceFonts(tester);
    final day = LocalDate(2027, 1, 2);
    final repo = InMemoryPlannerRepository();
    await seedDemoData(repo, today: day);
    final project = await repo.createProject(
      ProjectDraft(name: '长中文项目名称与进度说明' * 6, color: ProjectColor.blue),
    );
    final lastTaskTitle = '这是需要在月底前完成的中文任务标题' * 6;
    final tasks = <PlannerTask>[];
    for (var index = 0; index < 12; index++) {
      tasks.add(
        await repo.createTask(
          PlannerTaskDraft(
            title: index == 11 ? lastTaskTitle : '密集演示任务 $index',
            scheduledDate: day,
            projectId: project.id,
            notes: '备注：核对项目、时间和明确的交付结果。',
            timeSlot: TimeSlot.at(hour: index + 8, durationMinutes: 30),
          ),
        ),
      );
    }
    for (var index = 0; index < 4; index++) {
      await repo.createSpan(
        PlanSpanDraft(
          projectId: project.id,
          title: '跨周密集安排 $index',
          startDate: day.addDays(-1),
          endDate: day.addDays(2),
        ),
      );
    }

    void window(Size logical, double dpr) {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = logical * dpr;
    }

    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    window(const Size(1440, 900), 1);
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: PlannerApp(repository: repo, today: day, isDemoData: true),
      ),
    );
    await tester.pumpAndSettle();
    Finder cell(String iso) => find.byKey(ValueKey('day-$iso'));
    Finder inDay(Finder child) =>
        find.descendant(of: cell(day.iso), matching: child);
    final week = find.byKey(const ValueKey('week-2026-12-27'));
    expect(find.byType(DayCell), findsNWidgets(42));
    expect(
      find.descendant(of: week, matching: find.byType(DayCell)),
      findsNWidgets(7),
    );
    final dense = tester.widget<DayCell>(cell(day.iso));
    expect(inDay(find.text('+${dense.tasks.length - 3} 项')), findsOneWidget);
    final hidden = dense.hiddenSpanCount;
    expect(hidden, greaterThanOrEqualTo(2));
    expect(inDay(find.text('+$hidden')), findsOneWidget);
    expect(
      find.descendant(of: cell('2026-12-29'), matching: find.text('+2')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, capture, 'after-six-weeks-1440x900');

    final stamp = find.byKey(ValueKey('day-badge-${day.iso}'));
    await tester.tapAt(tester.getCenter(stamp));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(DayDetailPanel), findsNothing);
    final target = tester.getCenter(stamp);
    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(target);
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailPanel), findsOneWidget);
    await _capture(tester, capture, 'after-day-1440x900');

    final panel = find.byType(DayDetailPanel);
    final timeline = find
        .descendant(of: panel, matching: find.byType(ListView))
        .last;
    final list = find.descendant(
      of: timeline,
      matching: find.byType(Scrollable),
    );
    final edit = find.byKey(ValueKey('task-edit-${tasks.last.id}'));
    await tester.scrollUntilVisible(edit, 220, scrollable: list);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('task-editor-title'));
    String draftTitle() => tester.widget<TextField>(title).controller!.text;
    expect(draftTitle(), lastTaskTitle);
    const draft = '窗口缩放后仍能保存的中文草稿';
    await tester.enterText(title, draft);
    await tester.pumpAndSettle();

    for (final dpr in [1.25, 1.5, 1.0]) {
      window(const Size(1100, 700), dpr);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(AppScope.of(tester.element(panel)).shell.selectedDate, day);
      expect(draftTitle(), draft);
      expect(find.byType(DayCell), findsNWidgets(42));
    }
    final save = find.byKey(const ValueKey('task-editor-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    await _capture(tester, capture, 'after-save-1100x700');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect((await repo.findTask(tasks.last.id))?.title, draft);

    final calendar = find.byType(MonthGridBody);
    final scrollable = find.descendant(
      of: calendar,
      matching: find.byType(Scrollable),
    );
    final lastDate = cell('2027-01-31');
    expect(lastDate.hitTestable(), findsNothing);
    await tester.scrollUntilVisible(lastDate, 130, scrollable: scrollable);
    final end = tester.getCenter(lastDate);
    final start =
        tester.getRect(cell('2027-01-30')).topCenter + const Offset(0, 12);
    final rightDrag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await rightDrag.moveTo(end);
    await tester.pump();
    expect(find.byKey(const ValueKey('calendar-range-box')), findsOneWidget);
    await rightDrag.up();
    await tester.pumpAndSettle();
    expect(find.text('新建跨天安排'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _loadEvidenceFonts(WidgetTester tester) async {
  if (Platform.environment['JIHUATAI_LAYOUT_EVIDENCE'] == null ||
      !Platform.isWindows) {
    return;
  }
  await tester.binding.runAsync(() async {
    final systemRoot = Platform.environment['WINDIR'];
    final fonts = {
      'Microsoft YaHei UI': '$systemRoot/Fonts/msyh.ttc',
      'MaterialIcons':
          'build/windows/x64/runner/Release/data/flutter_assets/'
          'fonts/MaterialIcons-Regular.otf',
    };
    for (final entry in fonts.entries) {
      final font = File(entry.value);
      if (font.existsSync()) {
        await (FontLoader(
          entry.key,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
}

/// 可选输出同一套演示数据的 Flutter 帧，普通测试不生成文件。
Future<void> _capture(WidgetTester tester, GlobalKey root, String label) async {
  final output = Platform.environment['JIHUATAI_LAYOUT_EVIDENCE'];
  if (output == null) return;
  await tester.binding.runAsync(() async {
    final boundary =
        root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('$output/$label.png').writeAsBytes(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
