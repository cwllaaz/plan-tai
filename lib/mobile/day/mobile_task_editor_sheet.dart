import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../shared/mobile_pickers.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';

/// 任务编辑面板的返回值。
final class MobileTaskEditResult {
  const MobileTaskEditResult.saved() : saved = true, deletedTask = null;

  const MobileTaskEditResult.deleted(PlannerTask task)
    : saved = false,
      deletedTask = task;

  const MobileTaskEditResult.cancelled() : saved = false, deletedTask = null;

  final bool saved;

  /// 被删除的任务快照（调用方据此提供「撤销」）。
  final PlannerTask? deletedTask;
}

/// 打开移动端任务编辑底部面板（新建 / 编辑）。
///
/// - 字段与校验对齐桌面 `TaskEditorInput`：标题必填、项目可空、日期必填、
///   固定时间必须成对且结束晚于开始、优先级默认「普通」；
/// - 写库在面板内部完成（`createTask` / `updateTask` / `deleteTask`），
///   成功后自动关闭，失败保留面板并就地显示错误；
/// - 系统返回先收起键盘；放弃未保存的修改需要确认。
Future<MobileTaskEditResult> showMobileTaskEditorSheet(
  BuildContext context, {
  required PlannerRepository repository,
  required List<Project> projects,
  required LocalDate defaultDate,
  required LocalDate today,
  PlannerTask? initial,
  String? defaultProjectId,
}) async {
  final result = await showMobileSheet<MobileTaskEditResult>(
    context,
    heightFactor: MobileMetrics.editorSheetHeightFactor,
    isDismissible: false,
    enableDrag: false,
    builder: (BuildContext sheetContext) => _MobileTaskEditorSheet(
      repository: repository,
      projects: projects,
      defaultDate: defaultDate,
      today: today,
      initial: initial,
      defaultProjectId: defaultProjectId,
    ),
  );
  return result ?? const MobileTaskEditResult.cancelled();
}

class _MobileTaskEditorSheet extends StatefulWidget {
  const _MobileTaskEditorSheet({
    required this.repository,
    required this.projects,
    required this.defaultDate,
    required this.today,
    this.initial,
    this.defaultProjectId,
  });

  final PlannerRepository repository;
  final List<Project> projects;
  final LocalDate defaultDate;
  final LocalDate today;
  final PlannerTask? initial;

  /// 新建时的默认项目（从项目详情页进来时预选该项目）。
  final String? defaultProjectId;

  @override
  State<_MobileTaskEditorSheet> createState() => _MobileTaskEditorSheetState();
}

