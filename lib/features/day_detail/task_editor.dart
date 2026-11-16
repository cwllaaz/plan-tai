import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'day_detail_math.dart';

/// 编辑器提交给上层的数据（由上层负责调用仓储）。
final class TaskEditorInput {
  const TaskEditorInput({
    required this.title,
    required this.date,
    required this.timeSlot,
    required this.projectId,
    required this.priority,
    required this.notes,
  });

  final String title;
  final LocalDate date;
  final TimeSlot? timeSlot;
  final String? projectId;
  final TaskPriority priority;
  final String notes;
}

/// 内嵌在时间轴里的任务编辑卡片（新建与编辑复用同一个表单）。
///
/// 之所以不用弹窗：产品硬指标是"不离开月历管完一天"，内联编辑不会打断上下文。
/// 表单只暴露常用字段，全部字段都有明确的空状态与校验提示。
class TaskEditorCard extends StatefulWidget {
  const TaskEditorCard({
    super.key,
    required this.initial,
    required this.defaultDate,
    required this.today,
    required this.projects,
    required this.onCancel,
    required this.onSubmit,
    this.onDelete,
  });

  /// 需要编辑的任务；null = 新建。
  final PlannerTask? initial;

  /// 新建任务时默认落在哪一天（即面板当前日期）。
  final LocalDate defaultDate;

  final LocalDate today;
  final List<Project> projects;
  final VoidCallback onCancel;

  /// 返回 null 表示保存成功（上层会关闭编辑器），否则返回可展示的错误文案。
  final Future<String?> Function(TaskEditorInput input) onSubmit;

  /// 仅编辑已有任务时提供。
  final VoidCallback? onDelete;

  @override
  State<TaskEditorCard> createState() => _TaskEditorCardState();
}

class _TaskEditorCardState extends State<TaskEditorCard> {
  late final TextEditingController _titleController;
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late final TextEditingController _notesController;

  late LocalDate _date;
  late bool _hasTime;
  late String _projectKey;
  late TaskPriority _priority;

  bool _saving = false;
  String? _titleError;
  String? _timeError;
  String? _formError;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _titleController = TextEditingController(text: initial?.title ?? '');
    _notesController = TextEditingController(text: initial?.notes ?? '');
    final slot = initial?.timeSlot;
    _hasTime = slot != null;
    _startController = TextEditingController(text: slot?.startLabel ?? '09:00');
    _endController = TextEditingController(text: slot?.endLabel ?? '09:30');
    _date = initial?.scheduledDate ?? widget.defaultDate;
    _projectKey = initial?.projectId ?? '';
    _priority = initial?.priority ?? TaskPriority.normal;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _startController.dispose();
    _endController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _toggleTime(bool enabled) {
    setState(() {
      _hasTime = enabled;
      _timeError = null;
      if (enabled) {
        if (_startController.text.trim().isEmpty) {
          _startController.text = '09:00';
        }
        if (_endController.text.trim().isEmpty) {
          _endController.text = defaultEndTimeText(_startController.text);
        }
      }
    });
  }

  void _onStartChanged(String value) {
    if (_timeError != null) setState(() => _timeError = null);
    // 结束时间还停留在默认值时，跟着开始时间顺延，减少一次手动输入。
    final currentEnd = parseTimeOfDay(_endController.text);
    final defaultEnd = parseTimeOfDay(defaultEndTimeText('09:00'));
    if (currentEnd == null || currentEnd == defaultEnd) {
      final next = defaultEndTimeText(value);
      if (next.isNotEmpty && next != _endController.text) {
        _endController.text = next;
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.startOfDay,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择任务日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null || !mounted) return;
    setState(() => _date = LocalDate.fromDateTime(picked));
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '请填写任务标题');
      return;
    }
    TimeSlot? slot;
    if (_hasTime) {
      final error = validateTimeInputs(
        startText: _startController.text,
        endText: _endController.text,
      );
      if (error != null) {
        setState(() => _timeError = error);
        return;
      }
      slot = timeSlotFromInputs(
        startText: _startController.text,
        endText: _endController.text,
      );
    }

