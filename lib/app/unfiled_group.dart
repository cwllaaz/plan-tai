import '../core/contracts/contracts.dart';
import '../core/models/models.dart';

/// 未归类分组的名字。
///
/// 数据契约里 `PlanSpan.projectId` 是**必填**（阶段必须属于一个项目），
/// 所以"不归类"在实现上落在一个系统分组里：跨天安排默认进「未归类」，
/// 用户之后可以把它们挑到具体项目，也可以一直留在这里。
const String kUnfiledProjectName = '未归类';

/// 未归类分组的颜色：低饱和中性灰，和 8 色项目色板区分开。
final ProjectColor kUnfiledProjectColor = ProjectColor.fromHex('#8B94A3');

/// 取出（必要时创建）「未归类」分组。
///
/// 幂等：按名字查找，已存在就直接返回。创建时给一个中性灰，
/// 这样未归类的横条默认是灰色，选了阶段颜色则用阶段自己的颜色。
Future<Project> ensureUnfiledProject(PlannerRepository repository) async {
  final projects = await repository.watchProjects(includeArchived: true).first;
  for (final project in projects) {
    if (project.name == kUnfiledProjectName) return project;
  }
  return repository.createProject(
    ProjectDraft(
      name: kUnfiledProjectName,
      color: kUnfiledProjectColor,
      description: '没有归类到具体项目的跨天安排。可以随时移动到其他项目。',
    ),
  );
}
