import 'package:flutter/gestures.dart'
    show kLongPressTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final today = LocalDate(2026, 11, 14);

  Future<
    ({
      InMemoryPlannerRepository repository,
      String alphaId,
      String betaId,
      String gammaId,
    })
  >
  pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = InMemoryPlannerRepository();
    final alpha = await repository.createProject(
      const ProjectDraft(name: '产品官网改版', color: ProjectColor.blue),
    );
    final beta = await repository.createProject(
      const ProjectDraft(name: '客户交付 · 星河', color: ProjectColor.teal),
    );
    final gamma = await repository.createProject(
      const ProjectDraft(name: '个人成长', color: ProjectColor.amber),
    );
    await tester.pumpWidget(
      PlannerApp(repository: repository, isDemoData: true, today: today),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('nav-projects')));
    await tester.pumpAndSettle();
    return (
      repository: repository,
      alphaId: alpha.id,
      betaId: beta.id,
      gammaId: gamma.id,
    );
  }

  Future<List<String>> projectOrder(InMemoryPlannerRepository repository) async {
    final projects = await repository.watchProjects().first;
    return projects.map((project) => project.name).toList();
  }

  Future<void> longPressDrag(
    WidgetTester tester,
    Finder item,
    double dy,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(item));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(0, dy / 2));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(0, dy / 2));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('长按拖动项目：列表顺序、仓储顺序、侧栏顺序一起变', (tester) async {
    final fixture = await pumpApp(tester);
    expect(await projectOrder(fixture.repository), <String>[
      '产品官网改版',
      '客户交付 · 星河',
      '个人成长',
    ]);

    // 把第一条往下拖过第二条。
    await longPressDrag(
      tester,
      find.byKey(ValueKey<String>('project-row-${fixture.alphaId}')),
      58,
    );

    expect(await projectOrder(fixture.repository), <String>[
      '客户交付 · 星河',
      '产品官网改版',
      '个人成长',
    ]);

    // 侧栏是同一个 watchProjects 流，顺序同步跟上。
    final sidebarBeta = tester
        .getTopLeft(find.byKey(ValueKey<String>('sidebar-project-${fixture.betaId}')))
        .dy;
    final sidebarAlpha = tester
        .getTopLeft(find.byKey(ValueKey<String>('sidebar-project-${fixture.alphaId}')))
        .dy;
    expect(sidebarBeta, lessThan(sidebarAlpha));
  });

  testWidgets('往回拖也能恢复顺序', (tester) async {
    final fixture = await pumpApp(tester);

    await longPressDrag(
      tester,
      find.byKey(ValueKey<String>('project-row-${fixture.alphaId}')),
      58,
    );
    expect((await projectOrder(fixture.repository)).first, '客户交付 · 星河');

    // 现在把「产品官网改版」（第 2 条）拖回第 1 条。
    await longPressDrag(
      tester,
      find.byKey(ValueKey<String>('project-row-${fixture.alphaId}')),
      -58,
    );
    expect((await projectOrder(fixture.repository)).first, '产品官网改版');
  });
}
