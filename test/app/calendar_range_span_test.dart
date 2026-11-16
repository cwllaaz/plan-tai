import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/app.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final today = LocalDate(2026, 11, 14);

  Future<void> pumpApp(
    WidgetTester tester,
    InMemoryPlannerRepository repository,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PlannerApp(repository: repository, isDemoData: true, today: today),
    );
    await tester.pumpAndSettle();
  }

  /// 在月历上从 [fromIso] 右键拖到 [toIso]。
  Future<void> rightDrag(
    WidgetTester tester,
    String fromIso,
    String toIso,
  ) async {
    final from = tester
        .getRect(find.byKey(ValueKey<String>('day-$fromIso')))
        .center;
    final to = tester.getRect(find.byKey(ValueKey<String>('day-$toIso'))).center;

    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<Project?> unfiledProject(InMemoryPlannerRepository repository) async {
    final projects = await repository
        .watchProjects(includeArchived: true)
        .first;
    for (final project in projects) {
      if (project.name == '未归类') return project;
    }
    return null;
  }

  Future<List<PlanSpan>> spansInRange(
    InMemoryPlannerRepository repository,
  ) {
    return repository
        .watchSpansInRange(
          LocalDateRange(LocalDate(2026, 11, 1), LocalDate(2026, 11, 30)),
        )
        .first;
  }

  testWidgets('右键拖选 → 填名称选颜色 → 保存后进「未归类」并出现在月历', (tester) async {
    final repository = InMemoryPlannerRepository();
    await repository.createProject(
      const ProjectDraft(name: '产品官网改版', color: ProjectColor.blue),
    );
    await pumpApp(tester, repository);

    await rightDrag(tester, '2026-11-25', '2026-11-28');

    // 弹窗里不再有「归属项目」，只有名称 / 颜色 / 起止 / 状态 / 说明。
    expect(find.text('新建跨天安排'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('span-project-field')), findsNothing);
    expect(find.text('11月25日 – 11月28日 · 共 4 天'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('span-title-field')),
      '拖选出来的安排',
    );
    // 选一个红色。
    await tester.tap(
      find.byKey(const ValueKey<String>('span-color-#E5484D')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('span-submit')));
    await tester.pumpAndSettle();

    // 月历上出现这条横条。
    expect(find.text('拖选出来的安排'), findsOneWidget);

    final spans = await spansInRange(repository);
    expect(spans, hasLength(1));
    expect(spans.single.startDate, LocalDate(2026, 11, 25));
    expect(spans.single.endDate, LocalDate(2026, 11, 28));
    expect(spans.single.color, ProjectColor.red);

    final unfiled = await unfiledProject(repository);
    expect(unfiled, isNotNull);
    expect(spans.single.projectId, unfiled!.id);
  });

  testWidgets('没有项目时也能建：自动准备「未归类」分组', (tester) async {
    final repository = InMemoryPlannerRepository();
    await pumpApp(tester, repository);

    await rightDrag(tester, '2026-11-25', '2026-11-28');
    expect(find.text('新建跨天安排'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('span-title-field')),
      '先放未归类',
    );
    await tester.tap(find.byKey(const ValueKey<String>('span-submit')));
    await tester.pumpAndSettle();

    final unfiled = await unfiledProject(repository);
    expect(unfiled, isNotNull);
    final spans = await spansInRange(repository);
    expect(spans.single.projectId, unfiled!.id);
  });

  testWidgets('取消弹窗不会写库', (tester) async {
    final repository = InMemoryPlannerRepository();
    await pumpApp(tester, repository);

    await rightDrag(tester, '2026-11-25', '2026-11-28');
    expect(find.text('新建跨天安排'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await spansInRange(repository), isEmpty);
  });

  testWidgets('双击横条可以把安排归类到项目', (tester) async {
    final repository = InMemoryPlannerRepository();
    final project = await repository.createProject(
      const ProjectDraft(name: '产品官网改版', color: ProjectColor.blue),
    );
    final unfiled = await repository.createProject(
      const ProjectDraft(name: '未归类', color: ProjectColor.teal),
    );
    final span = await repository.createSpan(
      PlanSpanDraft(
        projectId: unfiled.id,
        title: '待归类安排',
        startDate: LocalDate(2026, 11, 25),
        endDate: LocalDate(2026, 11, 28),
      ),
    );
    await pumpApp(tester, repository);

    final bar = find.byKey(
      ValueKey<String>('span-${span.id}-2026-11-22'),
    );
    expect(bar, findsOneWidget);

    await tester.tap(bar);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(bar);
    await tester.pumpAndSettle();

    expect(find.text('编辑跨天安排'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('span-project-field')),
      findsOneWidget,
    );

    // 改归属项目。
    await tester.tap(find.byKey(const ValueKey<String>('span-project-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('产品官网改版').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('span-submit')));
    await tester.pumpAndSettle();

    final updated = await repository.findSpan(span.id);
    expect(updated!.projectId, project.id);
  });

  testWidgets('编辑弹窗里没有「状态」，但可以删除这条安排', (tester) async {
    final repository = InMemoryPlannerRepository();
    final unfiled = await repository.createProject(
      const ProjectDraft(name: '未归类', color: ProjectColor.teal),
    );
    final span = await repository.createSpan(
      PlanSpanDraft(
        projectId: unfiled.id,
        title: '要删掉的安排',
        startDate: LocalDate(2026, 11, 18),
        endDate: LocalDate(2026, 11, 24),
      ),
    );
    await pumpApp(tester, repository);

    final bar = find.byKey(
      ValueKey<String>('span-${span.id}-2026-11-15'),
    );
    expect(bar, findsOneWidget);

    await tester.tap(bar);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(bar);
    await tester.pumpAndSettle();

    expect(find.text('编辑跨天安排'), findsOneWidget);
    // 状态选择已经去掉。
    expect(find.text('状态'), findsNothing);
    expect(find.byType(DropdownButtonFormField<PlanSpanStatus>), findsNothing);

    // 删除需要二次确认。
    await tester.tap(find.byKey(const ValueKey<String>('span-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除这条安排？'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('span-delete-confirm')),
    );
    await tester.pumpAndSettle();

    expect(await repository.findSpan(span.id), isNull);
    expect(find.text('要删掉的安排'), findsNothing);
  });
}
