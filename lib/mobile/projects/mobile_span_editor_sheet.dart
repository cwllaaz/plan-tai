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

/// 新建 / 编辑跨天阶段（「安排」）。返回 true 表示已保存或已删除，调用方刷新即可。
Future<bool> showMobileSpanEditorSheet(
  BuildContext context, {
  required PlannerRepository repository,
  required String projectId,
  PlanSpan? initial,
  required LocalDate defaultStart,
}) async {
  final result = await showMobileSheet<bool>(
    context,
    heightFactor: 0.88,
    isDismissible: false,
    enableDrag: false,
    builder: (BuildContext sheetContext) => _MobileSpanEditorSheet(
      repository: repository,
      projectId: projectId,
      initial: initial,
      defaultStart: defaultStart,
    ),
  );
  return result ?? false;
}

class _MobileSpanEditorSheet extends StatefulWidget {
  const _MobileSpanEditorSheet({
    required this.repository,
    required this.projectId,
    required this.defaultStart,
    this.initial,
  });

  final PlannerRepository repository;
  final String projectId;
  final LocalDate defaultStart;
  final PlanSpan? initial;

  @override
  State<_MobileSpanEditorSheet> createState() => _MobileSpanEditorSheetState();
}

class _MobileSpanEditorSheetState extends State<_MobileSpanEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late LocalDate _start;
  late LocalDate _end;
  late PlanSpanStatus _status;
  late ProjectColor? _color;

  bool _saving = false;
  String? _titleError;
  String? _formError;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _title = TextEditingController(text: initial?.title ?? '');
    _description = TextEditingController(text: initial?.description ?? '');
    _start = initial?.startDate ?? widget.defaultStart;
    _end = initial?.endDate ?? widget.defaultStart.addDays(6);
    _status = initial?.status ?? PlanSpanStatus.planned;
    _color = initial?.color;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  int get _dayCount => _end.differenceInDays(_start) + 1;

  Future<void> _pickStart() async {
    final picked = await pickMobileDate(
      context,
      initial: _start,
      helpText: '选择开始日',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _start = picked;
      if (_end.isBefore(_start)) _end = _start;
      _formError = null;
    });
  }

  Future<void> _pickEnd() async {
    final picked = await pickMobileDate(
      context,
      initial: _end,
      helpText: '选择结束日',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _end = picked;
      _formError = null;
    });
  }

  Future<void> _pickStatus() async {
    final picked = await pickMobileSpanStatus(context, selected: _status);
    if (picked == null || !mounted) return;
    setState(() => _status = picked);
  }

  Future<void> _pickColor() async {
    final picked = await pickMobileSpanColor(context, selected: _color);
    if (picked == null || !mounted) return;
    setState(() => _color = picked.color);
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '请填写安排名称');
      return;
    }
    if (_end.isBefore(_start)) {
      setState(() => _formError = '结束日不能早于开始日');
      return;
    }
    if (_dayCount > 366) {
      setState(() => _formError = '单条安排跨度不能超过 366 天');
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
        await widget.repository.createSpan(
          PlanSpanDraft(
            projectId: widget.projectId,
            title: title,
            startDate: _start,
            endDate: _end,
            status: _status,
            description: _description.text.trim(),
            color: _color,
          ),
        );
      } else {
        await widget.repository.updateSpan(
          initial.copyWith(
            title: title,
            startDate: _start,
            endDate: _end,
            status: _status,
            description: _description.text.trim(),
            color: _color,
          ),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PlannerException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = '保存失败，请稍后重试';
      });
    }
  }

  Future<void> _delete() async {
    final initial = widget.initial;
    if (initial == null || _saving) return;
    final confirmed = await showMobileConfirm(
      context,
      title: '删除这条安排？',
      message: '「${initial.title}」会从月历和项目页移除；关联的任务会保留，只是不再归属这条安排。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.repository.deleteSpan(initial.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = '删除失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        MobileSheetHeader(
          title: _isEditing ? '编辑安排' : '新建安排',
          subtitle: _rangeSummary(),
          onClose: () => Navigator.of(context).pop(false),
        ),
        Expanded(
          child: MobileSheetBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextField(
                  key: const ValueKey<String>('mobile-span-editor-title'),
                  controller: _title,
                  autofocus: !_isEditing,
                  maxLength: 120,
                  buildCounter: _noCounter,
                  style: AppText.bodyStrong.copyWith(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: '安排名称，如：信息架构评审',
                    errorText: _titleError,
                    contentPadding: const EdgeInsets.all(AppSpacing.md),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSunken,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: AppColors.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      MobileFormField(
                        key: const ValueKey<String>('mobile-span-editor-start'),
                        label: '开始日',
                        value: monthDayWithWeekday(_start),
                        icon: Icons.play_circle_outline_rounded,
                        onTap: _pickStart,
                      ),
                      const Divider(height: 1),
                      MobileFormField(
                        key: const ValueKey<String>('mobile-span-editor-end'),
                        label: '结束日',
                        value: monthDayWithWeekday(_end),
                        icon: Icons.stop_circle_outlined,
                        onTap: _pickEnd,
                      ),
                      const Divider(height: 1),
                      MobileFormField(
                        label: '状态',
                        value: _status.label,
                        icon: Icons.flag_outlined,
                        onTap: _pickStatus,
                      ),
                      const Divider(height: 1),
                      MobileFormField(
                        label: '颜色',
                        value: _color == null ? '跟随项目颜色' : _color!.hex,
                        icon: Icons.palette_outlined,
                        onTap: _pickColor,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  key: const ValueKey<String>('mobile-span-editor-description'),
                  controller: _description,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 2000,
                  buildCounter: _noCounter,
                  style: AppText.small.copyWith(
                    fontSize: 13.5,
                    color: AppColors.textSecondary,
                  ),
                  decoration: const InputDecoration(
                    hintText: '说明（可选）',
                    contentPadding: EdgeInsets.all(AppSpacing.md),
                  ),
                ),
                if (_formError != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  MobileFormError(message: _formError!),
                ],
              ],
            ),
          ),
        ),
        MobileSheetFooter(
          children: <Widget>[
            if (_isEditing)
              TextButton(
                key: const ValueKey<String>('mobile-span-editor-delete'),
                onPressed: _saving ? null : _delete,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  minimumSize: const Size(0, MobileMetrics.minTapTarget),
                ),
                child: Text(
                  '删除',
                  style: AppText.bodyStrong.copyWith(
                    fontSize: 14,
                    color: AppColors.danger,
                  ),
                ),
              ),
            const Spacer(),
            MobileSecondaryButton(
              label: '取消',
              onPressed: _saving
                  ? null
                  : () => Navigator.of(context).pop(false),
            ),
            const SizedBox(width: AppSpacing.sm),
            MobilePrimaryButton(
              key: const ValueKey<String>('mobile-span-editor-save'),
              label: '保存',
              loading: _saving,
              onPressed: _submit,
            ),
          ],
        ),
      ],
    );
  }

  String _rangeSummary() {
    if (_end.isBefore(_start)) return '结束日不能早于开始日';
    return '${monthDay(_start)} – ${monthDay(_end)} · 共 $_dayCount 天';
  }

  static Widget? _noCounter(
    BuildContext context, {
    required int currentLength,
    required bool isFocused,
    required int? maxLength,
  }) => null;
}
