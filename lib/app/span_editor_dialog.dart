import 'package:material_ui/material_ui.dart';

import '../core/format/format.dart';
import '../core/models/models.dart';
import '../core/theme/theme.dart';
import 'form_fields.dart';

/// 跨天阶段编辑弹窗的返回值。
///
/// [projectId] 只有在弹窗里选了「归属项目」时才有值；
/// 从月历右键拖选创建时没有项目选项，由调用方放进「未归类」。
/// [color] 为 null 表示"跟随项目颜色"。
/// [delete] 为 true 表示用户在弹窗里点了「删除这条安排」，此时其余字段是原值、可忽略。
final class SpanFormResult {
  const SpanFormResult({
    required this.projectId,
    required this.title,
    required this.start,
    required this.end,
    required this.status,
    required this.description,
    this.color,
    this.delete = false,
  });

  final String? projectId;
  final String title;
  final LocalDate start;
  final LocalDate end;
  final PlanSpanStatus status;
  final String description;
  final ProjectColor? color;
  final bool delete;
}

/// 打开「新建 / 编辑跨天安排」弹窗。
///
/// - 从月历右键拖选创建：不传 [projects]，弹窗只有 名称 / 颜色 / 起止 / 说明；
/// - 编辑已有安排：传 [projects]，底部多一个「归属项目」下拉，可改到别的项目或「未归类」；
///   传 [allowDelete] 时左下多一个「删除」，点它会二次确认后返回 `delete: true`；
/// - 项目页里添加阶段：不传 [projects]，归属由页面决定。
///
/// 状态（计划中/进行中/…）不在这里编辑：新建默认「计划中」，编辑时保持原状态。
/// 返回 null 表示用户取消。
Future<SpanFormResult?> showSpanEditorDialog(
  BuildContext context, {
  required String title,
  required LocalDate initialStart,
  required LocalDate initialEnd,
  String initialTitle = '',
  String initialDescription = '',
  PlanSpanStatus initialStatus = PlanSpanStatus.planned,
  ProjectColor? initialColor,
  List<Project>? projects,
  String? initialProjectId,
  String? footerHint,
  bool allowDelete = false,
  String submitLabel = '保存',
}) {
  return showDialog<SpanFormResult>(
    context: context,
    builder: (context) => _SpanEditorDialog(
      title: title,
      initialTitle: initialTitle,
      initialDescription: initialDescription,
      initialStart: initialStart,
      initialEnd: initialEnd,
      initialStatus: initialStatus,
      initialColor: initialColor,
      projects: projects,
      initialProjectId: initialProjectId,
      footerHint: footerHint,
      allowDelete: allowDelete,
      submitLabel: submitLabel,
    ),
  );
}

class _SpanEditorDialog extends StatefulWidget {
  const _SpanEditorDialog({
    required this.title,
    required this.initialStart,
    required this.initialEnd,
    this.initialTitle = '',
    this.initialDescription = '',
    this.initialStatus = PlanSpanStatus.planned,
    this.initialColor,
    this.projects,
    this.initialProjectId,
    this.footerHint,
    this.allowDelete = false,
    this.submitLabel = '保存',
  });

  final String title;
  final String initialTitle;
  final String initialDescription;
  final LocalDate initialStart;
  final LocalDate initialEnd;
  final PlanSpanStatus initialStatus;
  final ProjectColor? initialColor;
  final List<Project>? projects;
  final String? initialProjectId;
  final String? footerHint;
  final bool allowDelete;
  final String submitLabel;

  @override
  State<_SpanEditorDialog> createState() => _SpanEditorDialogState();
}

