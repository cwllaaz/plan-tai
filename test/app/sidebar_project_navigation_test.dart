import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/app/app_scope.dart';
import 'package:jihuatai/app/app_shell.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final today = LocalDate(2026, 11, 14);

  Future<({InMemoryPlannerRepository repository, String alphaId, String betaId})>
  pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = InMemoryPlannerRepository();
    final alpha = await repository.createProject(
      const ProjectDraft(
        name: '产品官网改版',
        description: '官网信息架构与视觉重构。',
        color: ProjectColor.blue,
      ),
    );
    final beta = await repository.createProject(
      const ProjectDraft(
        name: '客户交付 · 星河',
        description: '数据看板与权限体系。',
        color: ProjectColor.teal,
      ),
    );
    await tester.pumpWidget(
      PlannerApp(repository: repository, isDemoData: true, today: today),
    );
    await tester.pumpAndSettle();
    return (
      repository: repository,
      alphaId: alpha.id,
      betaId: beta.id,
    );
  }

  Future<void> tapSidebarProject(WidgetTester tester, String id) async {
    await tester.tap(
      find.byKey(ValueKey<String>('sidebar-project-$id')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('从日历点侧栏项目：跳到项目页并选中该项目', (tester) async {
    final fixture = await pumpApp(tester);

    // 一开始在日历页。
    expect(find.text('月历'), findsOneWidget);

    await tapSidebarProject(tester, fixture.betaId);

    // 已经切到项目页，右侧详情是该项目的简介。
    expect(find.text('月历'), findsNothing);
    expect(find.text('客户交付 · 星河'), findsWidgets);
    expect(find.text('数据看板与权限体系。'), findsOneWidget);
  });

  testWidgets('已在项目页时，点侧栏另一个项目会切换详情', (tester) async {
    final fixture = await pumpApp(tester);

    await tapSidebarProject(tester, fixture.alphaId);
    expect(find.text('官网信息架构与视觉重构。'), findsOneWidget);

    await tapSidebarProject(tester, fixture.betaId);
    expect(find.text('数据看板与权限体系。'), findsOneWidget);

    // shell 里的焦点也跟着变了。
    final context = tester.element(find.byType(AppShell));
    expect(AppScope.of(context).shell.focusedProjectId, fixture.betaId);
  });

  testWidgets('点侧栏「管理项目」进入项目页', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('管理项目'));
    await tester.pumpAndSettle();

    expect(find.text('项目'), findsWidgets);
    expect(find.text('月历'), findsNothing);
  });
}
