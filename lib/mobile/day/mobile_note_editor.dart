import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../../features/day_detail/day_note_section.dart';

/// 移动端每日备注：正文 + 最多 3 条当日重点，600ms 防抖自动保存。
///
/// 复用桌面 `DayNoteSection` 的外观与交互（同一套「正在保存 / 已保存 / 失败重试」
/// 语义），保存逻辑在这里实现：失焦、切日期、关闭面板前强制落库；
/// 空内容且本来没有记录时不凭空创建空备注。
class MobileNoteEditor extends StatefulWidget {
  const MobileNoteEditor({
    super.key,
    required this.repository,
    required this.date,
    this.onEditing,
  });

  final PlannerRepository repository;
  final LocalDate date;
  final VoidCallback? onEditing;

  @override
  State<MobileNoteEditor> createState() => _MobileNoteEditorState();
}

class _MobileNoteEditorState extends State<MobileNoteEditor>
    with AutomaticKeepAliveClientMixin<MobileNoteEditor> {
  static const Duration _debounce = Duration(milliseconds: 600);

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  StreamSubscription<DailyNote?>? _subscription;
  DailyNote? _note;
  List<String> _focusItems = const <String>[];
  Timer? _timer;
  bool _dirty = false;
  bool _saving = false;
  Future<DailyNote>? _pendingWrite;

  @override
  bool get wantKeepAlive => true;
  NoteSaveStatus _status = NoteSaveStatus.idle;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    _subscribe();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focusNode.removeListener(_onFocusChanged);
    _disposeFlush();
    unawaited(_subscription?.cancel());
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 组件销毁时把未保存的备注写回（此时不能再 setState，也不能等防抖）。
  void _disposeFlush() {
    if (!_dirty) return;
    final body = _controller.text;
    final focusItems = List<String>.from(_focusItems);
    if (_note == null && body.trim().isEmpty && focusItems.isEmpty) return;
    final pending = _pendingWrite;
    final repository = widget.repository;
    final date = widget.date;
    unawaited(() async {
      try {
        if (pending != null) {
          try {
            final saved = await pending;
            if (saved.body == body &&
                _sameItems(saved.focusItems, focusItems)) {
              return;
            }
          } on Object {
            // 重新尝试写入离开时捕获的最后一个版本。
          }
        }
        await repository.saveDailyNote(
          date,
          body: body,
          focusItems: focusItems,
        );
      } on Object {
        // 已离开面板，不能再更新已销毁状态。
      }
    }());
  }

  void _subscribe() {
    _subscription = widget.repository
        .watchDailyNote(widget.date)
        .listen(_onNote);
  }

  void _onNote(DailyNote? note) {
    if (!mounted) return;
    setState(() {
      _note = note;
      if (_dirty || _saving) return;
      final body = note?.body ?? '';
      if (_controller.text != body) {
        _controller.value = TextEditingValue(
          text: body,
          selection: TextSelection.collapsed(offset: body.length),
        );
      }
      _focusItems =
          note?.focusItems.toList(growable: false) ?? const <String>[];
    });
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _flush();
  }

  void _onBodyChanged(String value) {
    _dirty = true;
    _timer?.cancel();
    setState(() => _status = NoteSaveStatus.dirty);
    _timer = Timer(_debounce, () {
      unawaited(_save());
    });
  }

  void _onFocusItemsChanged(List<String> items) {
    widget.onEditing?.call();
    setState(() {
      _focusItems = List<String>.unmodifiable(items);
      _status = NoteSaveStatus.dirty;
    });
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      unawaited(_save());
    });
  }

  /// 立即保存（失焦 / 关闭 / 切日期）。
  void _flush() {
    _timer?.cancel();
    unawaited(_save());
  }

  static bool _sameItems(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    final body = _controller.text;
    final focusItems = List<String>.from(_focusItems);
    if (_note == null && body.trim().isEmpty && focusItems.isEmpty) {
      _dirty = false;
      if (mounted) setState(() => _status = NoteSaveStatus.idle);
      return;
    }
    _saving = true;
    if (mounted) setState(() => _status = NoteSaveStatus.saving);
    try {
      final write = widget.repository.saveDailyNote(
        widget.date,
        body: body,
        focusItems: focusItems,
      );
      _pendingWrite = write;
      await write;
      if (!mounted) return;
      final changedMeanwhile =
          _controller.text != body || !_sameItems(_focusItems, focusItems);
      setState(() {
        _dirty = changedMeanwhile;
        _status = changedMeanwhile
            ? NoteSaveStatus.dirty
            : NoteSaveStatus.saved;
      });
      if (changedMeanwhile) {
        _timer?.cancel();
        _timer = Timer(_debounce, () {
          unawaited(_save());
        });
      }
    } on PlannerException catch (error) {
      if (!mounted) return;
      setState(() => _status = NoteSaveStatus.failed);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('备注保存失败：${error.message}')));
    } on Object {
      if (!mounted) return;
      setState(() => _status = NoteSaveStatus.failed);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('备注保存失败，请稍后重试')));
    } finally {
      _pendingWrite = null;
      _saving = false;
    }
  }

  void _retry() {
    _dirty = true;
    _flush();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (hasFocus) {
        if (hasFocus) widget.onEditing?.call();
      },
      child: DayNoteSection(
        controller: _controller,
        focusNode: _focusNode,
        focusItems: _focusItems,
        status: _status,
        hasNote: _note != null,
        onBodyChanged: _onBodyChanged,
        onCommit: _flush,
        onFocusItemsChanged: _onFocusItemsChanged,
        onRetry: _retry,
      ),
    );
  }
}
