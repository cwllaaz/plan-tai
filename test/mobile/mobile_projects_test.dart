import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/core/testing/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'mobile_test_helpers.dart';

void main() {
  group('项目页面', () {
    testWidgets('项目列表显示演示项目与任务计数', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-tab-projects');
      expect(find.text('产品官网改版'), findsWidgets);
      expect(find.text('客户交付 · 星河'), findsWidgets);
      expect(find.text('个人成长'), findsWidgets);
      expect(find.textContaining('项任务'), findsWidgets);
    });

    testWidgets('新建项目成功后出现在列表与仓储', (WidgetTester tester) async {
      final repository = await demoRepository();
      await pumpMobileApp(tester, repository: repository);

      await tapKey(tester, 'mobile-tab-projects');
      await tapKey(tester, 'mobile-project-create');
      await tester.enterText(
        find.byKey(const ValueKey<String>('mobile-project-editor-name')),
        '手机端新建的项目',
      );
      await tester.pumpAndSettle();
      await tapVisibleKey(tester, 'mobile-project-editor-save');

      final projects = await repository.watchProjects().first;
      expect(
        projects.where((Project project) => project.name == '手机端新建的项目'),
        hasLength(1),
      );
      expect(find.text('手机端新建的项目'), findsWidgets);
    });

    testWidgets('项目详情显示任务与安排，并可新建安排', (WidgetTester tester) async {
      final repository = await demoRepository();
      final projects = await repository.watchProjects().first;
      final project = projects.firstWhere(
        (Project item) => item.name == '产品官网改版',
      );
      final spans = await repository.watchSpansForProject(project.id).first;
      expect(spans, isNotEmpty);

      await pumpMobileApp(tester, repository: repository);
      await tapKey(tester, 'mobile-tab-projects');
      await tapVisibleKey(tester, 'mobile-project-${project.id}');

      expect(find.text('产品官网改版'), findsWidgets);
      expect(find.text('安排'), findsOneWidget);
      expect(find.text(spans.first.title), findsWidgets);

      await tapVisibleKey(tester, 'mobile-project-add-span');
      await tester.enterText(
        find.byKey(const ValueKey<String>('mobile-span-editor-title')),
        '手机端新建的时间阶段',
      );
      await tester.pumpAndSettle();
      await tapVisibleKey(tester, 'mobile-span-editor-save');

      final updated = await repository.watchSpansForProject(project.id).first;
      expect(updated.where((span) => span.title == '手机端新建的时间阶段'), hasLength(1));
    });

    testWidgets('项目内新建任务会自动带上该项目', (WidgetTester tester) async {
      final repository = await demoRepository();
      final projects = await repository.watchProjects().first;
      final project = projects.firstWhere(
        (Project item) => item.name == '客户交付 · 星河',
      );

      await pumpMobileApp(tester, repository: repository);
      await tapKey(tester, 'mobile-tab-projects');
      await tapVisibleKey(tester, 'mobile-project-${project.id}');

      await tapVisibleKey(tester, 'mobile-project-add-task');
      await tester.enterText(
        find.byKey(const ValueKey<String>('mobile-task-editor-title')),
        '归属到星河项目的新任务',
      );
      await tester.pumpAndSettle();
      await tapVisibleKey(tester, 'mobile-task-editor-save');

      final tasks = await repository.watchTasksForProject(project.id).first;
      expect(tasks.where((task) => task.title == '归属到星河项目的新任务'), hasLength(1));
    });

    testWidgets('归档项目默认隐藏，打开开关后可见', (WidgetTester tester) async {
      final repository = await demoRepository();
      final projects = await repository.watchProjects().first;
      final project = projects.firstWhere(
        (Project item) => item.name == '个人成长',
      );

      await pumpMobileApp(tester, repository: repository);
      await tapKey(tester, 'mobile-tab-projects');
      await tapVisibleKey(tester, 'mobile-project-${project.id}');

      await tapKey(tester, 'mobile-project-more');
      await tapVisibleKey(tester, 'mobile-project-action-archive');
      await tester.pumpAndSettle();

      final archived = await repository.findProject(project.id);
      expect(archived!.status, ProjectStatus.archived);

      await tapKey(tester, 'mobile-page-back');
      await tester.pumpAndSettle();
      expect(find.text('个人成长'), findsNothing);

      await tapVisibleKey(tester, 'mobile-projects-archived');
      expect(find.text('个人成长'), findsWidgets);
    });

    testWidgets('删除项目会级联删除其任务', (WidgetTester tester) async {
      final repository = await demoRepository();
      final projects = await repository.watchProjects().first;
      final project = projects.firstWhere(
        (Project item) => item.name == '客户交付 · 星河',
      );
      final tasksBefore = await repository
          .watchTasksForProject(project.id)
          .first;
      expect(tasksBefore, isNotEmpty);

      await pumpMobileApp(tester, repository: repository);
      await tapKey(tester, 'mobile-tab-projects');
      await tapVisibleKey(tester, 'mobile-project-${project.id}');

      await tapKey(tester, 'mobile-project-more');
      await tapVisibleKey(tester, 'mobile-project-action-delete');
      await tapKey(tester, 'mobile-confirm-ok');

      expect(await repository.findProject(project.id), isNull);
      final tasksAfter = await repository
          .watchTasksForProject(project.id)
          .first;
      expect(tasksAfter, isEmpty);
    });

    testWidgets('超长项目名不溢出', (WidgetTester tester) async {
      final repository = InMemoryPlannerRepository();
      await repository.createProject(
        const ProjectDraft(
          name:
              '这是一个特别特别长的项目名称，用来验证手机小屏上项目卡片不会因为文字太长而溢出布局'
              '（第二段补充说明）',
        ),
      );
      await pumpMobileApp(tester, repository: repository, size: phoneNarrow);
      await tapKey(tester, 'mobile-tab-projects');
      expect(tester.takeException(), isNull);
    });
  });
}