class _SpanEditorDialogState extends State<_SpanEditorDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.initialTitle,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.initialDescription,
  );
  late final TextEditingController _start = TextEditingController(
    text: widget.initialStart.iso,
  );
  late final TextEditingController _end = TextEditingController(
    text: widget.initialEnd.iso,
  );
  late ProjectColor? _color = widget.initialColor;
  String? _projectId;
  String? _error;

  bool get _hasProjectPicker => widget.projects != null;

  @override
  void initState() {
    super.initState();
    final candidates = widget.projects ?? const <Project>[];
    if (_hasProjectPicker && candidates.isNotEmpty) {
      final preferred = widget.initialProjectId;
      final hasPreferred =
          preferred != null && candidates.any((p) => p.id == preferred);
      _projectId = hasPreferred ? preferred : candidates.first.id;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final current = LocalDate.tryParse(controller.text) ?? LocalDate.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: current.startOfDay,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    controller.text = LocalDate.fromDateTime(picked).iso;
  }

  void _submit() {
    final title = _title.text.trim();
    final start = LocalDate.tryParse(_start.text);
    final end = LocalDate.tryParse(_end.text);
    if (title.isEmpty) {
      setState(() => _error = '安排名称不能为空');
      return;
    }
    if (_hasProjectPicker && _projectId == null) {
      setState(() => _error = '请选择一个归属项目，或选「未归类」');
      return;
    }
    if (start == null || end == null) {
      setState(() => _error = '日期格式应为 YYYY-MM-DD');
      return;
    }
    if (end.isBefore(start)) {
      setState(() => _error = '结束日不能早于开始日');
      return;
    }
    Navigator.of(context).pop(
      SpanFormResult(
        projectId: _projectId,
        title: title,
        start: start,
        end: end,
        status: widget.initialStatus,
        description: _description.text.trim(),
        color: _color,
      ),
    );
  }

  /// 删除：先二次确认，确认后带着 `delete: true` 关闭弹窗（由调用方真正删库）。
  Future<void> _requestDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条安排？'),
        content: Text(
          '「${widget.initialTitle.isEmpty ? '未命名安排' : widget.initialTitle}」'
          '会从月历和项目页移除，之后不再显示。\n'
          '任务不受影响：任务和跨天安排是两类独立记录。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('span-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(
      SpanFormResult(
        projectId: _projectId,
        title: widget.initialTitle,
        start: widget.initialStart,
        end: widget.initialEnd,
        status: widget.initialStatus,
        description: widget.initialDescription,
        color: widget.initialColor,
        delete: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final projects = widget.projects ?? const <Project>[];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('span-title-field'),
              controller: _title,
              autofocus: true,
              style: AppText.body,
              decoration: dialogInputDecoration('安排名称，如：信息架构评审'),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            _ColorPicker(
              selected: _color,
              onChanged: (color) => setState(() => _color = color),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('span-start-field'),
                    controller: _start,
                    style: AppText.body,
                    onChanged: (_) => setState(() {}),
                    decoration: dialogInputDecoration('开始日 YYYY-MM-DD')
                        .copyWith(
                          suffixIcon: IconButton(
                            tooltip: '选择开始日',
                            icon: const Icon(
                              Icons.calendar_today_outlined,
                              size: AppSizes.iconSm,
                            ),
                            onPressed: () => _pickDate(_start),
                          ),
                        ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('span-end-field'),
                    controller: _end,
                    style: AppText.body,
                    onChanged: (_) => setState(() {}),
                    decoration: dialogInputDecoration('结束日 YYYY-MM-DD')
                        .copyWith(
                          suffixIcon: IconButton(
                            tooltip: '选择结束日',
                            icon: const Icon(
                              Icons.calendar_today_outlined,
                              size: AppSizes.iconSm,
                            ),
                            onPressed: () => _pickDate(_end),
                          ),
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _rangeSummary(),
              key: const ValueKey<String>('span-range-summary'),
              style: AppText.caption,
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 3,
              style: AppText.body,
              decoration: dialogInputDecoration('说明（可选）'),
            ),
            if (_hasProjectPicker && projects.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.sm + 2),
              DropdownButtonFormField<String>(
                key: const ValueKey<String>('span-project-field'),
                initialValue: _projectId,
                decoration: dialogInputDecoration('归属项目（可稍后再归类）'),
                items: <DropdownMenuItem<String>>[
                  for (final project in projects)
                    DropdownMenuItem<String>(
                      value: project.id,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: project.color.uiColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(project.name, style: AppText.body),
                        ],
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) setState(() => _projectId = id);
                },
              ),
            ],
            if (widget.footerHint != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(widget.footerHint!, style: AppText.caption),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _error!,
                style: AppText.small.copyWith(color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        if (widget.allowDelete) ...<Widget>[
          TextButton(
            key: const ValueKey<String>('span-delete'),
            onPressed: _requestDelete,
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('span-submit'),
          onPressed: _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }

  String _rangeSummary() {
    final start = LocalDate.tryParse(_start.text);
    final end = LocalDate.tryParse(_end.text);
    if (start == null || end == null) return '日期格式应为 YYYY-MM-DD';
    if (end.isBefore(start)) return '结束日不能早于开始日';
    final days = end.differenceInDays(start) + 1;
    return '${monthDay(start)} – ${monthDay(end)} · 共 $days 天';
  }
}

/// 安排颜色：默认（跟随项目）+ 8 色板。
class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.selected, required this.onChanged});

  final ProjectColor? selected;
  final ValueChanged<ProjectColor?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Text('颜色', style: AppText.caption),
        const SizedBox(width: AppSpacing.sm + 2),
        _DefaultChip(selected: selected == null, onTap: () => onChanged(null)),
        for (final color in ProjectColor.palette)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _ColorDot(
              color: color,
              selected: selected == color,
              onTap: () => onChanged(color),
            ),
          ),
      ],
    );
  }
}

class _DefaultChip extends StatelessWidget {
  const _DefaultChip({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '跟随项目颜色',
      child: InkWell(
        key: const ValueKey<String>('span-color-default'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Text(
            '默认',
            style: AppText.micro.copyWith(
              fontSize: 10.5,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final ProjectColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: color.hex,
      child: InkWell(
        key: ValueKey<String>('span-color-${color.hex}'),
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: color.uiColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.textPrimary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
      ),
    );
  }
}
