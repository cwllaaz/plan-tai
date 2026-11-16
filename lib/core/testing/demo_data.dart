import '../contracts/planner_repository.dart';
import '../models/models.dart';

/// 给内存仓储灌入一套覆盖各种边界的演示数据，供三个 Agent 并行开发 UI。
///
/// 数据刻意包含这些情况，方便界面自测：
/// - 跨月阶段（月初前 4 天到月初后 2 天）与同周多条阶段（车道冲突）；
/// - 有具体时刻的任务、只有日期没有时刻的任务、未排期收件箱任务；
/// - 已完成任务、紧急任务、无项目任务；
/// - 今天与昨天的每日备注，今天带 3 条「当日重点」。
///
/// **这些数据只存在于内存中**，正式数据模式（数据层 的 SQLite 实现）不会加载它们，
/// 也不会被写入磁盘。
Future<void> seedDemoData(
  PlannerRepository repository, {
  LocalDate? today,
}) async {
  final base = today ?? LocalDate.today();
  final monthStart = base.firstDayOfMonth;

  final website = await repository.createProject(
    const ProjectDraft(
      name: '产品官网改版',
      description: '把官网信息架构重做一遍，重点提升转化路径。',
      color: ProjectColor.blue,
      sortOrder: 0,
    ),
  );
  final delivery = await repository.createProject(
    const ProjectDraft(
      name: '客户交付 · 星河',
      description: 'Q4 交付里程碑：数据看板 + 权限体系。',
      color: ProjectColor.teal,
      sortOrder: 1,
    ),
  );
  final growth = await repository.createProject(
    const ProjectDraft(
      name: '个人成长',
      description: '阅读、写作与每周复盘。',
      color: ProjectColor.amber,
      sortOrder: 2,
    ),
  );

  // 跨月阶段：月初前 4 天 → 月初后 2 天，用来验证月历分段渲染。
  await repository.createSpan(
    PlanSpanDraft(
      projectId: website.id,
      title: '信息架构重做',
      startDate: monthStart.addDays(-4),
      endDate: monthStart.addDays(2),
      status: PlanSpanStatus.doing,
      sortOrder: 0,
    ),
  );
  await repository.createSpan(
    PlanSpanDraft(
      projectId: website.id,
      title: '视觉改版 v2',
      startDate: base.addDays(9),
      endDate: base.addDays(16),
      status: PlanSpanStatus.planned,
      sortOrder: 1,
    ),
  );
  // 同一周内相互重叠的两条阶段，用来验证车道分配。
  await repository.createSpan(
    PlanSpanDraft(
      projectId: delivery.id,
      title: '权限模型联调',
      startDate: base.addDays(-2),
      endDate: base.addDays(5),
      status: PlanSpanStatus.doing,
      sortOrder: 0,
    ),
  );
  await repository.createSpan(
    PlanSpanDraft(
      projectId: growth.id,
      title: '每周复盘',
      startDate: base.addDays(1),
      endDate: base.addDays(3),
      status: PlanSpanStatus.planned,
      sortOrder: 1,
    ),
  );

  Future<void> addTask(
    String title, {
    String? projectId,
    String? spanId,
    int dayOffset = 0,
    int? hour,
    int durationMinutes = 45,
    TaskPriority priority = TaskPriority.normal,
    TaskStatus status = TaskStatus.todo,
    String notes = '',
  }) async {
    await repository.createTask(
      PlannerTaskDraft(
        projectId: projectId,
        spanId: spanId,
        title: title,
        notes: notes,
        scheduledDate: dayOffset == 0 && hour == null && projectId == null
            ? null
            : base.addDays(dayOffset),
        timeSlot: hour == null
            ? null
            : TimeSlot.at(hour: hour, durationMinutes: durationMinutes),
        priority: priority,
        status: status,
      ),
    );
  }

  await addTask(
    '信息架构草案评审',
    projectId: website.id,
    hour: 9,
    durationMinutes: 60,
    priority: TaskPriority.urgent,
    notes: '拉上设计和市场一起过一遍导航层级。',
  );
  await addTask(
    '整理高流量页面清单',
    projectId: website.id,
    hour: 11,
    durationMinutes: 45,
    status: TaskStatus.done,
  );
  await addTask(
    '首页视觉稿 v2',
    projectId: website.id,
    dayOffset: 1,
    hour: 14,
    durationMinutes: 120,
    priority: TaskPriority.high,
  );
  await addTask(
    '组件库与设计规范对齐',
    projectId: website.id,
    dayOffset: 2,
    hour: 10,
    durationMinutes: 90,
  );
  await addTask(
    '可用性测试脚本',
    projectId: website.id,
    dayOffset: 5,
    priority: TaskPriority.high,
  );

  await addTask(
    '权限模型技术方案',
    projectId: delivery.id,
    dayOffset: 0,
    hour: 15,
    durationMinutes: 90,
    priority: TaskPriority.urgent,
    notes: 'RBAC + 数据行级权限，先给出最小可用方案。',
  );
  await addTask(
    '修复导出 Excel 乱码',
    projectId: delivery.id,
    dayOffset: -1,
    priority: TaskPriority.urgent,
    notes: '客户反馈 Windows 下中文表头乱码，需要带 BOM。',
  );
  await addTask(
    '准备周会演示环境',
    projectId: delivery.id,
    dayOffset: 2,
    hour: 16,
    durationMinutes: 45,
  );
  await addTask('交付验收清单', projectId: delivery.id, dayOffset: 7);

  await addTask(
    '读《深度工作》第 3 章',
    projectId: growth.id,
    hour: 21,
    durationMinutes: 30,
    priority: TaskPriority.low,
  );
  await addTask(
    '写一篇关于日历化时间管理的文章',
    projectId: growth.id,
    dayOffset: 4,
    priority: TaskPriority.low,
  );
  await addTask(
    '周复盘与下周计划',
    projectId: growth.id,
    dayOffset: 6,
    hour: 20,
    durationMinutes: 60,
  );

  await addTask('整理收件箱，清空待办');
  await addTask(
    '给导师回复邮件',
    hour: 18,
    durationMinutes: 15,
    priority: TaskPriority.high,
  );

  await repository.saveDailyNote(
    base,
    body: '上午把信息架构过完，下午专注权限方案。',
    focusItems: const <String>['信息架构评审', '权限模型方案', '读 30 页书'],
  );
  await repository.saveDailyNote(
    base.addDays(-1),
    body: '导出乱码排查了一下午，明天需要补一个带 BOM 的用例。',
  );
}
