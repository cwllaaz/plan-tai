import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../../features/calendar/month_layout.dart';
import '../../features/day_detail/day_detail_math.dart';
import '../shared/mobile_sheets.dart';
import '../shared/mobile_widgets.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_note_editor.dart';
import 'mobile_task_actions.dart';
import 'mobile_task_list.dart';

/// 打开「当日详情」底部面板（手机：从底部拉起；平板：可作为右侧面板内容复用）。
///
/// 面板内部可翻到前一天/后一天，并且把新日期同步回外壳（月历选中态跟着变）。
Future<void> showMobileDaySheet(
  BuildContext context, {
  required PlannerRepository repository,
  required LocalDate date,
  required LocalDate today,
  ValueChanged<LocalDate>? onDateChange,
}) async {
  var current = date;
  await showMobileSheet<void>(
    context,
    heightFactor: MobileMetrics.daySheetHeightFactor,
    builder: (BuildContext sheetContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          return MobileDayPanel(
            repository: repository,
            date: current,
            today: today,
            onClose: () => Navigator.of(sheetContext).pop(),
            onDateChange: (LocalDate next) {
              setSheetState(() => current = next);
              onDateChange?.call(next);
            },
          );
        },
      );
    },
  );
}

/// 当日面板：日期头 + 完成率 + 当天安排 + 任务列表 + 每日备注。
///
/// 手机端放在底部面板里；平板三栏布局里作为右侧固定面板（`onClose == null`）。
class MobileDayPanel extends StatefulWidget {
  const MobileDayPanel({
    super.key,
    required this.repository,
    required this.date,
    required this.today,
    this.onClose,
    this.onDateChange,
    this.onOpenFullDay,
    this.showHeaderDivider = true,
    this.showNote = true,
    this.showAddButton = true,
  });

  final PlannerRepository repository;
  final LocalDate date;
  final LocalDate today;

  /// 关闭面板（底部面板用）；平板固定面板传 null。
  final VoidCallback? onClose;

  /// 翻到前一天/后一天。
  final ValueChanged<LocalDate>? onDateChange;

  /// 从手机下方的当日摘要展开完整当日详情（底部面板）。
  final VoidCallback? onOpenFullDay;

  final bool showHeaderDivider;

  /// 是否显示每日备注（手机摘要区不显示，完整面板/平板面板显示）。
  final bool showNote;

  final bool showAddButton;

  @override
  State<MobileDayPanel> createState() => _MobileDayPanelState();
}

