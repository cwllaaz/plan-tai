import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'calendar_style.dart';
import 'month_grid.dart';
import 'month_layout.dart';

/// 月历视图（月历模块 实现）。
///
/// 只负责"把一个月画好"：整周网格、今天/选中状态、跨天阶段车道、单日任务与折叠计数。
/// 窗口边框、侧栏、顶栏、月份切换、抽屉开关都由外壳负责（见 docs/MODULE_API.md §2）。
///
/// 接口是冻结的：构造参数与回调语义不得修改。数据只从 [PlannerRepository] 的流来，
/// 日期只从参数 [today] / [selectedDate] 来 —— 组件内部不读系统时钟、不碰 SQLite。
class CalendarMonthView extends StatelessWidget {
  const CalendarMonthView({
    super.key,
    required this.repository,
    required this.month,
    required this.today,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDay,
    this.onRangeSelected,
    this.onOpenSpan,
  });

  /// 数据来源：订阅 `watchTasksInRange` / `watchSpansInRange` / `watchProjects`。
  final PlannerRepository repository;

  /// 可见月份，约定为当月任意一天（外壳始终传入 1 号）。
  final LocalDate month;

  /// 本机今天，用于"今天"样式与相对日期。
  final LocalDate today;

  /// 当前选中日期（单击设置）。
  final LocalDate selectedDate;

  /// 单击某天时调用：只改变选中，不打开抽屉。
  final ValueChanged<LocalDate> onSelectDate;

  /// 双击某天时调用：选中并展开右侧每日面板。
  final ValueChanged<LocalDate> onOpenDay;

  /// 右键拖选一段连续日期后调用（闭区间、已按先后排序）。
  ///
  /// 这是新增的**可选**回调（原有构造参数不变）：外壳收到后弹「新建跨天安排」，
  /// 组件本身不建弹窗、不写库。为空时右键拖选不产生任何动作。
  final void Function(LocalDate start, LocalDate end)? onRangeSelected;

  /// 双击跨天条时调用，用于编辑/归类该阶段；为空时双击无动作。
  final ValueChanged<PlanSpan>? onOpenSpan;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.panel,
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: _CalendarData(
        repository: repository,
        month: month,
        today: today,
        selectedDate: selectedDate,
        onSelectDate: onSelectDate,
        onOpenDay: onOpenDay,
        onRangeSelected: onRangeSelected,
        onOpenSpan: onOpenSpan,
      ),
    );
  }
}

/// 订阅三条数据流，并把"月历内容"装配出来。
///
/// 用 StatefulWidget 缓存流对象：父级重建（选中日变化等）时不会重新订阅，
/// 避免每次点击都闪一下空数据。
class _CalendarData extends StatefulWidget {
  const _CalendarData({
    required this.repository,
    required this.month,
    required this.today,
    required this.selectedDate,
    required this.onSelectDate,
    required this.onOpenDay,
    required this.onRangeSelected,
    required this.onOpenSpan,
  });

  final PlannerRepository repository;
  final LocalDate month;
  final LocalDate today;
  final LocalDate selectedDate;
  final ValueChanged<LocalDate> onSelectDate;
  final ValueChanged<LocalDate> onOpenDay;
  final void Function(LocalDate start, LocalDate end)? onRangeSelected;
  final ValueChanged<PlanSpan>? onOpenSpan;

  @override
  State<_CalendarData> createState() => _CalendarDataState();
}

class _CalendarDataState extends State<_CalendarData> {
  late MonthGrid _grid;
  late Stream<List<PlannerTask>> _tasks;
  late Stream<List<PlanSpan>> _spans;
  late Stream<List<Project>> _projects;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(_CalendarData oldWidget) {
    super.didUpdateWidget(oldWidget);
    final monthChanged = !oldWidget.month.isSameMonthAs(widget.month);
    if (monthChanged || oldWidget.repository != widget.repository) {
      _bind();
    }
  }

