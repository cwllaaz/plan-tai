import 'package:flutter/foundation.dart';

import '../core/models/models.dart';

/// 左侧导航对应的主区域。
enum AppSection { calendar, projects, tasks, completed, archive }

/// 应用级 UI 状态：当前可见月份、选中日期、右侧抽屉开关、左侧导航区域。
///
/// 只放**跨模块共享**的界面状态，不放业务数据（业务数据一律走
/// [PlannerRepository] 的流）。日历与每日面板都通过它协调"选中哪天 / 打开哪天"。
class PlannerShellState extends ChangeNotifier {
  PlannerShellState({LocalDate? today, LocalDate? initialSelectedDate})
    : _todayOverride = today,
      _today = today ?? LocalDate.today(),
      _selectedDate = initialSelectedDate ?? today ?? LocalDate.today(),
      _visibleMonth =
          (initialSelectedDate ?? today ?? LocalDate.today()).firstDayOfMonth;

  /// 测试注入的"今天"；为 null 时跟随系统时钟。生产环境不传。
  final LocalDate? _todayOverride;

  LocalDate _today;
  LocalDate _selectedDate;
  LocalDate _visibleMonth;
  bool _drawerOpen = false;

  /// 右侧面板当前"停在"哪一天（双击收起时用来判断是不是同一天）。
  LocalDate? _drawerDate;

  AppSection _section = AppSection.calendar;
  String? _focusedProjectId;

  LocalDate get today => _today;

  AppSection get section => _section;

  /// 项目管理页当前聚焦的项目；由侧栏项目条目或项目页自身设置。
  String? get focusedProjectId => _focusedProjectId;

  LocalDate get selectedDate => _selectedDate;

  /// 始终是某个月的 1 号。
  LocalDate get visibleMonth => _visibleMonth;

  bool get isDrawerOpen => _drawerOpen;

  /// 单击某天：只改选中，不改变抽屉状态。
  void selectDate(LocalDate date) {
    if (_selectedDate == date) return;
    _selectedDate = date;
    if (!date.isSameMonthAs(_visibleMonth)) {
      _visibleMonth = date.firstDayOfMonth;
    }
    notifyListeners();
  }

  /// 双击某天：选中并展开右侧抽屉。
  void openDay(LocalDate date) {
    final changed = _selectedDate != date || !_drawerOpen;
    _selectedDate = date;
    _drawerDate = date;
    if (!date.isSameMonthAs(_visibleMonth)) {
      _visibleMonth = date.firstDayOfMonth;
    }
    _drawerOpen = true;
    if (changed) notifyListeners();
  }

  /// 双击某天：没开就展开；右侧面板正停在同一天时，再双击就收起。
  ///
  /// 这里比较的是"面板当前停在哪天"（[_drawerDate]），而不是 [_selectedDate]：
  /// 双击的第一下会先把选中日改掉，如果用 selectedDate 判断，双击另一天会被误当成
  /// "同一天"而把刚打开的面板关掉。
  void toggleDay(LocalDate date) {
    if (_drawerOpen && _drawerDate == date) {
      closeDrawer();
      return;
    }
    openDay(date);
  }

  void closeDrawer() {
    if (!_drawerOpen) return;
    _drawerOpen = false;
    notifyListeners();
  }

  void toggleDrawer() {
    _drawerOpen = !_drawerOpen;
    notifyListeners();
  }

  /// 抽屉内前后翻一天；抽屉保持展开。
  void shiftDay(int delta) {
    _selectedDate = _selectedDate.addDays(delta);
    _drawerDate = _selectedDate;
    if (!_selectedDate.isSameMonthAs(_visibleMonth)) {
      _visibleMonth = _selectedDate.firstDayOfMonth;
    }
    notifyListeners();
  }

  void shiftMonth(int delta) {
    _visibleMonth = _visibleMonth.addMonths(delta);
    // 翻月时把选中日期收到可见月份内，避免选中态停留在别的月份。
    if (!_selectedDate.isSameMonthAs(_visibleMonth)) {
      _selectedDate = _visibleMonth;
    }
    notifyListeners();
  }

  void showMonthOf(LocalDate date) {
    final month = date.firstDayOfMonth;
    if (month == _visibleMonth) return;
    _visibleMonth = month;
    notifyListeners();
  }

  /// 回到今天：刷新"今天"的缓存值，选中今天并定位到本月。
  void goToToday() {
    _today = _todayOverride ?? LocalDate.today();
    _selectedDate = _today;
    _visibleMonth = _today.firstDayOfMonth;
    notifyListeners();
  }

  /// 切换左侧导航区域；切到非日历页时收起抽屉，避免两套内容互相挤压。
  void showSection(AppSection section) {
    if (_section == section) {
      if (section != AppSection.calendar && _drawerOpen) {
        _drawerOpen = false;
        notifyListeners();
      }
      return;
    }
    _section = section;
    if (section != AppSection.calendar) _drawerOpen = false;
    notifyListeners();
  }

  /// 在项目页聚焦某个项目。
  void focusProject(String? projectId) {
    if (_focusedProjectId == projectId) return;
    _focusedProjectId = projectId;
    notifyListeners();
  }

  /// 从侧栏/任务列表打开项目页并聚焦该项目。
  void openProject(String projectId) {
    _section = AppSection.projects;
    _focusedProjectId = projectId;
    _drawerOpen = false;
    notifyListeners();
  }
}