class _MobileDayPanelState extends State<MobileDayPanel> {
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  List<PlannerTask> _tasks = const <PlannerTask>[];
  List<PlanSpan> _spans = const <PlanSpan>[];
  List<Project> _projects = const <Project>[];

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant MobileDayPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.date != widget.date) {
      _cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _listen() {
    final repository = widget.repository;
    final range = LocalDateRange.singleDay(widget.date);
    _subscriptions
      ..add(repository.watchTasksInRange(range).listen(_onTasks))
      ..add(repository.watchSpansInRange(range).listen(_onSpans))
      ..add(repository.watchProjects().listen(_onProjects));
  }

  void _cancel() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _onTasks(List<PlannerTask> tasks) {
    if (mounted) setState(() => _tasks = tasks);
  }

  void _onSpans(List<PlanSpan> spans) {
    if (mounted) setState(() => _spans = spans);
  }

  void _onProjects(List<Project> projects) {
    if (mounted) setState(() => _projects = projects);
  }

  Map<String, Project> get _projectsById => indexProjects(_projects);

  Future<void> _openEditor(PlannerTask task) async {
    await openMobileTaskEditor(
      context,
      repository: widget.repository,
      projects: _projects,
      defaultDate: widget.date,
      today: widget.today,
      initial: task,
    );
  }

  Future<void> _createTask() async {
    await openMobileTaskEditor(
      context,
      repository: widget.repository,
      projects: _projects,
      defaultDate: widget.date,
      today: widget.today,
    );
  }

  void _shiftDay(int delta) {
    final handler = widget.onDateChange;
    if (handler == null) return;
    handler(widget.date.addDays(delta));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MobileDayHeader(
          date: widget.date,
          today: widget.today,
          tasks: _tasks,
          onClose: widget.onClose,
          onOpenFullDay: widget.onOpenFullDay,
          onPrevious: widget.onDateChange == null ? null : () => _shiftDay(-1),
          onNext: widget.onDateChange == null ? null : () => _shiftDay(1),
          showDivider: widget.showHeaderDivider,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
            children: <Widget>[
              if (_spans.isNotEmpty) _buildSpans(),
              MobileTaskList(
                repository: widget.repository,
                tasks: _tasks,
                projects: _projectsById,
                today: widget.today,
                onEditTask: _openEditor,
                onAddTask: _createTask,
                showAddButton: widget.showAddButton,
              ),
              if (widget.showNote) ...<Widget>[
                const Divider(height: 1),
                MobileNoteEditor(
                  key: ValueKey<String>('mobile-note-${widget.date.iso}'),
                  repository: widget.repository,
                  date: widget.date,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSpans() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: <Widget>[
          for (final span in _spans)
            MobileTag(
              label: '安排 · ${span.title}',
              color: Color.alphaBlend(
                MobilePalette.spanInk(
                  spanColorOf(span, _projectsById[span.projectId]),
                ).withValues(alpha: 1),
                AppColors.surface,
              ),
              icon: Icons.view_week_outlined,
            ),
        ],
      ),
    );
  }
}

/// 当日面板的头部：日期 + 星期 + 完成率 + 前后翻页/关闭。
class MobileDayHeader extends StatelessWidget {
  const MobileDayHeader({
    super.key,
    required this.date,
    required this.today,
    required this.tasks,
    this.onClose,
    this.onPrevious,
    this.onNext,
    this.onOpenFullDay,
    this.showDivider = true,
  });

  final LocalDate date;
  final LocalDate today;
  final List<PlannerTask> tasks;
  final VoidCallback? onClose;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onOpenFullDay;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final stats = computeDayTaskStats(tasks);
    final isToday = date == today;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: showDivider
            ? const Border(bottom: BorderSide(color: AppColors.border))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (onPrevious != null)
                MobileIconButton(
                  key: const ValueKey<String>('mobile-day-prev'),
                  icon: Icons.chevron_left_rounded,
                  tooltip: '前一天',
                  onPressed: onPrevious,
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            monthDay(date),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.h1.copyWith(fontSize: 19),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          weekdayShort(date),
                          style: AppText.small.copyWith(
                            fontSize: 12.5,
                            color: AppColors.textTertiary,
                          ),
                        ),
                        if (isToday) ...<Widget>[
                          const SizedBox(width: AppSpacing.xs + 2),
                          const MobileTag(label: '今天', color: AppColors.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      stats.total == 0
                          ? '还没有任务'
                          : '${stats.total} 项任务 · 完成 ${stats.done} 项',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (onNext != null)
                MobileIconButton(
                  key: const ValueKey<String>('mobile-day-next'),
                  icon: Icons.chevron_right_rounded,
                  tooltip: '后一天',
                  onPressed: onNext,
                ),
              if (onOpenFullDay != null)
                MobileTextButton(
                  key: const ValueKey<String>('mobile-day-expand'),
                  label: '展开',
                  icon: Icons.open_in_full_rounded,
                  onPressed: onOpenFullDay,
                ),
              if (onClose != null)
                MobileIconButton(
                  key: const ValueKey<String>('mobile-day-close'),
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  onPressed: onClose,
                ),
            ],
          ),
          if (stats.total > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.xs + 2),
            CompletionBar(done: stats.done, total: stats.total),
          ],
        ],
      ),
    );
  }
}
