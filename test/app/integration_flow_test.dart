import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

/// 集成层流程测试：左侧导航 → 项目管理 / 任务列表 → 数据回流。
///
/// 与模块自己的测试不同，这里从 `PlannerApp` 整体启动，验证外壳、导航、
/// 页面与仓储流确实接在一起。
void main() {
  final today = LocalDate(2026, 11, 14);

  Future<InMemoryPlannerRepository> pumpEmpty(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = InMemoryPlannerRepository();
    await tester.pumpWidget(
      PlannerApp(repository: repository, isDemoData: true, today: today),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('项目管理：新建项目 → 添加跨天阶段 → 归档', (tester) async {
    await pumpEmpty(tester);

    await tester.tap(find.byKey(const ValueKey<String>('nav-projects')));
    await tester.pumpAndSettle();
    expect(find.text('还没有项目'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('projects-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('project-create-name')),
      '集成测试项目',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('project-create-submit')),
    );
    await tester.pumpAndSettle();

    // 左侧列表与右侧编辑区都显示新项目。
    expect(find.text('集成测试项目'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('project-name-field')),
      findsOneWidget,
    );

    // 添加跨天阶段。
    await tester.tap(find.byKey(const ValueKey<String>('span-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('span-title-field')),
      '跨天评审',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('span-start-field')),
      '2026-11-16',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('span-end-field')),
      '2026-11-20',
    );
    await tester.tap(find.byKey(const ValueKey<String>('span-submit')));
    await tester.pumpAndSettle();
    expect(find.text('跨天评审'), findsOneWidget);
    expect(find.textContaining('5 天', findRichText: true), findsWidgets);

    // 归档后从「项目」消失、出现在「归档」。
    await tester.tap(find.text('归档项目'));
    await tester.pumpAndSettle();
    expect(find.text('集成测试项目'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('nav-archive')));
    await tester.pumpAndSettle();
    expect(find.text('集成测试项目'), findsWidgets);
  });

  testWidgets('任务列表：勾选完成 → 从待办移入已完成', (tester) async {
    final repository = await pumpEmpty(tester);
    final project = await repository.createProject(
      const ProjectDraft(name: '任务测试项目'),
    );
    final task = await repository.createTask(
      PlannerTaskDraft(
        title: '集成任务一条',
        projectId: project.id,
        scheduledDate: today,
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.text('集成任务一条'), findsOneWidget);

    final row = find.byKey(ValueKey<String>('task-row-${task.id}'));
    expect(row, findsOneWidget);
    await tester.tap(
      find.descendant(of: row, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();

    // 待办列表里消失。
    expect(find.text('集成任务一条'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('nav-completed')));
    await tester.pumpAndSettle();
    expect(find.text('集成任务一条'), findsOneWidget);
  });

  testWidgets('侧栏只保留日历/项目/任务/已完成/归档，「今日」入口已移除', (tester) async {
    await pumpEmpty(tester);

    expect(find.byKey(const ValueKey<String>('nav-today')), findsNothing);
    for (final key in <String>[
      'nav-calendar',
      'nav-projects',
      'nav-tasks',
      'nav-completed',
      'nav-archive',
    ]) {
      expect(
        find.byKey(ValueKey<String>(key)),
        findsOneWidget,
        reason: '视图入口 $key 应该还在',
      );
    }
  });
}
