import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'day_detail_header.dart';
import 'day_detail_math.dart';
import 'day_note_section.dart';
import 'task_editor.dart';
import 'task_tile.dart';

/// 每日任务面板（右侧抽屉内容）。
///
/// 冻结接口见 docs/MODULE_API.md §3：抽屉的宽度、展开/收起动画由外壳负责，
/// 这里只实现可嵌入的内容面板。所有写操作都直接走 [PlannerRepository]，
/// 不缓存业务数据——仓储流会驱动界面自动刷新。
///
/// 组件结构：
/// ```
/// DayDetailPanel
/// └─ _DayDetailBody            // 按日期 key，切日期时整体重建（旧备注先落库）
///    ├─ DayDetailHeader        // 日期卡 / 前后一天 / 关闭 / 完成率 / 跨天阶段
///    ├─ 时间轴（滚动）         // 有时间 → 未安排时间；内联任务编辑器
///    ├─ 新建任务按钮
///    └─ DayNoteSection         // 当日备注 + 当日重点（防抖自动保存）
/// ```
class DayDetailPanel extends StatelessWidget {
  const DayDetailPanel({
    super.key,
    required this.repository,
    required this.date,
    required this.today,
    required this.onClose,
    required this.onDateChange,
  });

  /// 数据来源：订阅 `watchTasksInRange`（单日区间）、`watchSpansInRange`、
  /// `watchDailyNote` 与 `watchProjects`。
  final PlannerRepository repository;

  /// 当前面板对应的日期。
  final LocalDate date;

  /// 本机今天，用于"今天"标记与相对日期文案。
  final LocalDate today;

  /// 关闭面板（Esc 或右上角关闭）。
  final VoidCallback onClose;

  /// 切换到前一天/后一天；外壳负责保持面板展开并同步月历选中态。
  final ValueChanged<LocalDate> onDateChange;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 外壳展开动画从 0 开始；保持表单的最小排版宽度，由外壳裁切过渡帧。
          final width = constraints.maxWidth < 320
              ? 320.0
              : constraints.maxWidth;
          return OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: width,
            maxWidth: width,
            child: _DayDetailBody(
              // 只在切换日期时重置编辑器与滚动位置。
              key: ValueKey<String>('day-detail-${date.iso}'),
              repository: repository,
              date: date,
              today: today,
              onClose: onClose,
              onDateChange: onDateChange,
            ),
          );
        },
      ),
    );
  }
}

class _DayDetailBody extends StatefulWidget {
  const _DayDetailBody({
    super.key,
    required this.repository,
    required this.date,
    required this.today,
    required this.onClose,
    required this.onDateChange,
  });

  final PlannerRepository repository;
  final LocalDate date;
  final LocalDate today;
  final VoidCallback onClose;
  final ValueChanged<LocalDate> onDateChange;

  @override
  State<_DayDetailBody> createState() => _DayDetailBodyState();
}

class _DayDetailBodyState extends State<_DayDetailBody> {
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  List<PlannerTask> _tasks = const <PlannerTask>[];
  List<PlanSpan> _spans = const <PlanSpan>[];
  List<Project> _projects = const <Project>[];
  DailyNote? _note;

  bool _loadingTasks = true;

  bool _creating = false;
  String? _editingTaskId;

  /// 正在写库的任务，避免连续点击产生两个并发写（第二个必然触发 revision 冲突）。
  final Set<String> _pendingTaskIds = <String>{};

  _PanelNoticeData? _notice;
  Timer? _noticeTimer;

  final TextEditingController _noteController = TextEditingController();
  final FocusNode _noteFocus = FocusNode();
  List<String> _focusItems = const <String>[];
  Timer? _noteDebounce;
  bool _noteDirty = false;
  bool _noteSaving = false;
  NoteSaveStatus _noteStatus = NoteSaveStatus.idle;

  @override
  void initState() {
    super.initState();
    _noteFocus.addListener(_onNoteFocusChanged);
    _listen();
  }

  @override
  void didUpdateWidget(covariant _DayDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _cancelSubscriptions();
      _listen();
    }
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    _noteDebounce?.cancel();
    _noticeTimer?.cancel();
    _noteFocus.removeListener(_onNoteFocusChanged);
    _noteFocus.dispose();
    _flushNoteOnDispose();
    _noteController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 数据订阅
  // ---------------------------------------------------------------------------

