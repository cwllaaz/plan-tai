import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:jihuatai/features/cloud_account/cloud_account.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

void main() {
  group('我的 / 账号与同步 / 数据', () {
    testWidgets('我的页入口齐全，离线时说明云同步未启用', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-tab-me');
      expect(find.textContaining('账号与同步'), findsOneWidget);
      expect(find.text('数据与备份'), findsOneWidget);
      expect(find.text('关于计划台'), findsOneWidget);
      expect(find.text('云同步未启用，本地数据照常可用'), findsOneWidget);

      await tapVisibleKey(tester, 'mobile-my-cloud');
      expect(find.text('云同步未启用'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mobile-cloud-offline')),
        findsOneWidget,
      );
      expect(find.text('登录'), findsNothing);
    });

    testWidgets('数据页显示演示模式与数据位置', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-tab-me');
      await tapVisibleKey(tester, 'mobile-my-data');

      expect(find.text('数据与备份'), findsWidgets);
      expect(find.text('内存（演示模式）'), findsOneWidget);
      expect(find.textContaining('演示模式使用内存数据'), findsOneWidget);
    });

    testWidgets('注入 Fake 云服务后，我的页显示未登录并可进入登录表单', (WidgetTester tester) async {
      final repository = await demoRepository();
      final fake = FakeCloudServices();
      final controller = CloudAccountController(services: fake.services);
      addTearDown(fake.close);

      await pumpMobileApp(
        tester,
        repository: repository,
        cloudServices: fake.services,
        cloudController: controller,
      );

      await tapKey(tester, 'mobile-tab-me');
      expect(find.textContaining('未登录'), findsWidgets);

      await tapVisibleKey(tester, 'mobile-my-cloud');
      // 集成后云端可用时直接复用 数据层 的移动端账号页（键名前缀 mobile-cloud-）。
      expect(
        find.byKey(const ValueKey<String>('mobile-cloud-server-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('mobile-cloud-account-field')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('顶部云端状态入口可打开账号页', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-cloud-entry');
      expect(find.text('账号与同步'), findsOneWidget);
      expect(find.text('离线模式'), findsOneWidget);
    });

    testWidgets('云端未启用时不会伪造登录墙，本地功能照常', (WidgetTester tester) async {
      final repository = InMemoryPlannerRepository();
      await seedDemoData(repository, today: testToday);
      await pumpMobileApp(tester, repository: repository);

      // 打开日历与当日面板都正常，不需要登录。
      await doubleTapDayCell(tester, testToday);
      expect(
        find.byKey(const ValueKey<String>('mobile-day-close')),
        findsOneWidget,
      );
      expect(find.text('登录'), findsNothing);
    });
  });
}
