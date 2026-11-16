import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';

import '../core/contracts/contracts.dart';
import '../core/format/format.dart';
import '../core/models/models.dart';
import '../core/theme/theme.dart';
import 'form_fields.dart';
import 'shell_state.dart';
import 'span_editor_dialog.dart';
import 'unfiled_group.dart';

/// 项目管理页（V1 正式功能）。
///
/// 左侧是项目列表（项目 / 归档两个入口共用本页），右侧是所选项的编辑区：
/// 名称、简介、颜色、状态，以及该项目的跨天阶段（新增 / 编辑 / 删除）。
/// 所有数据都来自仓储流，保存后月历与侧栏会自动刷新。
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({
    super.key,
    required this.repository,
    required this.shell,
    this.archivedOnly = false,
  });

  final PlannerRepository repository;
  final PlannerShellState shell;

  /// true 时只展示已归档项目（左侧「归档」入口）。
  final bool archivedOnly;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.shell.focusedProjectId;
    // 侧栏点某个项目时，shell 会先把 focusedProjectId 改成它再切到本页；
    // 如果本页已经在显示，就必须跟着这个变化走，否则"点侧栏没反应"。
    widget.shell.addListener(_onShellChanged);
  }

  @override
  void didUpdateWidget(covariant ProjectsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shell != widget.shell) {
      oldWidget.shell.removeListener(_onShellChanged);
      widget.shell.addListener(_onShellChanged);
      _selectedId = widget.shell.focusedProjectId;
      return;
    }
    // 注意：不能比较 oldWidget.shell.focusedProjectId——两个字段是同一个对象，
    // 永远相等。要跟状态变化只能靠监听。
    _onShellChanged();
  }

  @override
  void dispose() {
    widget.shell.removeListener(_onShellChanged);
    super.dispose();
  }

  void _onShellChanged() {
    final focused = widget.shell.focusedProjectId;
    if (focused == null || focused == _selectedId) return;
    if (!mounted) return;
    setState(() => _selectedId = focused);
  }

  Project? _pick(List<Project> projects) {
    for (final project in projects) {
      if (project.id == _selectedId) return project;
    }
    return projects.isEmpty ? null : projects.first;
  }

  void _notify(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: error ? AppColors.danger : null,
      ),
    );
  }

  Future<void> _createProject() async {
    final draft = await showDialog<ProjectDraft>(
      context: context,
      builder: (context) => const _ProjectCreateDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      final project = await widget.repository.createProject(draft);
      if (!mounted) return;
      setState(() => _selectedId = project.id);
      widget.shell.focusProject(project.id);
      _notify('已创建项目「${project.name}」');
    } on PlannerException catch (error) {
      _notify(error.message, error: true);
    }
  }

  /// 列表里右键 → 删除项目（带二次确认）。
  ///
  /// 和详情页的「删除项目」是同一套语义：项目连同阶段、任务一起软删除，可从备份恢复。
  Future<void> _deleteProjectFromList(Project project) async {
    if (project.name == kUnfiledProjectName) {
      _notify('「未归类」是系统分组，不能删除；可以把里面的安排改到其他项目', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目？'),
        content: Text(
          '「${project.name}」及其全部阶段、任务都会被删除（可在备份中恢复）。'
          '此操作会立即从月历与列表中移除。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('project-row-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deleteProject(project.id);
      if (!mounted) return;
      if (_selectedId == project.id) {
        setState(() => _selectedId = null);
        widget.shell.focusProject(null);
      }
      _notify('项目已删除「${project.name}」');
    } on PlannerException catch (error) {
      if (!mounted) return;
      _notify(error.message, error: true);
    }
  }

  /// 长按拖动调换顺序：把被拖动项按新位置落定，再按 0..n-1 重写 sortOrder。
  ///
  /// 仓储按 `sortOrder ↑ → createdAt ↑` 排序，所以侧栏（同一个 watchProjects 流）
  /// 会跟着一起变；列表里只重写"顺序真的变了"的那些项目，避免无谓的 revision +1。
  Future<void> _reorderProjects(
    List<Project> ordered,
    int oldIndex,
    int newIndex,
  ) async {
    // onReorderItem 给的是"移除之后"的目标下标，直接用即可。
    final target = newIndex.clamp(0, ordered.length - 1);
    if (target == oldIndex) return;
    final next = <Project>[...ordered];
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);

    try {
      for (var index = 0; index < next.length; index++) {
        final project = next[index];
        if (project.sortOrder == index) continue;
        await widget.repository.updateProject(project.copyWith(sortOrder: index));
      }
      if (!mounted) return;
      _notify('项目顺序已更新');
    } on PlannerException catch (error) {
      if (!mounted) return;
      _notify(error.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Project>>(
      stream: widget.repository.watchProjects(includeArchived: true),
      builder: (context, snapshot) {
        final all = snapshot.data ?? const <Project>[];
        final projects = all
            .where(
              (project) => widget.archivedOnly
                  ? project.isArchived
                  : !project.isArchived,
            )
            .toList(growable: false);
        final selected = _pick(projects);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _PageHeader(
              title: widget.archivedOnly ? '归档' : '项目',
              subtitle: widget.archivedOnly
                  ? '已归档的项目不再出现在侧栏与月历中，可随时恢复。'
                  : '项目是任务与跨天阶段的归属单元，颜色会同步到月历。',
              count: projects.length,
              action: widget.archivedOnly
                  ? null
                  : FilledButton.icon(
                      key: const ValueKey<String>('projects-new'),
                      onPressed: _createProject,
                      icon: const Icon(
                        Icons.add_rounded,
                        size: AppSizes.iconSm,
                      ),
                      label: const Text('新建项目'),
                    ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadius.panel,
                  border: Border.all(color: AppColors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: projects.isEmpty
                    ? _EmptyProjects(
                        archivedOnly: widget.archivedOnly,
                        onCreate: _createProject,
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(
                            width: 280,
                            child: _ProjectList(
                              projects: projects,
                              selectedId: selected?.id,
                              onSelect: (project) {
                                setState(() => _selectedId = project.id);
                                widget.shell.focusProject(project.id);
                              },
                              onDelete: _deleteProjectFromList,
                              onReorder: (oldIndex, newIndex) =>
                                  _reorderProjects(projects, oldIndex, newIndex),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: selected == null
                                ? const SizedBox.shrink()
                                : _ProjectDetail(
                                    key: ValueKey<String>(
                                      'project-detail-${selected.id}',
                                    ),
                                    repository: widget.repository,
                                    project: selected,
                                    onDeleted: () {
                                      setState(() => _selectedId = null);
                                      widget.shell.focusProject(null);
                                    },
                                    onNotify: _notify,
                                  ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// 列表
// -----------------------------------------------------------------------------

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.subtitle,
    required this.count,
    this.action,
  });

  final String title;
  final String subtitle;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title, style: AppText.h1),
                const SizedBox(width: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSunken,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('$count', style: AppText.micro),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(subtitle, style: AppText.caption),
          ],
        ),
        const Spacer(),
        ?action,
      ],
    );
  }
}

class _ProjectList extends StatelessWidget {
  const _ProjectList({
    required this.projects,
    required this.selectedId,
    required this.onSelect,
    required this.onDelete,
    required this.onReorder,
  });

  final List<Project> projects;
  final String? selectedId;
  final ValueChanged<Project> onSelect;
  final ValueChanged<Project> onDelete;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      buildDefaultDragHandles: false,
      itemCount: projects.length,
      onReorderItem: onReorder,
      proxyDecorator: (child, index, animation) => Material(
        color: AppColors.surface,
        elevation: 6,
        borderRadius: AppRadius.card,
        child: child,
      ),
      itemBuilder: (context, index) {
        final project = projects[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey<String>('project-row-${project.id}'),
          index: index,
          child: _ProjectRow(
            project: project,
            selected: project.id == selectedId,
            onTap: () => onSelect(project),
            onDelete: () => onDelete(project),
          ),
        );
      },
    );
  }
}

class _ProjectRow extends StatefulWidget {
  const _ProjectRow({
    required this.project,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final Project project;
  final bool selected;
  final VoidCallback onTap;

  /// 右键菜单里选中「删除项目」后触发（确认与写库由页面负责）。
  final VoidCallback onDelete;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  bool _hovered = false;

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    );
    final locked = widget.project.name == kUnfiledProjectName;
    final action = await showMenu<String>(
      context: context,
      position: position,
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: locked ? null : 'delete',
          enabled: !locked,
          height: 40,
          child: Row(
            children: <Widget>[
              Icon(
                Icons.delete_outline_rounded,
                size: AppSizes.iconSm,
                color: locked ? AppColors.textDisabled : AppColors.danger,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                locked ? '系统分组，不能删除' : '删除项目',
                style: AppText.body.copyWith(
                  fontSize: 13,
                  color: locked ? AppColors.textDisabled : AppColors.danger,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (action == 'delete' && context.mounted) widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onHover: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      // 用 Listener 自己判右键：onSecondaryTapDown 在部分环境（含 widget 测试的
      // 合成指针事件）拿不到 secondary 按下，Listener 能稳定收到。
      child: Listener(
        onPointerDown: (event) {
          if ((event.buttons & kSecondaryButton) == 0) return;
          widget.onTap();
          _showContextMenu(context, event.position);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            // 只在 alpha 上过渡，避免透明黑补间造成的深灰闪烁。
            color: widget.selected
                ? AppColors.accentSoft
                : AppColors.surfaceHover.withValues(alpha: _hovered ? 1 : 0),
            child: Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 22,
                  decoration: BoxDecoration(
                    color: widget.project.color.uiColor,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm + 2),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.project.name,
                        style: AppText.bodyStrong.copyWith(fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(widget.project.status.label, style: AppText.micro),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects({required this.archivedOnly, required this.onCreate});

  final bool archivedOnly;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.folder_open_rounded,
            size: 44,
            color: AppColors.textDisabled,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(archivedOnly ? '还没有归档的项目' : '还没有项目', style: AppText.h2),
          const SizedBox(height: AppSpacing.xs),
          Text(
            archivedOnly ? '归档项目后会在这里出现。' : '先建一个项目，再把任务和跨天阶段放进去。',
            style: AppText.caption,
          ),
          if (!archivedOnly) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: AppSizes.iconSm),
              label: const Text('新建项目'),
            ),
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 详情
// -----------------------------------------------------------------------------

class _ProjectDetail extends StatefulWidget {
  const _ProjectDetail({
    super.key,
    required this.repository,
    required this.project,
    required this.onDeleted,
    required this.onNotify,
  });

  final PlannerRepository repository;
  final Project project;
  final VoidCallback onDeleted;
  final void Function(String message, {bool error}) onNotify;

  @override
  State<_ProjectDetail> createState() => _ProjectDetailState();
}

class _ProjectDetailState extends State<_ProjectDetail> {
  late final TextEditingController _name = TextEditingController(
    text: widget.project.name,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.project.description,
  );
  late ProjectColor _color = widget.project.color;
  late ProjectStatus _status = widget.project.status;
  bool _saving = false;

  @override
  void didUpdateWidget(covariant _ProjectDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id) {
      _name.text = widget.project.name;
      _description.text = widget.project.description;
      _color = widget.project.color;
      _status = widget.project.status;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      widget.onNotify('项目名称不能为空', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final updated = await widget.repository.updateProject(
        widget.project.copyWith(
          name: name,
          description: _description.text.trim(),
          color: _color,
          status: _status,
        ),
      );
      if (!mounted) return;
      widget.onNotify('已保存「${updated.name}」');
    } on PlannerException catch (error) {
      if (!mounted) return;
      widget.onNotify(error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    final archiving = !widget.project.isArchived;
    try {
      await widget.repository.updateProject(
        widget.project.copyWith(
          status: archiving ? ProjectStatus.archived : ProjectStatus.active,
        ),
      );
      if (!mounted) return;
      widget.onNotify(archiving ? '项目已归档' : '项目已恢复');
    } on PlannerException catch (error) {
      if (!mounted) return;
      widget.onNotify(error.message, error: true);
    }
  }

  Future<void> _delete() async {
    // 「未归类」是系统分组：删掉会级联删掉还没归类的安排，只允许改名/搬走里面的内容。
    if (widget.project.name == kUnfiledProjectName) {
      widget.onNotify('「未归类」是系统分组，不能删除；可以把里面的安排改到其他项目', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目？'),
        content: Text(
          '「${widget.project.name}」及其全部阶段、任务都会被删除（可在备份中恢复）。'
          '此操作会立即从月历与列表中移除。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('project-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.deleteProject(widget.project.id);
      if (!mounted) return;
      widget.onDeleted();
      widget.onNotify('项目已删除');
    } on PlannerException catch (error) {
      if (!mounted) return;
      widget.onNotify(error.message, error: true);
    }
  }

  Future<void> _addSpan() async {
    final result = await showSpanEditorDialog(
      context,
      title: '新建跨天阶段',
      initialStart: LocalDate.today(),
      initialEnd: LocalDate.today().addDays(2),
    );
    if (result == null || !mounted) return;
    try {
      await widget.repository.createSpan(
        PlanSpanDraft(
          projectId: widget.project.id,
          title: result.title,
          startDate: result.start,
          endDate: result.end,
          status: result.status,
          description: result.description,
          color: result.color,
        ),
      );
      if (!mounted) return;
      widget.onNotify('已添加阶段「${result.title}」');
    } on PlannerException catch (error) {
      widget.onNotify(error.message, error: true);
    }
  }

  Future<void> _editSpan(PlanSpan span) async {
    final result = await showSpanEditorDialog(
      context,
      title: '编辑跨天阶段',
      initialTitle: span.title,
      initialDescription: span.description,
      initialStart: span.startDate,
      initialEnd: span.endDate,
      initialStatus: span.status,
      initialColor: span.color,
    );
    if (result == null || !mounted) return;
    try {
      await widget.repository.updateSpan(
        span.copyWith(
          title: result.title,
          startDate: result.start,
          endDate: result.end,
          status: result.status,
          description: result.description,
          color: result.color,
        ),
      );
      if (!mounted) return;
      widget.onNotify('阶段已更新');
    } on PlannerException catch (error) {
      widget.onNotify(error.message, error: true);
    }
  }

  Future<void> _deleteSpan(PlanSpan span) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除阶段？'),
        content: Text('「${span.title}」会从月历移除，关联任务保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.deleteSpan(span.id);
      if (!mounted) return;
      widget.onNotify('阶段已删除');
    } on PlannerException catch (error) {
      widget.onNotify(error.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 10,
              height: 28,
              decoration: BoxDecoration(
                color: _color.uiColor,
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
            ),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: TextField(
                key: const ValueKey<String>('project-name-field'),
                controller: _name,
                style: AppText.h1,
                decoration: const InputDecoration(
                  hintText: '项目名称',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _StatusDropdown(
              value: _status,
              onChanged: (status) => setState(() => _status = status),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const Text('简介', style: AppText.caption),
        const SizedBox(height: AppSpacing.xs + 2),
        TextField(
          key: const ValueKey<String>('project-description-field'),
          controller: _description,
          minLines: 2,
          maxLines: 4,
          style: AppText.body,
          decoration: dialogInputDecoration('这个项目要达成什么？'),
        ),
        const SizedBox(height: AppSpacing.lg),
        const Text('颜色', style: AppText.caption),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final color in ProjectColor.palette)
              _ColorDot(
                key: ValueKey<String>('project-color-${color.hex}'),
                color: color,
                selected: color == _color,
                onTap: () => setState(() => _color = color),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: <Widget>[
            FilledButton(
              key: const ValueKey<String>('project-save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存修改'),
            ),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(
              onPressed: _archive,
              child: Text(widget.project.isArchived ? '取消归档' : '归档项目'),
            ),
            const Spacer(),
            TextButton(
              key: const ValueKey<String>('project-delete'),
              onPressed: _delete,
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('删除项目'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        const Divider(height: 1),
        const SizedBox(height: AppSpacing.lg),
        _SectionHeading(
          title: '跨天阶段',
          subtitle: '阶段会以彩条横跨月历上的多天，不是任务。',
          action: FilledButton.icon(
            key: const ValueKey<String>('span-new'),
            onPressed: _addSpan,
            icon: const Icon(Icons.add_rounded, size: AppSizes.iconSm),
            label: const Text('新建阶段'),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        StreamBuilder<List<PlanSpan>>(
          stream: widget.repository.watchSpansForProject(widget.project.id),
          builder: (context, snapshot) {
            final spans = snapshot.data ?? const <PlanSpan>[];
            if (spans.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSunken,
                  borderRadius: AppRadius.card,
                ),
                child: const Text(
                  '还没有跨天阶段。比如「11月3日–11月7日 信息架构评审」。',
                  style: AppText.caption,
                ),
              );
            }
            return Column(
              children: <Widget>[
                for (final span in spans)
                  _SpanRow(
                    key: ValueKey<String>('span-row-${span.id}'),
                    span: span,
                    onEdit: () => _editSpan(span),
                    onDelete: () => _deleteSpan(span),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.xxl),
        const _SectionHeading(title: '关联任务', subtitle: '在该项目下创建的任务会出现在这里与月历中。'),
        const SizedBox(height: AppSpacing.md),
        StreamBuilder<List<PlannerTask>>(
          stream: widget.repository.watchTasksForProject(widget.project.id),
          builder: (context, snapshot) {
            final tasks = snapshot.data ?? const <PlannerTask>[];
            if (tasks.isEmpty) {
              return const Text(
                '还没有任务。打开某一天的面板即可新建并选择本项目。',
                style: AppText.caption,
              );
            }
            return Column(
              children: <Widget>[
                for (final task in tasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs + 2),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          task.isDone
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked,
                          size: AppSizes.iconSm,
                          color: task.isDone
                              ? AppColors.success
                              : AppColors.textTertiary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            task.title,
                            style: AppText.body.copyWith(
                              fontSize: 13,
                              decoration: task.isDone
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          task.scheduledDate == null
                              ? '未排期'
                              : monthDay(task.scheduledDate!),
                          style: AppText.micro,
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StatusDropdown extends StatelessWidget {
  const _StatusDropdown({required this.value, required this.onChanged});

  final ProjectStatus value;
  final ValueChanged<ProjectStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: AppRadius.control,
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ProjectStatus>(
          value: value,
          isDense: true,
          style: AppText.small,
          items: <DropdownMenuItem<ProjectStatus>>[
            for (final status in ProjectStatus.values)
              DropdownMenuItem<ProjectStatus>(
                value: status,
                child: Text(status.label, style: AppText.small),
              ),
          ],
          onChanged: (status) {
            if (status != null) onChanged(status);
          },
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final ProjectColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color.uiColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.textPrimary : Colors.transparent,
              width: 2,
            ),
          ),
          child: selected
              ? const Icon(
                  Icons.check_rounded,
                  size: 14,
                  color: AppColors.textInverse,
                )
              : null,
        ),
      ),
    );
  }
}

class _SpanRow extends StatelessWidget {
  const _SpanRow({
    super.key,
    required this.span,
    required this.onEdit,
    required this.onDelete,
  });

  final PlanSpan span;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  span.title,
                  style: AppText.bodyStrong.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  '${monthDay(span.startDate)} – ${monthDay(span.endDate)}'
                  ' · ${span.lengthInDays} 天 · ${span.status.label}',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑阶段',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: AppSizes.iconSm),
          ),
          IconButton(
            tooltip: '删除阶段',
            onPressed: onDelete,
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: AppSizes.iconSm,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: AppText.h2),
            const SizedBox(height: 2),
            Text(subtitle, style: AppText.caption),
          ],
        ),
        const Spacer(),
        ?action,
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 新建项目 / 阶段编辑对话框
// -----------------------------------------------------------------------------

class _ProjectCreateDialog extends StatefulWidget {
  const _ProjectCreateDialog();

  @override
  State<_ProjectCreateDialog> createState() => _ProjectCreateDialogState();
}

class _ProjectCreateDialogState extends State<_ProjectCreateDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _description = TextEditingController();
  ProjectColor _color = ProjectColor.defaultColor;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) return;
    Navigator.of(context).pop(
      ProjectDraft(
        name: _name.text.trim(),
        description: _description.text.trim(),
        color: _color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建项目'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('project-create-name'),
              controller: _name,
              autofocus: true,
              style: AppText.body,
              decoration: dialogInputDecoration('项目名称'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 3,
              style: AppText.body,
              decoration: dialogInputDecoration('简介（可选）'),
            ),
            const SizedBox(height: AppSpacing.md),
            const Text('颜色', style: AppText.caption),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final color in ProjectColor.palette)
                  _ColorDot(
                    color: color,
                    selected: color == _color,
                    onTap: () => setState(() => _color = color),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('project-create-submit'),
          onPressed: _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