  void _listen() {
    final repository = widget.repository;
    final dayRange = LocalDateRange.singleDay(widget.date);
    _subscriptions
      ..add(
        repository
            .watchTasksInRange(dayRange)
            .listen(_onTasks, onError: _onStreamError),
      )
      ..add(
        repository
            .watchSpansInRange(dayRange)
            .listen(_onSpans, onError: _onStreamError),
      )
      ..add(
        repository.watchProjects().listen(_onProjects, onError: _onStreamError),
      )
      ..add(
        repository
            .watchDailyNote(widget.date)
            .listen(_onNote, onError: _onStreamError),
      );
  }

  void _cancelSubscriptions() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _onTasks(List<PlannerTask> tasks) {
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loadingTasks = false;
      final editingId = _editingTaskId;
      if (editingId != null && !tasks.any((task) => task.id == editingId)) {
        // 任务被别处删除（或改到别的日期）后，编辑器不应继续挂着。
        _editingTaskId = null;
      }
    });
  }

  void _onSpans(List<PlanSpan> spans) {
    if (!mounted) return;
    setState(() => _spans = spans);
  }

  void _onProjects(List<Project> projects) {
    if (!mounted) return;
    setState(() => _projects = projects);
  }

  void _onNote(DailyNote? note) {
    if (!mounted) return;
    setState(() {
      _note = note;
      // 用户正在编辑时不要被流覆盖（否则光标会跳）。
      if (_noteDirty || _noteSaving) return;
      final body = note?.body ?? '';
      if (_noteController.text != body) {
        _noteController.value = TextEditingValue(
          text: body,
          selection: TextSelection.collapsed(offset: body.length),
        );
      }
      _focusItems =
          note?.focusItems.toList(growable: false) ?? const <String>[];
    });
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    _showNotice(_readableError(error), isError: true);
  }

  // ---------------------------------------------------------------------------
  // 备注
  // ---------------------------------------------------------------------------

  void _onNoteFocusChanged() {
    if (!_noteFocus.hasFocus) {
      _commitNote();
    }
  }

  void _onNoteBodyChanged(String value) {
    _markNoteDirty();
    setState(() => _noteStatus = NoteSaveStatus.dirty);
  }

  void _onFocusItemsChanged(List<String> items) {
    setState(() {
      _focusItems = List<String>.unmodifiable(items);
    });
    _markNoteDirty();
    setState(() => _noteStatus = NoteSaveStatus.dirty);
  }

  void _markNoteDirty() {
    _noteDirty = true;
    _noteDebounce?.cancel();
    _noteDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_saveNote());
    });
  }

  /// 立即保存（失焦、关闭、切日期前）。
  void _commitNote() {
    _noteDebounce?.cancel();
    unawaited(_saveNote());
  }

  Future<void> _saveNote() async {
    if (_noteSaving || !_noteDirty) return;
    final body = _noteController.text;
    final focusItems = List<String>.from(_focusItems);
    final existedBefore = _note != null;
    if (!existedBefore && body.trim().isEmpty && focusItems.isEmpty) {
      // 没有内容就不要凭空造一条空备注。
      setState(() {
        _noteDirty = false;
        _noteStatus = NoteSaveStatus.idle;
      });
      return;
    }

    _noteSaving = true;
    setState(() => _noteStatus = NoteSaveStatus.saving);
    try {
      await widget.repository.saveDailyNote(
        widget.date,
        body: body,
        focusItems: focusItems,
      );
      if (!mounted) return;
      final changedMeanwhile = _noteController.text != body;
      setState(() {
        _noteDirty = changedMeanwhile;
        _noteStatus = changedMeanwhile
            ? NoteSaveStatus.dirty
            : NoteSaveStatus.saved;
      });
      if (changedMeanwhile) {
        _markNoteDirty();
      }
    } on PlannerException catch (error) {
      if (!mounted) return;
      setState(() => _noteStatus = NoteSaveStatus.failed);
      _showNotice('备注保存失败：${error.message}', isError: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _noteStatus = NoteSaveStatus.failed);
      _showNotice('备注保存失败，请稍后重试', isError: true);
    } finally {
      _noteSaving = false;
    }
  }

  /// 面板被关闭/切换日期时把未保存的备注写回**旧日期**，不让用户白写。
  void _flushNoteOnDispose() {
    if (!_noteDirty) return;
    final body = _noteController.text;
    final focusItems = List<String>.from(_focusItems);
    if (body.trim().isEmpty && focusItems.isEmpty && _note == null) return;
    unawaited(
      widget.repository
          .saveDailyNote(widget.date, body: body, focusItems: focusItems)
          .then<void>((DailyNote saved) {})
          .catchError((Object error) {}),
    );
  }

  // ---------------------------------------------------------------------------
  // 任务操作
  // ---------------------------------------------------------------------------

  void _startCreate() {
    setState(() {
      _creating = true;
      _editingTaskId = null;
    });
    _scrollToTop();
  }

  void _startEdit(PlannerTask task) {
    setState(() {
      _creating = false;
      _editingTaskId = task.id;
    });
  }

  void _cancelEditor() {
    setState(() {
      _creating = false;
      _editingTaskId = null;
    });
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final position = _timelineKey.currentState;
      if (position != null) position.scrollToTop();
    });
  }

  final GlobalKey<_TimelineState> _timelineKey = GlobalKey<_TimelineState>();

  Future<void> _toggleDone(PlannerTask task) async {
    if (_pendingTaskIds.contains(task.id)) return;
    setState(() => _pendingTaskIds.add(task.id));
    final next = task.isDone ? TaskStatus.todo : TaskStatus.done;
    try {
      await widget.repository.updateTask(task.copyWith(status: next));
    } on PlannerException catch (error) {
      _showNotice(error.message, isError: true);
    } catch (_) {
      _showNotice('更新任务状态失败，请稍后重试', isError: true);
    } finally {
      if (mounted) {
        setState(() => _pendingTaskIds.remove(task.id));
      } else {
        _pendingTaskIds.remove(task.id);
      }
    }
  }

  Future<String?> _submitCreate(TaskEditorInput input) async {
    try {
      await widget.repository.createTask(
        PlannerTaskDraft(
          title: input.title,
          projectId: input.projectId,
          scheduledDate: input.date,
          timeSlot: input.timeSlot,
          priority: input.priority,
          notes: input.notes,
        ),
      );
      if (!mounted) return null;
      setState(() => _creating = false);
      return null;
    } on PlannerException catch (error) {
      return error.message;
    } catch (_) {
      return '任务保存失败，请稍后重试';
    }
  }

  Future<String?> _submitUpdate(PlannerTask task, TaskEditorInput input) async {
    final projectChanged = task.projectId != input.projectId;
    try {
      await widget.repository.updateTask(
        task.copyWith(
          title: input.title,
          projectId: input.projectId,
          // 换项目后原阶段可能已不属于新项目，必须解除关联，否则模型校验失败。
          spanId: projectChanged ? null : task.spanId,
          scheduledDate: input.date,
          timeSlot: input.timeSlot,
          priority: input.priority,
          notes: input.notes,
        ),
      );
      if (!mounted) return null;
      setState(() => _editingTaskId = null);
      if (task.scheduledDate != input.date) {
        _showNotice('已移到 ${monthDayWithWeekday(input.date)}');
      }
      return null;
    } on PlannerException catch (error) {
      return error.message;
    } catch (_) {
      return '任务保存失败，请稍后重试';
    }
  }

  Future<void> _deleteTask(PlannerTask task) async {
    if (_pendingTaskIds.contains(task.id)) return;
    setState(() => _pendingTaskIds.add(task.id));
    try {
      await widget.repository.deleteTask(task.id);
      if (!mounted) return;
      setState(() {
        if (_editingTaskId == task.id) _editingTaskId = null;
      });
      _showNotice(
        '已删除「${task.title}」',
        actionLabel: '撤销',
        onAction: () => unawaited(_restoreTask(task)),
      );
    } on PlannerException catch (error) {
      _showNotice(error.message, isError: true);
    } catch (_) {
      _showNotice('删除任务失败，请稍后重试', isError: true);
    } finally {
      _pendingTaskIds.remove(task.id);
    }
  }

  /// 撤销删除：软删除无法直接恢复，这里按原字段重新建一条（内容与归属不变）。
  Future<void> _restoreTask(PlannerTask task) async {
    try {
      await widget.repository.createTask(
        PlannerTaskDraft(
          title: task.title,
          projectId: task.projectId,
          spanId: task.spanId,
          notes: task.notes,
          scheduledDate: task.scheduledDate,
          timeSlot: task.timeSlot,
          priority: task.priority,
          status: task.status,
          sortOrder: task.sortOrder,
        ),
      );
      if (!mounted) return;
      _showNotice('已恢复「${task.title}」');
    } on PlannerException catch (error) {
      _showNotice('恢复失败：${error.message}', isError: true);
    } catch (_) {
      _showNotice('恢复失败，请稍后重试', isError: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 反馈
  // ---------------------------------------------------------------------------

  String _readableError(Object error) {
    if (error is PlannerException) return error.message;
    return '操作失败，请稍后重试';
  }

  /// 面板内联提示（5 秒后自动消失）。
  ///
  /// 不用 SnackBar：它会浮在窗口底部压住当日备注区，而抽屉本身很窄，
  /// 内联提示更贴近操作、也不会遮住可编辑内容。
  void _showNotice(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    bool isError = false,
  }) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() {
      _notice = _PanelNoticeData(
        message: message,
        actionLabel: actionLabel,
        onAction: onAction,
        isError: isError,
      );
    });
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _notice = null);
    });
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  Project? _projectOf(String? projectId) {
    if (projectId == null) return null;
    for (final project in _projects) {
      if (project.id == projectId) return project;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stats = computeDayTaskStats(_tasks);
    final timed = timedTasksOf(_tasks);
    final untimed = untimedTasksOf(_tasks);
    final isEmpty = _tasks.isEmpty && !_creating && !_loadingTasks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DayDetailHeader(
          date: widget.date,
          today: widget.today,
          stats: stats,
          spans: _spans,
          projects: _projects,
          onPrevious: () => widget.onDateChange(widget.date.addDays(-1)),
          onNext: () => widget.onDateChange(widget.date.addDays(1)),
          onClose: widget.onClose,
        ),
        const Divider(height: 1),
        if (!isEmpty) _AddTaskBar(onTap: _creating ? null : _startCreate),
        if (_notice != null)
          _PanelNotice(
            key: const ValueKey<String>('day-detail-notice'),
            data: _notice!,
            onDismiss: () {
              _noticeTimer?.cancel();
              setState(() => _notice = null);
            },
          ),
        Expanded(child: _buildTimeline(timed, untimed)),
      ],
    );
  }

  Widget _buildTimeline(List<PlannerTask> timed, List<PlannerTask> untimed) {
    final children = <Widget>[];
    if (_loadingTasks) children.add(const _TimelineSkeleton());
    if (_tasks.isEmpty && !_creating && !_loadingTasks) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: _EmptyDay(
            key: const ValueKey<String>('day-detail-empty'),
            date: widget.date,
            today: widget.today,
            onCreate: _startCreate,
          ),
        ),
      );
    }
    if (_creating) {
      children.add(
        TaskEditorCard(
          key: const ValueKey<String>('task-editor-new'),
          initial: null,
          defaultDate: widget.date,
          today: widget.today,
          projects: _projects,
          onCancel: _cancelEditor,
          onSubmit: _submitCreate,
        ),
      );
    }
    if (timed.isNotEmpty) {
      children.add(_SectionLabel('今日安排', trailing: '${timed.length} 项'));
      for (final task in timed) {
        children.add(_buildRow(task));
      }
    }
    if (untimed.isNotEmpty) {
      children.add(const _DashedDivider(label: '未安排时间'));
      for (final task in untimed) {
        children.add(_buildRow(task));
      }
    }
    children.addAll([
      const SizedBox(height: AppSpacing.sm),
      const Divider(height: 1),
      DayNoteSection(
        key: const ValueKey<String>('day-detail-notes'),
        controller: _noteController,
        focusNode: _noteFocus,
        focusItems: _focusItems,
        status: _noteStatus,
        hasNote: _note != null,
        onBodyChanged: _onNoteBodyChanged,
        onCommit: _commitNote,
        onFocusItemsChanged: _onFocusItemsChanged,
        onRetry: _commitNote,
      ),
    ]);

    return _Timeline(key: _timelineKey, children: children);
  }

  Widget _buildRow(PlannerTask task) {
    if (_editingTaskId == task.id) {
      return TaskEditorCard(
        key: ValueKey<String>('task-editor-${task.id}'),
        initial: task,
        defaultDate: widget.date,
        today: widget.today,
        projects: _projects,
        onCancel: _cancelEditor,
        onSubmit: (TaskEditorInput input) => _submitUpdate(task, input),
        onDelete: () => unawaited(_deleteTask(task)),
      );
    }
    final overlaps = overlappingTasks(task, _tasks);
    return TaskTile(
      key: ValueKey<String>('task-tile-${task.id}'),
      task: task,
      project: _projectOf(task.projectId),
      overlap: overlaps.isEmpty ? null : overlaps.first,
      busy: _pendingTaskIds.contains(task.id),
      onToggle: () => unawaited(_toggleDone(task)),
      onEdit: () => _startEdit(task),
      onDelete: () => unawaited(_deleteTask(task)),
    );
  }
}

