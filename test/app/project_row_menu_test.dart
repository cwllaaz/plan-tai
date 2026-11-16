import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final today = LocalDate(2026, 11, 14);

  /// 建好两个项目并进入项目页；返回仓储与项目 id。
  Future<({InMemoryPlannerRepository repository, String websiteId, String deliveryId})>
  pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = InMemoryPlannerRepository();
    final website = await repository.createProject(
      const ProjectDraft(name: '产品官网改版', color: ProjectColor.blue),
    );
    final delivery = await repository.createProject(
      const ProjectDraft(name: '客户交付 · 星河', color: ProjectColor.teal),
    );
    await tester.pumpWidget(
      PlannerApp(repository: repository, isDemoData: true, today: today),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('nav-projects')));
    await tester.pumpAndSettle();
    return (
      repository: repository,
      websiteId: website.id,
      deliveryId: delivery.id,
    );
  }

  Future<List<Project>> liveProjects(
    InMemoryPlannerRepository repository,
  ) async {
    return repository.watchProjects(includeArchived: true).first;
  }

  /// 在「项目」页左侧列表里右键某个项目（按行的 Key 定位，避开侧栏同名条目）。
  Future<void> rightClickRow(WidgetTester tester, String projectId) async {
    final row = find.byKey(ValueKey<String>('project-row-$projectId'));
    final gesture = await tester.startGesture(
      tester.getCenter(row),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('项目列表右键出现「删除项目」，确认后删除', (tester) async {
    final fixture = await pumpApp(tester);

    await rightClickRow(tester, fixture.deliveryId);
    // 详情页底部也有一个「删除项目」，这里只断言右键菜单里的那一项。
    expect(
      find.widgetWithText(PopupMenuItem<String>, '删除项目'),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, '删除项目'),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除项目？'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('project-row-delete-confirm')),
    );
    await tester.pumpAndSettle();

    final projects = await liveProjects(fixture.repository);
    expect(projects.map((project) => project.name), <String>['产品官网改版']);
    expect(
      find.byKey(ValueKey<String>('project-row-${fixture.deliveryId}')),
      findsNothing,
    );
  });

  testWidgets('右键菜单取消后不删除', (tester) async {
    final fixture = await pumpApp(tester);

    await rightClickRow(tester, fixture.deliveryId);
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, '删除项目'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect((await liveProjects(fixture.repository)), hasLength(2));
  });

  testWidgets('「未归类」右键菜单是禁用的，不能删除', (tester) async {
    final fixture = await pumpApp(tester);
    final unfiled = await fixture.repository.createProject(
      const ProjectDraft(name: '未归类', color: ProjectColor.blue),
    );
    await tester.pumpAndSettle();

    await rightClickRow(tester, unfiled.id);
    expect(find.text('系统分组，不能删除'), findsOneWidget);
    expect(
      find.widgetWithText(PopupMenuItem<String>, '删除项目'),
      findsNothing,
    );

    await tester.tap(find.text('系统分组，不能删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除项目？'), findsNothing);
    expect((await liveProjects(fixture.repository)), hasLength(3));
  });
}
