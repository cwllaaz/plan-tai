import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/contracts/contracts.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/features/cloud_account/cloud_account.dart';
import 'package:jihuatai/mobile/mobile_app.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 测试固定「今天」：2026-11-14（周六），演示数据围绕这一天生成。
final LocalDate testToday = LocalDate(2026, 11, 14);

/// 手机竖屏、平板竖屏、平板横屏、最小可用宽度等常用尺寸。
const Size phoneNarrow = Size(320, 640);
const Size phoneSmall = Size(360, 800);
const Size phone = Size(412, 915);
const Size tabletPortrait = Size(800, 1280);
const Size tabletLandscape = Size(1280, 800);
const Size mediumWidth = Size(600, 960);

/// 建一个带演示数据的内存仓储（不写磁盘、不需要网络）。
Future<InMemoryPlannerRepository> demoRepository() async {
  final repository = InMemoryPlannerRepository();
  await seedDemoData(repository, today: testToday);
  return repository;
}

/// 给测试注入固定画布尺寸与像素比。
void useViewSize(WidgetTester tester, Size size, {double textScale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// 启动移动端应用（默认演示数据 + 离线云）。
Future<void> pumpMobileApp(
  WidgetTester tester, {
  required PlannerRepository repository,
  Size size = phone,
  double textScale = 1.0,
  CloudServices? cloudServices,
  CloudAccountController? cloudController,
}) async {
  useViewSize(tester, size, textScale: textScale);
  await tester.pumpWidget(
    MobileApp(
      repository: repository,
      isDemoData: true,
      today: testToday,
      cloudServices: cloudServices,
      cloudController: cloudController,
    ),
  );
  await tester.pumpAndSettle();
}

/// 等待某段时间并让界面稳定（备注防抖 600ms 等）。
Future<void> settleFor(WidgetTester tester, Duration duration) async {
  await tester.pump(duration);
  await tester.pumpAndSettle();
}

/// 单击月历格子（格子同时注册了单击/双击，单击回调要等双击判定超时）。
Future<void> tapDayCell(WidgetTester tester, LocalDate date) async {
  final cell = find.byKey(ValueKey<String>('mobile-day-${date.iso}'));
  expect(cell, findsOneWidget, reason: '找不到日期格 ${date.iso}');
  await tester.tap(cell);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// 双击月历格子（打开当日详情面板）。
Future<void> doubleTapDayCell(WidgetTester tester, LocalDate date) async {
  final cell = find.byKey(ValueKey<String>('mobile-day-${date.iso}'));
  expect(cell, findsOneWidget, reason: '找不到日期格 ${date.iso}');
  await tester.tap(cell);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(cell);
  await tester.pumpAndSettle();
}

/// 点击带 key 的控件并稳定。
Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: '找不到 $key');
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 先滚动到可见再点击（列表里的行可能在视口外）。
Future<void> tapVisibleKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: '找不到 $key');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 载入系统中文字体，让 golden 截图里的中文可读（而不是方块）。
///
/// 同时载入 Flutter SDK 自带的 MaterialIcons 字形，否则截图里所有图标都是方框。
/// 找不到字体时返回 false，调用方应跳过截图断言；其他自动化测试不依赖字体。
Future<bool> loadChineseTestFont() async {
  var loaded = false;
  const candidates = <String>[
    'C:/Windows/Fonts/simhei.ttf',
    'C:/Windows/Fonts/Deng.ttf',
    'C:/Windows/Fonts/msyh.ttc',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      await _loadFontFile('Microsoft YaHei UI', file);
      loaded = true;
      break;
    } on Object {
      continue;
    }
  }
  final iconFont = _materialIconFontFile();
  if (iconFont != null) {
    try {
      await _loadFontFile('MaterialIcons', iconFont);
    } on Object {
      // 图标字体加载失败只影响截图观感，不影响断言。
    }
  }
  return loaded;
}

Future<void> _loadFontFile(String family, File file) async {
  final bytes = ByteData.sublistView(
    Uint8List.fromList(await file.readAsBytes()),
  );
  final loader = FontLoader(family)..addFont(Future<ByteData>.value(bytes));
  await loader.load();
}

/// 从 `flutter_tester` 可执行文件位置反推 Flutter SDK 的 MaterialIcons 字体。
File? _materialIconFontFile() {
  final envRoot = (Platform.environment['FLUTTER_ROOT'] ?? '').trim();
  if (envRoot.isNotEmpty) {
    final file = File(
      p.join(
        envRoot,
        'bin',
        'cache',
        'artifacts',
        'material_fonts',
        'materialicons-regular.otf',
      ),
    );
    if (file.existsSync()) return file;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = File(
      p.join(
        directory.path,
        'artifacts',
        'material_fonts',
        'materialicons-regular.otf',
      ),
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}
