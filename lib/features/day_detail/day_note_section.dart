import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/theme.dart';

/// 每日备注的保存状态，决定页脚右上角那行轻提示。
enum NoteSaveStatus {
  /// 没有待保存的改动。
  idle,

  /// 有改动，等待防抖计时结束。
  dirty,

  /// 正在写入仓储。
  saving,

  /// 已写入。
  saved,

  /// 写入失败，可点击重试。
  failed,
}

/// 面板底部的每日备注区：正文 + 最多 3 条「当日重点」，失焦/防抖自动保存。
class DayNoteSection extends StatefulWidget {
  const DayNoteSection({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.focusItems,
    required this.status,
    required this.hasNote,
    required this.onBodyChanged,
    required this.onCommit,
    required this.onFocusItemsChanged,
    required this.onRetry,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 已保存的「当日重点」（最多 3 条）。
  final List<String> focusItems;

  final NoteSaveStatus status;

  /// 仓储里是否已经有这一天的备注记录。
  final bool hasNote;

  final ValueChanged<String> onBodyChanged;

  /// 立即落库（失焦、点「保存」、切日期前都会调用）。
  final VoidCallback onCommit;

  final ValueChanged<List<String>> onFocusItemsChanged;

  final VoidCallback onRetry;

  @override
  State<DayNoteSection> createState() => _DayNoteSectionState();
}

class _DayNoteSectionState extends State<DayNoteSection>
    with AutomaticKeepAliveClientMixin<DayNoteSection> {
  // 备注区移入滚动列表后，滚出视口时也保留正在输入的当日重点。
  @override
  bool get wantKeepAlive => true;

  /// 正在编辑的重点下标；-1 表示新增。null 表示没有在编辑。
  int? _editingIndex;
  TextEditingController? _chipController;
  FocusNode? _chipFocus;
  String? _chipError;

  @override
  void dispose() {
    _chipController?.dispose();
    _chipFocus?.dispose();
    super.dispose();
  }

  void _startEditing(int index) {
    setState(() {
      _editingIndex = index;
      _chipError = null;
      final existing = index < widget.focusItems.length
          ? widget.focusItems[index]
          : '';
      _chipController?.dispose();
      _chipController = TextEditingController(text: existing);
      _chipFocus?.dispose();
      _chipFocus = FocusNode();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chipFocus?.requestFocus();
    });
  }

  void _stopEditing() {
    setState(() {
      _editingIndex = null;
      _chipError = null;
      _chipController?.dispose();
      _chipController = null;
    });
  }

  void _commitEditing() {
    final index = _editingIndex;
    final controller = _chipController;
    if (index == null || controller == null) return;
    final text = controller.text.trim();
    final next = List<String>.from(widget.focusItems);
    if (text.isEmpty) {
      if (index < next.length) next.removeAt(index);
    } else {
      if (text.length > 60) {
        setState(() => _chipError = '单条重点不能超过 60 字');
        return;
      }
      if (index < next.length) {
        next[index] = text;
      } else {
        next.add(text);
      }
    }
    widget.onFocusItemsChanged(next);
    _stopEditing();
  }

  void _removeItem(int index) {
    final next = List<String>.from(widget.focusItems)..removeAt(index);
    widget.onFocusItemsChanged(next);
  }

  KeyEventResult _onChipKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _stopEditing();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = widget.controller.text;
    final isEmpty = body.trim().isEmpty && widget.focusItems.isEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('当日备注', style: AppText.bodyStrong.copyWith(fontSize: 13)),
              const Spacer(),
              _NoteStatusLabel(
                status: widget.status,
                empty: isEmpty && !widget.hasNote,
                onRetry: widget.onRetry,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildFocusRow(),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const ValueKey<String>('day-note-field'),
            controller: widget.controller,
            focusNode: widget.focusNode,
            minLines: 2,
            maxLines: 3,
            maxLength: 10000,
            buildCounter: (
              BuildContext context, {
              required int currentLength,
              required bool isFocused,
              required int? maxLength,
            }) => null,
            style: AppText.small.copyWith(
              fontSize: 12.5,
              height: 1.55,
              color: AppColors.textSecondary,
            ),
            decoration: const InputDecoration(
              hintText: '写下今天的复盘与想法…',
              contentPadding: EdgeInsets.all(AppSpacing.sm + 2),
            ),
            onChanged: widget.onBodyChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildFocusRow() {
    final items = widget.focusItems;
    final editing = _editingIndex;
    final children = <Widget>[
      Text(
        '当日重点',
        style: AppText.micro.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    ];

    for (var i = 0; i < items.length; i++) {
      if (editing == i) {
        children.add(_buildChipField());
      } else {
        children.add(_buildChip(items[i], i));
      }
    }

    if (editing == items.length || (editing == null && items.length < 3)) {
      if (editing == items.length) {
        children.add(_buildChipField());
      } else {
        children.add(_buildAddChip());
      }
    }

    if (_chipError != null) {
      children.add(
        Text(
          _chipError!,
          style: AppText.micro.copyWith(fontSize: 10, color: AppColors.danger),
        ),
      );
    }

    return Wrap(
      spacing: AppSpacing.xs + 2,
      runSpacing: AppSpacing.xs + 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  Widget _buildChip(String text, int index) {
    return GestureDetector(
      onTap: () => _startEditing(index),
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 3, AppSpacing.xs, 3),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.accentBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              style: AppText.micro.copyWith(
                fontSize: 11,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => _removeItem(index),
              child: const Padding(
                padding: EdgeInsets.all(1),
                child: Icon(
                  Icons.close_rounded,
                  size: 11,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddChip() {
    return GestureDetector(
      onTap: () => _startEditing(widget.focusItems.length),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.add_rounded,
              size: 11,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 2),
            Text('添加重点', style: AppText.micro.copyWith(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildChipField() {
    return Focus(
      onKeyEvent: _onChipKey,
      child: SizedBox(
        width: 148,
        height: 26,
        child: TextField(
          key: const ValueKey<String>('day-note-focus-field'),
          controller: _chipController,
          focusNode: _chipFocus,
          maxLength: 60,
          buildCounter: (
            BuildContext context, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) => null,
          onSubmitted: (_) => _commitEditing(),
          style: AppText.micro.copyWith(
            fontSize: 11,
            color: AppColors.textPrimary,
          ),
          decoration: const InputDecoration(
            hintText: '今天必须完成的一件事',
            isDense: true,
            contentPadding: EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: 4,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteStatusLabel extends StatelessWidget {
  const _NoteStatusLabel({
    required this.status,
    required this.empty,
    required this.onRetry,
  });

  final NoteSaveStatus status;
  final bool empty;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case NoteSaveStatus.saving:
        return Text('保存中…', style: AppText.micro.copyWith(fontSize: 11));
      case NoteSaveStatus.saved:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.check_circle_outline_rounded,
              size: 12,
              color: AppColors.success,
            ),
            const SizedBox(width: 3),
            Text(
              '已保存',
              style: AppText.micro.copyWith(
                fontSize: 11,
                color: AppColors.success,
              ),
            ),
          ],
        );
      case NoteSaveStatus.failed:
        return InkWell(
          onTap: onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.refresh_rounded,
                size: 12,
                color: AppColors.danger,
              ),
              const SizedBox(width: 2),
              Text(
                '保存失败 · 重试',
                style: AppText.micro.copyWith(
                  fontSize: 11,
                  color: AppColors.danger,
                ),
              ),
            ],
          ),
        );
      case NoteSaveStatus.dirty:
        return Text('待保存', style: AppText.micro.copyWith(fontSize: 11));
      case NoteSaveStatus.idle:
        return Text(
          empty ? '还没有备注' : '自动保存',
          style: AppText.micro.copyWith(fontSize: 11),
        );
    }
  }
}
