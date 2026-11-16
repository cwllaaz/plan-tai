import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';

/// 新建 / 编辑项目（名称、简介、颜色）。
///
/// 归档与删除是项目详情页的独立动作，不混在这张表单里，避免误触。
Future<bool> showMobileProjectEditorSheet(
  BuildContext context, {
  required PlannerRepository repository,
  Project? initial,
}) async {
  final saved = await showMobileSheet<bool>(
    context,
    heightFactor: 0.78,
    isDismissible: false,
    enableDrag: false,
    builder: (BuildContext sheetContext) =>
        _MobileProjectEditorSheet(repository: repository, initial: initial),
  );
  return saved ?? false;
}

class _MobileProjectEditorSheet extends StatefulWidget {
  const _MobileProjectEditorSheet({required this.repository, this.initial});

  final PlannerRepository repository;
  final Project? initial;

  @override
  State<_MobileProjectEditorSheet> createState() =>
      _MobileProjectEditorSheetState();
}

class _MobileProjectEditorSheetState extends State<_MobileProjectEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late ProjectColor _color;
  bool _saving = false;
  String? _nameError;
  String? _formError;
  bool _allowPop = false;

  bool get _isEditing => widget.initial != null;

  late final String _initialName;
  late final String _initialDescription;
  late final ProjectColor _initialColor;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _description = TextEditingController(text: initial?.description ?? '');
    _color = initial?.color ?? ProjectColor.defaultColor;
    _initialName = _name.text;
    _initialDescription = _description.text;
    _initialColor = _color;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _name.text != _initialName ||
      _description.text != _initialDescription ||
      _color != _initialColor;

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final discard = await showMobileConfirm(
      context,
      title: '放弃修改？',
      message: '项目信息还没有保存。',
      confirmLabel: '放弃',
      danger: true,
    );
    if (!discard || !mounted) return;
    Navigator.of(context).pop(false);
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请填写项目名称');
      return;
    }
    setState(() {
      _saving = true;
      _nameError = null;
      _formError = null;
    });
    try {
      final initial = widget.initial;
      if (initial == null) {
        await widget.repository.createProject(
          ProjectDraft(
            name: name,
            description: _description.text.trim(),
            color: _color,
          ),
        );
      } else {
        await widget.repository.updateProject(
          initial.copyWith(
            name: name,
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_confirmDiscard());
      },
      child: Column(
        children: <Widget>[
          MobileSheetHeader(
            title: _isEditing ? '编辑项目' : '新建项目',
            subtitle: '项目颜色会用在月历横条与任务圆点上',
            onClose: _requestClose,
          ),
          Expanded(
            child: MobileSheetBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextField(
                    key: const ValueKey<String>('mobile-project-editor-name'),
                    controller: _name,
                    autofocus: !_isEditing,
                    maxLength: 80,
                    buildCounter: _noCounter,
                    style: AppText.bodyStrong.copyWith(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '项目名称，如：产品官网改版',
                      errorText: _nameError,
                      contentPadding: const EdgeInsets.all(AppSpacing.md),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '颜色',
                    style: AppText.caption.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      for (final color in ProjectColor.palette)
                        _ColorOption(
                          color: color,
                          selected: color == _color,
                          onTap: () => setState(() => _color = color),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    key: const ValueKey<String>(
                      'mobile-project-editor-description',
                    ),
                    controller: _description,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 2000,
                    buildCounter: _noCounter,
                    style: AppText.small.copyWith(
                      fontSize: 13.5,
                      color: AppColors.textSecondary,
                    ),
                    decoration: const InputDecoration(
                      hintText: '简介（可选）',
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
              MobileSecondaryButton(
                key: const ValueKey<String>('mobile-project-editor-cancel'),
                label: '取消',
                onPressed: _saving ? null : _requestClose,
              ),
              const SizedBox(width: AppSpacing.sm),
              MobilePrimaryButton(
                key: const ValueKey<String>('mobile-project-editor-save'),
                label: '保存',
                loading: _saving,
                onPressed: _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    final discard = await showMobileConfirm(
      context,
      title: '放弃修改？',
      message: '项目信息还没有保存。',
      confirmLabel: '放弃',
      danger: true,
    );
    if (!discard || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(false);
    });
  }

  static Widget? _noCounter(
    BuildContext context, {
    required int currentLength,
    required bool isFocused,
    required int? maxLength,
  }) => null;
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final ProjectColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey<String>('mobile-project-color-${color.hex}'),
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: MobileMetrics.minTapTarget,
        height: MobileMetrics.minTapTarget,
        child: Center(
          child: Container(
            width: 30,
            height: 30,
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
                    size: 18,
                    color: AppColors.textInverse,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