class _MobileTaskEditorSheetState extends State<_MobileTaskEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _notes;

  late LocalDate _date;
  late bool _hasTime;
  late int _startMinute;
  late int _endMinute;
  late TaskPriority _priority;
  late String? _projectId;

  bool _saving = false;
  String? _titleError;
  String? _formError;
  String? _timeError;
  bool _confirmingClose = false;
  final _titleAnchor = GlobalKey();
  final _timeErrorAnchor = GlobalKey();
  final _formErrorAnchor = GlobalKey();

  bool get _isEditing => widget.initial != null;

  /// 初始快照，用于判断是否有未保存改动。
  late final String _initialTitle;
  late final String _initialNotes;
  late final LocalDate _initialDate;
  late final bool _initialHasTime;
  late final int _initialStart;
  late final int _initialEnd;
  late final TaskPriority _initialPriority;
  late final String? _initialProjectId;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _title = TextEditingController(text: initial?.title ?? '');
    _notes = TextEditingController(text: initial?.notes ?? '');
    _date = initial?.scheduledDate ?? widget.defaultDate;
    _priority = initial?.priority ?? TaskPriority.normal;
    _projectId = initial?.projectId ?? widget.defaultProjectId;
    final slot = initial?.timeSlot;
    _hasTime = slot != null;
    _startMinute = slot?.startMinute ?? 9 * 60;
    _endMinute = slot?.endMinute ?? 9 * 60 + 30;

    _initialTitle = _title.text;
    _initialNotes = _notes.text;
    _initialDate = _date;
    _initialHasTime = _hasTime;
    _initialStart = _startMinute;
    _initialEnd = _endMinute;
    _initialPriority = _priority;
    _initialProjectId = _projectId;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _title.text != _initialTitle ||
      _notes.text != _initialNotes ||
      _date != _initialDate ||
      _hasTime != _initialHasTime ||
      (_hasTime && _startMinute != _initialStart) ||
      (_hasTime && _endMinute != _initialEnd) ||
      _priority != _initialPriority ||
      _projectId != _initialProjectId;

  String get _projectLabel {
    final projectId = _projectId;
    if (projectId == null) return '未归项目';
    for (final project in widget.projects) {
      if (project.id == projectId) return project.name;
    }
    return '未归项目';
  }

  TimeSlot? get _timeSlot {
    if (!_hasTime) return null;
    return TimeSlot.startEnd(startMinute: _startMinute, endMinute: _endMinute);
  }

  // ---------------------------------------------------------------------------
  // 表单交互
  // ---------------------------------------------------------------------------

  Future<void> _pickProject() async {
    final choice = await pickMobileProject(
      context,
      projects: widget.projects,
      selectedId: _projectId,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _projectId = choice.projectId;
      _formError = null;
    });
  }

  Future<void> _pickDate() async {
    final picked = await pickMobileDate(
      context,
      initial: _date,
      helpText: '选择任务日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _date = picked);
  }

  Future<void> _pickStart() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _startMinute ~/ 60,
        minute: _startMinute % 60,
      ),
      helpText: '开始时间',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null || !mounted) return;
    final start = picked.hour * 60 + picked.minute;
    setState(() {
      _startMinute = start;
      if (_endMinute <= start) {
        _endMinute = (start + 30).clamp(start + 1, 1440).toInt();
      }
      _timeError = null;
    });
  }

  Future<void> _pickEnd() async {
    // TimeSlot 支持 24:00，系统时间选择器的小时范围是 0–23。
    final pickerMinute = _endMinute.clamp(0, 1439);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: pickerMinute ~/ 60,
        minute: pickerMinute % 60,
      ),
      helpText: '结束时间',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null || !mounted) return;
    final end = picked.hour * 60 + picked.minute;
    setState(() {
      _endMinute = end;
      _timeError = null;
    });
    if (end <= _startMinute) _showTimeError();
  }

  void _toggleTime(bool enabled) {
    setState(() {
      _hasTime = enabled;
      _timeError = null;
    });
  }

  Future<void> _requestClose() async {
    if (_saving || _confirmingClose) return;
    FocusScope.of(context).unfocus();
    if (_dirty) {
      _confirmingClose = true;
      final discard = await showMobileConfirm(
        context,
        title: '放弃这次编辑？',
        message: '当前修改还没有保存，返回后会丢失。',
        confirmLabel: '放弃',
        danger: true,
      );
      _confirmingClose = false;
      if (!discard || !mounted) return;
    }
    Navigator.of(context).pop(const MobileTaskEditResult.cancelled());
  }

  void _reveal(GlobalKey anchor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = anchor.currentContext;
      if (mounted && target != null) {
        unawaited(Scrollable.ensureVisible(target));
      }
    });
  }

  void _showTimeError() {
    setState(() => _timeError = '结束时间必须晚于开始时间');
    _reveal(_timeErrorAnchor);
  }

  void _showFormError(String message) {
    setState(() {
      _saving = false;
      _formError = message;
    });
    _reveal(_formErrorAnchor);
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '请填写任务标题');
      _reveal(_titleAnchor);
      return;
    }
    if (_hasTime && _endMinute <= _startMinute) {
      setState(() => _formError = '结束时间必须晚于开始时间');
      return;
    }
    setState(() {
      _saving = true;
      _titleError = null;
      _formError = null;
    });

    try {
      final initial = widget.initial;
      if (initial == null) {
        await widget.repository.createTask(
          PlannerTaskDraft(
            title: title,
            projectId: _projectId,
            notes: _notes.text.trim(),
            scheduledDate: _date,
            timeSlot: _timeSlot,
            priority: _priority,
          ),
        );
      } else {
        final projectChanged = initial.projectId != _projectId;
        await widget.repository.updateTask(
          initial.copyWith(
            title: title,
            projectId: _projectId,
            // 换项目后原阶段可能不属于新项目，解除关联（与桌面一致）。
            spanId: projectChanged ? null : initial.spanId,
            notes: _notes.text.trim(),
            scheduledDate: _date,
            timeSlot: _timeSlot,
            priority: _priority,
          ),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(const MobileTaskEditResult.saved());
    } on PlannerException catch (error) {
      if (!mounted) return;
      _showFormError(error.message);
    } on Object {
      if (!mounted) return;
      _showFormError('保存失败，请稍后重试');
    }
  }

  Future<void> _delete() async {
    final initial = widget.initial;
    if (initial == null || _saving) return;
    final confirmed = await showMobileConfirm(
      context,
      title: '删除这个任务？',
      message: '「${initial.title}」会从当天列表移除，删除后可以立即撤销。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.repository.deleteTask(initial.id);
      if (!mounted) return;
      Navigator.of(context).pop(MobileTaskEditResult.deleted(initial));
    } on PlannerException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = error.message;
      });
    } on Object {
      if (!mounted) return;
      _showFormError('删除失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final imeVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final header = Material(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          children: [
            MobileTextButton(
              key: const ValueKey<String>('mobile-task-editor-cancel'),
              label: '取消',
              onPressed: _saving ? null : _requestClose,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isEditing ? '编辑任务' : '新建任务',
                    style: AppText.h2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    monthDayWithWeekday(_date),
                    style: AppText.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            MobileTextButton(
              key: const ValueKey<String>('mobile-task-editor-save'),
              label: _saving ? '保存中…' : '保存',
              onPressed: _saving ? null : _submit,
            ),
          ],
        ),
      ),
    );
    return PopScope<MobileTaskEditResult>(
      canPop: !imeVisible && !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (imeVisible) {
          FocusScope.of(context).unfocus();
        } else {
          unawaited(_requestClose());
        }
      },
      child: LayoutBuilder(
        builder: (context, bounds) {
          final scrollHeader = bounds.maxHeight < 132;
          return Column(
            children: [
              if (!scrollHeader) header else const SizedBox.shrink(),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (scrollHeader) header,
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            KeyedSubtree(
                              key: _titleAnchor,
                              child: TextField(
                                key: const ValueKey<String>(
                                  'mobile-task-editor-title',
                                ),
                                controller: _title,
                                autofocus: !_isEditing,
                                textInputAction: TextInputAction.done,
                                minLines: 1,
                                maxLines: 2,
                                maxLength: 200,
                                buildCounter: _noCounter,
                                style: AppText.bodyStrong.copyWith(
                                  fontSize: 16,
                                  height: 1.35,
                                ),
                                decoration: InputDecoration(
                                  hintText: '要做什么？',
                                  errorText: _titleError,
                                  errorMaxLines: 2,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.md,
                                    vertical: AppSpacing.md,
                                  ),
                                ),
                                onChanged: (_) =>
                                    setState(() => _titleError = null),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _FieldGroup(
                              children: <Widget>[
                                MobileFormField(
                                  key: const ValueKey<String>(
                                    'mobile-task-editor-date',
                                  ),
                                  label: '日期',
                                  value: mobileDayLabel(_date, widget.today),
                                  icon: Icons.calendar_today_outlined,
                                  onTap: _pickDate,
                                ),
                                const Divider(height: 1),
                                MobileFormField(
                                  key: const ValueKey<String>(
                                    'mobile-task-editor-project',
                                  ),
                                  label: '项目',
                                  value: _projectLabel,
                                  icon: Icons.folder_outlined,
                                  onTap: _pickProject,
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _FieldGroup(
                              children: <Widget>[
                                MobileSwitchRow(
                                  key: const ValueKey<String>(
                                    'mobile-task-editor-timeswitch',
                                  ),
                                  title: '固定时间',
                                  subtitle: _hasTime
                                      ? '${_formatMinute(_startMinute)} – ${_formatMinute(_endMinute)}'
                                      : '不排具体时间，当天完成即可',
                                  value: _hasTime,
                                  onChanged: _toggleTime,
                                ),
                                if (_hasTime) ...<Widget>[
                                  const Divider(height: 1),
                                  Padding(
                                    padding: const EdgeInsets.all(
                                      AppSpacing.md,
                                    ),
                                    child: MobileTimeRangeField(
                                      startLabel: _formatMinute(_startMinute),
                                      endLabel: _formatMinute(_endMinute),
                                      onPickStart: _pickStart,
                                      onPickEnd: _pickEnd,
                                    ),
                                  ),
                                  if (_timeError != null)
                                    Padding(
                                      key: _timeErrorAnchor,
                                      padding: const EdgeInsets.fromLTRB(
                                        AppSpacing.md,
                                        0,
                                        AppSpacing.md,
                                        AppSpacing.sm,
                                      ),
                                      child: MobileFormError(
                                        message: _timeError!,
                                      ),
                                    ),
                                ],
                              ],
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              '优先级',
                              style: AppText.caption.copyWith(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            _PrioritySelector(
                              value: _priority,
                              onChanged: (TaskPriority priority) =>
                                  setState(() => _priority = priority),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            TextField(
                              key: const ValueKey<String>(
                                'mobile-task-editor-notes',
                              ),
                              controller: _notes,
                              onChanged: (_) => setState(() {}),
                              minLines: 2,
                              maxLines: 5,
                              maxLength: 5000,
                              buildCounter: _noCounter,
                              style: AppText.small.copyWith(
                                fontSize: 13.5,
                                color: AppColors.textSecondary,
                              ),
                              decoration: const InputDecoration(
                                hintText: '补充说明（可选）',
                                contentPadding: EdgeInsets.all(AppSpacing.md),
                              ),
                            ),
                            if (_formError != null) ...<Widget>[
                              const SizedBox(height: AppSpacing.sm),
                              MobileFormError(
                                key: _formErrorAnchor,
                                message: _formError!,
                              ),
                            ],

                            if (_isEditing)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: MobileTextButton(
                                  key: const ValueKey<String>(
                                    'mobile-task-editor-delete',
                                  ),
                                  label: '删除任务',
                                  danger: true,
                                  onPressed: _saving ? null : _delete,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget? _noCounter(
    BuildContext context, {
    required int currentLength,
    required bool isFocused,
    required int? maxLength,
  }) => null;

  static String _formatMinute(int minute) {
    final hour = minute ~/ 60;
    final rest = minute % 60;
    return '${hour.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  }
}

/// 白底圆角分组容器（表单里的分段）。
class _FieldGroup extends StatelessWidget {
  const _FieldGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// 四个优先级的分段选择（触摸目标 48dp）。
class _PrioritySelector extends StatelessWidget {
  const _PrioritySelector({required this.value, required this.onChanged});

  final TaskPriority value;
  final ValueChanged<TaskPriority> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (final priority in TaskPriority.values) ...<Widget>[
          if (priority != TaskPriority.values.first)
            const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _PriorityOption(
              priority: priority,
              selected: value == priority,
              onTap: () => onChanged(priority),
            ),
          ),
        ],
      ],
    );
  }
}

class _PriorityOption extends StatelessWidget {
  const _PriorityOption({
    required this.priority,
    required this.selected,
    required this.onTap,
  });

  final TaskPriority priority;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      TaskPriority.low => AppColors.textTertiary,
      TaskPriority.normal => AppColors.textSecondary,
      TaskPriority.high => AppColors.warning,
      TaskPriority.urgent => AppColors.danger,
    };
    return InkWell(
      key: ValueKey<String>('mobile-task-editor-priority-${priority.level}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        height: MobileMetrics.minTapTarget,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          priority.label,
          style: AppText.bodyStrong.copyWith(
            fontSize: 13,
            color: selected ? AppColors.accent : color,
          ),
        ),
      ),
    );
  }
}