    setState(() {
      _saving = true;
      _titleError = null;
      _timeError = null;
      _formError = null;
    });

    final error = await widget.onSubmit(
      TaskEditorInput(
        title: title,
        date: _date,
        timeSlot: slot,
        projectId: _projectKey.isEmpty ? null : _projectKey,
        priority: _priority,
        notes: _notesController.text.trim(),
      ),
    );

    if (!mounted) return;
    setState(() {
      _saving = false;
      _formError = error;
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.xs + 2,
        AppSpacing.xs + 2,
        AppSpacing.xs + 2,
        AppSpacing.md,
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm + 2,
        AppSpacing.md,
        AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: AppColors.accentBorder),
        boxShadow: AppShadows.card,
      ),
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  _isEditing ? '编辑任务' : '新建任务',
                  style: AppText.bodyStrong.copyWith(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                if (_isEditing && widget.onDelete != null)
                  TextButton(
                    key: const ValueKey<String>('task-editor-delete'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      minimumSize: const Size(0, 26),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs + 2,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _saving ? null : widget.onDelete,
                    child: Text(
                      '删除',
                      style: AppText.small.copyWith(
                        fontSize: 12,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            TextField(
              key: const ValueKey<String>('task-editor-title'),
              controller: _titleController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              maxLength: 200,
              buildCounter: (
                BuildContext context, {
                required int currentLength,
                required bool isFocused,
                required int? maxLength,
              }) => null,
              style: AppText.body.copyWith(
                fontSize: 13,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: '任务标题',
                errorText: _titleError,
              ),
              onChanged: (_) {
                if (_titleError != null) {
                  setState(() => _titleError = null);
                }
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: _DateField(
                    date: _date,
                    today: widget.today,
                    onPrevious: () => setState(() => _date = _date.addDays(-1)),
                    onNext: () => setState(() => _date = _date.addDays(1)),
                    onPick: _pickDate,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  width: 92,
                  child: CompactSelect<TaskPriority>(
                    key: const ValueKey<String>('task-editor-priority'),
                    value: _priority,
                    items: TaskPriority.values,
                    labelOf: (TaskPriority priority) => priority.label,
                    icon: Icons.flag_outlined,
                    onSelected: (TaskPriority priority) =>
                        setState(() => _priority = priority),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Checkbox(
                    value: _hasTime,
                    onChanged: (bool? value) => _toggleTime(value ?? false),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: const BorderSide(
                      color: AppColors.borderStrong,
                      width: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs + 2),
                InkWell(
                  onTap: () => _toggleTime(!_hasTime),
                  child: Text(
                    '固定时间',
                    style: AppText.small.copyWith(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const Spacer(),
                if (_hasTime) ...<Widget>[
                  _TimeField(
                    key: const ValueKey<String>('task-editor-start'),
                    controller: _startController,
                    onChanged: _onStartChanged,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    child: Text(
                      '–',
                      style: AppText.small.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                  _TimeField(
                    key: const ValueKey<String>('task-editor-end'),
                    controller: _endController,
                    onChanged: (_) {
                      if (_timeError != null) {
                        setState(() => _timeError = null);
                      }
                    },
                  ),
                ] else
                  Text(
                    '不排具体时间，当天完成即可',
                    style: AppText.micro.copyWith(fontSize: 11),
                  ),
              ],
            ),
            if (_timeError != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs + 2),
              Text(
                _timeError!,
                style: AppText.micro.copyWith(
                  fontSize: 11,
                  color: AppColors.danger,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            CompactSelect<String>(
              key: const ValueKey<String>('task-editor-project'),
              value: _projectKey,
              items: <String>[
                '',
                for (final project in widget.projects) project.id,
              ],
              labelOf: _projectLabel,
              icon: Icons.folder_outlined,
              onSelected: (String key) => setState(() => _projectKey = key),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey<String>('task-editor-notes'),
              controller: _notesController,
              minLines: 1,
              maxLines: 2,
              maxLength: 5000,
              buildCounter: (
                BuildContext context, {
                required int currentLength,
                required bool isFocused,
                required int? maxLength,
              }) => null,
              style: AppText.small.copyWith(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
              decoration: const InputDecoration(hintText: '补充说明（可选）'),
            ),
            if (_formError != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs + 2),
              Text(
                _formError!,
                key: const ValueKey<String>('task-editor-error'),
                style: AppText.micro.copyWith(
                  fontSize: 11,
                  color: AppColors.danger,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm + 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  key: const ValueKey<String>('task-editor-cancel'),
                  onPressed: _saving ? null : widget.onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    minimumSize: const Size(0, 32),
                  ),
                  child: Text(
                    '取消',
                    style: AppText.small.copyWith(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                FilledButton(
                  key: const ValueKey<String>('task-editor-save'),
                  onPressed: _saving ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 32),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: Text(_saving ? '保存中…' : '保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _projectLabel(String key) {
    if (key.isEmpty) return '未归项目';
    for (final project in widget.projects) {
      if (project.id == key) return project.name;
    }
    return '未归项目';
  }
}

/// 日期选择行：`‹ 11月14日 周六 ›`，点中间可打开日期选择器。
class _DateField extends StatelessWidget {
  const _DateField({
    required this.date,
    required this.today,
    required this.onPrevious,
    required this.onNext,
    required this.onPick,
  });

  final LocalDate date;
  final LocalDate today;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: AppRadius.control,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          _DateArrow(
            key: const ValueKey<String>('task-editor-date-prev'),
            icon: Icons.chevron_left_rounded,
            tooltip: '前一天',
            onTap: onPrevious,
          ),
          Expanded(
            child: InkWell(
              onTap: onPick,
              borderRadius: AppRadius.control,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(
                    Icons.calendar_today_outlined,
                    size: 12,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      date == today
                          ? '今天 · ${monthDayWithWeekday(date)}'
                          : monthDayWithWeekday(date),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.small.copyWith(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _DateArrow(
            key: const ValueKey<String>('task-editor-date-next'),
            icon: Icons.chevron_right_rounded,
            tooltip: '后一天',
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _DateArrow extends StatelessWidget {
  const _DateArrow({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: AppRadius.control,
        onTap: onTap,
        child: SizedBox(
          width: 26,
          height: 32,
          child: Icon(icon, size: 15, color: AppColors.textTertiary),
        ),
      ),
    );
  }
}

/// 开始/结束时间输入框，等宽数字，宽度紧凑。
class _TimeField extends StatelessWidget {
  const _TimeField({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 62,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textAlign: TextAlign.center,
        maxLength: 5,
        buildCounter: (
          BuildContext context, {
          required int currentLength,
          required bool isFocused,
          required int? maxLength,
        }) => null,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9:：]')),
        ],
        style: AppText.numeric.copyWith(
          fontSize: 12,
          color: AppColors.textPrimary,
        ),
        decoration: const InputDecoration(
          hintText: '09:00',
          contentPadding: EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}

/// 紧凑下拉选择（自绘，避免 Material 下拉在窄抽屉里过宽/过重）。
class CompactSelect<T> extends StatelessWidget {
  const CompactSelect({
    super.key,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onSelected,
    this.icon,
  });

  final T value;
  final List<T> items;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: '',
      position: PopupMenuPosition.under,
      color: AppColors.surface,
      elevation: 8,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<T>>[
        for (final item in items)
          PopupMenuItem<T>(
            value: item,
            height: 34,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    labelOf(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small.copyWith(
                      fontSize: 12.5,
                      color: item == value
                          ? AppColors.accent
                          : AppColors.textPrimary,
                      fontWeight: item == value
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (item == value)
                  const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: AppColors.accent,
                  ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          borderRadius: AppRadius.control,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 12, color: AppColors.textTertiary),
              const SizedBox(width: AppSpacing.xs),
            ],
            Expanded(
              child: Text(
                labelOf(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const Icon(
              Icons.expand_more_rounded,
              size: 15,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
