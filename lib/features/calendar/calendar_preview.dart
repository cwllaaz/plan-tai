import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/testing/testing.dart';
import '../../core/theme/theme.dart';
import 'calendar_month_view.dart';

/// 月历模块的**独立预览入口**（开发用，不参与正式打包）。
///
/// 它不经过 AppShell，只把 `CalendarMonthView` 放进一个最小外壳里，
/// 方便单独运行 / 截图 / 调交互：
///
/// ```powershell
/// flutter run -t lib/features/calendar/calendar_preview.dart -d windows
/// ```
///
/// 数据来自 `core/testing` 的内存仓储 + 演示数据，不读写磁盘。
/// 选中日 / 可见月份 / 今天全部由这个小外壳持有，和正式外壳的职责一致。
void main() {
  runApp(const CalendarPreviewApp());
}

class CalendarPreviewApp extends StatelessWidget {
  const CalendarPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '月历预览 · 计划台',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const _PreviewPage(),
    );
  }
}

class _PreviewPage extends StatefulWidget {
  const _PreviewPage();

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  final InMemoryPlannerRepository _repository = InMemoryPlannerRepository();
  late final LocalDate _today = LocalDate.today();
  late LocalDate _selectedDate = _today;
  late LocalDate _visibleMonth = _today.firstDayOfMonth;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  Future<void> _seed() async {
    await seedDemoData(_repository, today: _today);
    if (!mounted) return;
    setState(() => _ready = true);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _visibleMonth = _visibleMonth.addMonths(delta);
      if (!_selectedDate.isSameMonthAs(_visibleMonth)) {
        _selectedDate = _visibleMonth;
      }
    });
  }

  void _goToToday() {
    setState(() {
      _selectedDate = _today;
      _visibleMonth = _today.firstDayOfMonth;
    });
  }

  void _selectDate(LocalDate date) {
    setState(() {
      _selectedDate = date;
      if (!date.isSameMonthAs(_visibleMonth)) {
        _visibleMonth = date.firstDayOfMonth;
      }
    });
  }

  void _openDay(LocalDate date) {
    _selectDate(date);
    // 预览里没有每日面板，用 SnackBar 顶替，证明回调时序正确。
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('打开当日面板：${monthDayWithWeekday(date)}')),
    );
  }

  /// 预览里没有"新建跨天安排"弹窗，用 SnackBar 展示拖选结果。
  void _openRange(LocalDate start, LocalDate end) {
    final days = end.differenceInDays(start) + 1;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('拖选：${monthDay(start)} – ${monthDay(end)} · 共 $days 天'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 44,
              child: Row(
                children: <Widget>[
                  Text(monthTitle(_visibleMonth), style: AppText.h1),
                  const SizedBox(width: AppSpacing.lg),
                  OutlinedButton(
                    onPressed: () => _shiftMonth(-1),
                    child: const Text('上个月'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: _goToToday,
                    child: const Text('今天'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: () => _shiftMonth(1),
                    child: const Text('下个月'),
                  ),
                  const Spacer(),
                  Text(
                    '选中 ${monthDayWithWeekday(_selectedDate)} · 预览数据',
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: _ready
                  ? CalendarMonthView(
                      repository: _repository,
                      month: _visibleMonth,
                      today: _today,
                      selectedDate: _selectedDate,
                      onSelectDate: _selectDate,
                      onOpenDay: _openDay,
                      onRangeSelected: _openRange,
                    )
                  : const Center(child: Text('正在准备演示数据…')),
            ),
          ],
        ),
      ),
    );
  }
}