/// 可滚动的时间轴容器；暴露滚动控制，新建任务时滚回顶部。
class _Timeline extends StatefulWidget {
  const _Timeline({super.key, required this.children});

  final List<Widget> children;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  final ScrollController _controller = ScrollController();

  void scrollToTop() {
    if (!_controller.hasClients) return;
    if (_controller.offset <= 0) return;
    unawaited(
      _controller.animateTo(
        0,
        duration: AppMotion.drawer,
        curve: AppMotion.curve,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView(
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.xs,
          ),
          children: widget.children,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs + 2,
        AppSpacing.sm,
        AppSpacing.xs + 2,
        AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: AppText.micro.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: AppColors.textTertiary,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(trailing!, style: AppText.micro.copyWith(fontSize: 10.5)),
        ],
      ),
    );
  }
}

/// 「未安排时间」的虚线分隔。
class _DashedDivider extends StatelessWidget {
  const _DashedDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs + 2,
        AppSpacing.md,
        AppSpacing.xs + 2,
        AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          const Expanded(
            child: CustomPaint(
              painter: _DashedLinePainter(color: AppColors.borderStrong),
              size: Size(double.infinity, 1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Text(
              label,
              style: AppText.micro.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: AppColors.textTertiary,
              ),
            ),
          ),
          const Expanded(
            child: CustomPaint(
              painter: _DashedLinePainter(color: AppColors.borderStrong),
              size: Size(double.infinity, 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final y = size.height / 2;
    var x = 0.0;
    while (x < size.width) {
      final end = x + 4 > size.width ? size.width : x + 4;
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += 8;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _AddTaskBar extends StatelessWidget {
  const _AddTaskBar({required this.onTap});

  /// null = 编辑器已经打开，按钮置灰。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: SizedBox(
        height: 34,
        child: OutlinedButton.icon(
          key: const ValueKey<String>('day-detail-add'),
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
            side: const BorderSide(color: AppColors.border),
          ),
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('新建任务'),
        ),
      ),
    );
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({
    super.key,
    required this.date,
    required this.today,
    required this.onCreate,
  });

  final LocalDate date;
  final LocalDate today;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final isToday = date == today;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: AppColors.surfaceSunken,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.event_available_outlined,
                size: 22,
                color: AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              isToday ? '今天还没有安排' : '这一天还没有安排',
              style: AppText.h2.copyWith(fontSize: 15),
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            Text(
              '加一条任务，把这一天变成可执行的计划。',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(height: 1.6),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              key: const ValueKey<String>('day-detail-empty-create'),
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('新建任务'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineSkeleton extends StatelessWidget {
  const _TimelineSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < 4; i++)
            Container(
              height: 52,
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surfaceSunken,
                borderRadius: AppRadius.control,
              ),
            ),
        ],
      ),
    );
  }
}

