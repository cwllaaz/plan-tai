import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/unfiled_group.dart';
import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../day/mobile_task_actions.dart';
import '../day/mobile_task_list.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_project_editor_sheet.dart';
import 'mobile_span_editor_sheet.dart';

/// 项目详情：项目信息、该项目下的任务、跨天阶段（安排）的查看与编辑。
class MobileProjectDetailPage extends StatefulWidget {
  const MobileProjectDetailPage({
    super.key,
    required this.repository,
    required this.projectId,
    required this.today,
  });

  final PlannerRepository repository;
  final String projectId;
  final LocalDate today;

  @override
  State<MobileProjectDetailPage> createState() =>
      _MobileProjectDetailPageState();
}

class _MobileProjectDetailPageState extends State<MobileProjectDetailPage> {
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  List<Project> _projects = const <Project>[];
  List<PlannerTask> _tasks = const <PlannerTask>[];
  List<PlanSpan> _spans = const <PlanSpan>[];

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant MobileProjectDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.projectId != widget.projectId) {
      _cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _listen() {
    final repository = widget.repository;
    _subscriptions
      ..add(
        repository.watchProjects(includeArchived: true).listen((
          List<Project> projects,
        ) {
          if (mounted) setState(() => _projects = projects);
        }),
      )
      ..add(
        repository.watchTasksForProject(widget.projectId).listen((
          List<PlannerTask> tasks,
        ) {
          if (mounted) setState(() => _tasks = tasks);
        }),
      )
      ..add(
        repository.watchSpansForProject(widget.projectId).listen((
          List<PlanSpan> spans,
        ) {
          if (mounted) setState(() => _spans = spans);
        }),
      );
  }

  Project? get _project {
    for (final project in _projects) {
      if (project.id == widget.projectId) return project;
    }
    return null;
  }

  bool get _isUnfiled => _project?.name == kUnfiledProjectName;

  Future<void> _editProject(Project project) async {
    final saved = await showMobileProjectEditorSheet(
      context,
      repository: widget.repository,
      initial: project,
    );
    if (!saved || !mounted) return;
    showMobileSnack(context, '项目已更新');
  }

  Future<void> _toggleArchive(Project project) async {
    final next = project.isArchived
        ? ProjectStatus.active
        : ProjectStatus.archived;
    try {
      await widget.repository.updateProject(project.copyWith(status: next));
      if (!mounted) return;
      showMobileSnack(
        context,
        next == ProjectStatus.archived ? '项目已归档' : '项目已恢复为进行中',
      );
    } on Object catch (error) {
      if (!mounted) return;
      showMobileError(context, error);
    }
  }

  Future<void> _deleteProject(Project project) async {
    final confirmed = await showMobileConfirm(
      context,
      title: '删除项目？',
      message:
          '「${project.name}」及其全部安排、任务都会被删除（软删除，可在备份中恢复）。'
          '删除后会立即从月历与项目列表移除。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await widget.repository.deleteProject(project.id);
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('项目已删除「${project.name}」')));
    } on Object catch (error) {
      if (!mounted) return;
      showMobileError(context, error);
    }
  }

  Future<void> _showActions(Project project) async {
    await showMobileSheet<void>(
      context,
      heightFactor: 0.5,
      builder: (BuildContext sheetContext) {
        return Column(
          children: <Widget>[
            MobileSheetHeader(
              title: project.name,
              subtitle: '项目操作',
              onClose: () => Navigator.of(sheetContext).pop(),
            ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  MobileListTile(
                    key: const ValueKey<String>('mobile-project-action-edit'),
                    title: '编辑名称与颜色',
                    leading: const Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_editProject(project));
                    },
                  ),
                  MobileListTile(
                    key: const ValueKey<String>(
                      'mobile-project-action-archive',
                    ),
                    title: project.isArchived ? '恢复为进行中' : '归档项目',
                    subtitle: _isUnfiled ? '「未归类」是系统分组，不能归档' : null,
                    leading: const Icon(
                      Icons.archive_outlined,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    onTap: _isUnfiled
                        ? null
                        : () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_toggleArchive(project));
                          },
                  ),
                  MobileListTile(
                    key: const ValueKey<String>('mobile-project-action-delete'),
                    title: '删除项目',
                    subtitle: _isUnfiled ? '「未归类」是系统分组，不能删除' : '会级联删除其下安排与任务',
                    leading: const Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: AppColors.danger,
                    ),
                    titleColor: _isUnfiled
                        ? AppColors.textDisabled
                        : AppColors.danger,
                    onTap: _isUnfiled
                        ? null
                        : () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_deleteProject(project));
                          },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _createTask(Project project) async {
    await openMobileTaskEditor(
      context,
      repository: widget.repository,
      projects: _projects,
      defaultDate: widget.today,
      today: widget.today,
      defaultProjectId: project.id,
    );
  }

  Future<void> _editTask(PlannerTask task) async {
    await openMobileTaskEditor(
      context,
      repository: widget.repository,
      projects: _projects,
      defaultDate: widget.today,
      today: widget.today,
      initial: task,
    );
  }

  Future<void> _createSpan(Project project) async {
    final saved = await showMobileSpanEditorSheet(
      context,
      repository: widget.repository,
      projectId: project.id,
      defaultStart: widget.today,
    );
    if (!saved || !mounted) return;
    showMobileSnack(context, '已保存安排');
  }

  Future<void> _editSpan(Project project, PlanSpan span) async {
    final saved = await showMobileSpanEditorSheet(
      context,
      repository: widget.repository,
      projectId: project.id,
      initial: span,
      defaultStart: widget.today,
    );
    if (!saved || !mounted) return;
    showMobileSnack(context, '已更新安排');
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            MobilePageHeader(
              title: project?.name ?? '项目',
              subtitle: project == null
                  ? '项目已删除'
                  : '${_tasks.length} 项任务 · ${_spans.length} 条安排',
              onBack: () => Navigator.of(context).maybePop(),
              actions: <Widget>[
                if (project != null) ...<Widget>[
                  MobileIconButton(
                    key: const ValueKey<String>('mobile-project-edit'),
                    icon: Icons.edit_outlined,
                    tooltip: '编辑项目',
                    onPressed: () => _editProject(project),
                  ),
                  MobileIconButton(
                    key: const ValueKey<String>('mobile-project-more'),
                    icon: Icons.more_horiz_rounded,
                    tooltip: '更多操作',
                    onPressed: () => _showActions(project),
                  ),
                ],
              ],
            ),
            Expanded(
              child: project == null
                  ? MobileEmptyState(
                      title: '项目已删除',
                      message: '这个项目可能已被删除或归档到别处。',
                      icon: Icons.folder_off_outlined,
                      actionLabel: '返回',
                      onAction: () => Navigator.of(context).maybePop(),
                    )
                  : _buildBody(project),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(Project project) {
    final done = _tasks.where((PlannerTask task) => task.isDone).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MobileMetrics.pagePadding,
        AppSpacing.md,
        MobileMetrics.pagePadding,
        AppSpacing.xxxl,
      ),
      children: <Widget>[
        MobileCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ProjectColorDot(color: project.color, size: 12),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    project.status.label,
                    style: AppText.caption.copyWith(fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    '完成 $done/${_tasks.length}',
                    style: AppText.numeric.copyWith(fontSize: 12),
                  ),
                ],
              ),
              if (project.description.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  project.description,
                  style: AppText.small.copyWith(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        MobileSectionHeader(
          title: '任务',
          subtitle: '该项目下的全部任务',
          trailing: MobileTextButton(
            key: const ValueKey<String>('mobile-project-add-task'),
            label: '新建',
            icon: Icons.add_rounded,
            onPressed: () => _createTask(project),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        MobileCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: MobileTaskList(
            repository: widget.repository,
            tasks: _tasks,
            projects: <String, Project>{project.id: project},
            today: widget.today,
            showDateLabel: true,
            onEditTask: _editTask,
            onAddTask: () => _createTask(project),
            emptyTitle: '这个项目还没有任务',
            emptyMessage: '新建任务会自动归属到本项目。',
            addLabel: '新建任务',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        MobileSectionHeader(
          title: '安排',
          subtitle: '跨天阶段，会显示为月历上的横条',
          trailing: MobileTextButton(
            key: const ValueKey<String>('mobile-project-add-span'),
            label: '新建',
            icon: Icons.add_rounded,
            onPressed: () => _createSpan(project),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        MobileCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: _spans.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    '还没有安排。安排适合表达「11月3日–11月7日 信息架构评审」这类跨天阶段。',
                    style: AppText.caption.copyWith(fontSize: 12.5),
                  ),
                )
              : Column(
                  children: <Widget>[
                    for (final span in _spans)
                      _SpanRow(
                        key: ValueKey<String>('mobile-span-${span.id}'),
                        span: span,
                        project: project,
                        onTap: () => _editSpan(project, span),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SpanRow extends StatelessWidget {
  const _SpanRow({
    super.key,
    required this.span,
    required this.project,
    required this.onTap,
  });

  final PlanSpan span;
  final Project project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = (span.color ?? project.color).uiColor;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: MobileMetrics.listRowMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 4,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      span.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong.copyWith(fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${monthDay(span.startDate)} – ${monthDay(span.endDate)} · ${span.lengthInDays} 天',
                      style: AppText.caption.copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              MobileTag(label: span.status.label),
              const SizedBox(width: AppSpacing.xs),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.textDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