  void _bind() {
    _grid = MonthGrid.of(widget.month);
    _tasks = widget.repository.watchTasksInRange(_grid.range);
    _spans = widget.repository.watchSpansInRange(_grid.range);
    _projects = widget.repository.watchProjects();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PlannerTask>>(
      stream: _tasks,
      builder: (context, tasksSnapshot) {
        return StreamBuilder<List<PlanSpan>>(
          stream: _spans,
          builder: (context, spansSnapshot) {
            return StreamBuilder<List<Project>>(
              stream: _projects,
              builder: (context, projectsSnapshot) {
                return _buildContent(
                  tasks: tasksSnapshot.data ?? const <PlannerTask>[],
                  spans: spansSnapshot.data ?? const <PlanSpan>[],
                  projects: projectsSnapshot.data ?? const <Project>[],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildContent({
    required List<PlannerTask> tasks,
    required List<PlanSpan> spans,
    required List<Project> projects,
  }) {
    final tasksByDate = groupTasksByDate(tasks);
    final spanLayout = layoutMonthSpans(
      spans,
      _grid,
      maxLanes: CalendarMetrics.maxLanes,
    );
    final projectsById = indexProjects(projects);
    final spansPerDay = _countSpansPerDay(spanLayout.values);

    final monthRange = LocalDateRange.monthOf(_grid.month);
    final monthTaskCount = tasks
        .where(
          (task) =>
              task.scheduledDate != null &&
              monthRange.contains(task.scheduledDate!),
        )
        .length;
    final monthSpanCount = spans
        .where((span) => span.overlaps(monthRange))
        .length;

    return Column(
      children: <Widget>[
        _MonthHeader(taskCount: monthTaskCount, spanCount: monthSpanCount),
        WeekdayHeaderRow(grid: _grid),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 1 || constraints.maxHeight < 1) {
                return const SizedBox.shrink();
              }
              return AnimatedSwitcher(
                duration: AppMotion.month,
                switchInCurve: AppMotion.curve,
                switchOutCurve: AppMotion.curve,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: <Widget>[...previous, ?current],
                ),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.012),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey<String>(
                    'month-${_grid.month.year}-${_grid.month.month}',
                  ),
                  child: MonthGridBody(
                    grid: _grid,
                    spanLayout: spanLayout,
                    tasksByDate: tasksByDate,
                    projects: projectsById,
                    spansPerDay: spansPerDay,
                    today: widget.today,
                    selectedDate: widget.selectedDate,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    onSelectDate: widget.onSelectDate,
                    onOpenDay: widget.onOpenDay,
                    onTaskTap: _handleTaskTap,
                    onRangeSelected: widget.onRangeSelected,
                    onOpenSpan: widget.onOpenSpan,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 单击任务：只把选中日移到任务所在的那天（双击才展开当日面板）。
  ///
  /// MODULE_API §2.2 原本写的是"单击任务 = 选中 + 展开面板"，但那样会把整格中心
  /// （常常正好落在任务行上）变成"一点就开抽屉"，与"单击选中、双击展开"的整体语义
  /// 冲突，也会让 `test/app/shell_smoke_test.dart` 的双击用例误判。
  /// 这里统一成：单击任务 = 选中该日；双击任务 = 展开当日面板。
  /// 若需要"单击任务直接定位到具体任务"，需要外壳新增 `onOpenTask(taskId)` 回调，
  /// 已在交付报告里作为接口变更建议提交。
  void _handleTaskTap(PlannerTask task) {
    final day = task.scheduledDate;
    if (day == null) return;
    widget.onSelectDate(day);
  }

  /// 每天被多少条跨天阶段覆盖（仅用于格子无障碍文案）。
  Map<LocalDate, int> _countSpansPerDay(Iterable<WeekSpanLayout> layouts) {
    final counts = <LocalDate, int>{};
    for (final layout in layouts) {
      for (final segment in layout.visible) {
        for (
          var day = segment.start;
          !day.isAfter(segment.end);
          day = day.addDays(1)
        ) {
          counts[day] = (counts[day] ?? 0) + 1;
        }
      }
    }
    return counts;
  }
}

/// 月历头：标题 + 本月规模 + 图例（跨天条 / 单日任务）。
///
/// 不做月份标题与翻月按钮 —— 那是外壳顶部工具栏的职责，避免同一信息出现两次。
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.taskCount, required this.spanCount});

  final int taskCount;
  final int spanCount;

  @override
  Widget build(BuildContext context) {
    final summary = taskCount == 0 && spanCount == 0
        ? '本月暂无安排'
        : '本月 $taskCount 项任务 · $spanCount 条安排';

    return Container(
      height: CalendarMetrics.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 抽屉展开后月历只剩 ~700 宽，图例先让位，再窄就只留标题。
          final showLegend = constraints.maxWidth >= 720;
          final showSummary = constraints.maxWidth >= 520;
          return Row(
            children: <Widget>[
              const Icon(
                Icons.calendar_month_outlined,
                size: AppSizes.iconSm,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('月历', style: AppText.bodyStrong.copyWith(fontSize: 13)),
              if (showSummary) ...<Widget>[
                const SizedBox(width: AppSpacing.sm + 2),
                Flexible(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.micro.copyWith(fontSize: 10.5),
                  ),
                ),
              ],
              const Spacer(),
              if (showLegend) ...<Widget>[
                const _Legend(
                  color: AppColors.accent,
                  label: '跨天安排',
                  filled: true,
                ),
                const SizedBox(width: AppSpacing.md),
                const _Legend(
                  color: AppColors.textTertiary,
                  label: '单日任务',
                  filled: false,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.filled,
  });

  final Color color;
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: filled ? 14 : CalendarMetrics.taskDotSize,
          height: filled ? 8 : CalendarMetrics.taskDotSize,
          decoration: BoxDecoration(
            color: filled
                ? Color.alphaBlend(
                    color.withValues(alpha: 0.18),
                    AppColors.surface,
                  )
                : color,
            borderRadius: filled
                ? BorderRadius.circular(2)
                : BorderRadius.circular(CalendarMetrics.taskDotSize / 2),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: AppText.micro.copyWith(fontSize: 10)),
      ],
    );
  }
}