/// 面板内联提示的数据。
final class _PanelNoticeData {
  const _PanelNoticeData({
    required this.message,
    this.actionLabel,
    this.onAction,
    this.isError = false,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isError;
}

/// 贴在备注区上方的内联提示条（错误 / 删除撤销 / 日期变更），5 秒自动消失。
///
/// 之所以不用 SnackBar：抽屉只有 420 宽，浮在窗口底部的提示条会压住备注输入框，
/// 而且跨窗口的 SnackBar 队列在桌面端容易遮挡上下文。
class _PanelNotice extends StatelessWidget {
  const _PanelNotice({super.key, required this.data, required this.onDismiss});

  final _PanelNoticeData data;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final isError = data.isError;
    final foreground = isError ? AppColors.danger : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 5, AppSpacing.xs, 5),
        decoration: BoxDecoration(
          color: isError ? AppColors.dangerSoft : AppColors.surfaceSunken,
          borderRadius: AppRadius.control,
          border: Border.all(
            color: isError ? const Color(0x59E5484D) : AppColors.border,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 14,
              color: foreground,
            ),
            const SizedBox(width: AppSpacing.xs + 2),
            Expanded(
              child: Text(
                data.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(
                  fontSize: 12,
                  height: 1.35,
                  color: foreground,
                ),
              ),
            ),
            if (data.actionLabel != null && data.onAction != null)
              TextButton(
                key: const ValueKey<String>('day-detail-notice-action'),
                onPressed: () {
                  onDismiss();
                  data.onAction!.call();
                },
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  minimumSize: const Size(0, 24),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  data.actionLabel!,
                  style: AppText.small.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.accent,
                  ),
                ),
              )
            else
              InkWell(
                onTap: onDismiss,
                borderRadius: AppRadius.control,
                child: const SizedBox(
                  width: 22,
                  height: 22,
                  child: Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
