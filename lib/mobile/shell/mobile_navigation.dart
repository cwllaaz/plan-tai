import 'package:material_ui/material_ui.dart';

import '../../core/theme/theme.dart';
import '../theme/mobile_metrics.dart';

/// 移动端底部导航的四个分区。
///
/// 与 `docs/android/UI_SPEC.md` 的差异：工单要求「今日」作为独立入口（不是桌面侧的
/// 「任务/已完成」分组），因此四个分区固定为 日历 / 今日 / 项目 / 我的。
enum MobileTab {
  calendar('日历', Icons.calendar_month_outlined, Icons.calendar_month_rounded),
  today('今日', Icons.today_outlined, Icons.today_rounded),
  projects('项目', Icons.folder_outlined, Icons.folder_rounded),
  me('我的', Icons.person_outline_rounded, Icons.person_rounded);

  const MobileTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 手机底部导航（56dp + 系统安全区）。
class MobileBottomNav extends StatelessWidget {
  const MobileBottomNav({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final MobileTab current;
  final ValueChanged<MobileTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MobileMetrics.bottomNavHeight,
          child: Row(
            children: <Widget>[
              for (final tab in MobileTab.values)
                Expanded(
                  child: _BottomNavItem(
                    tab: tab,
                    selected: tab == current,
                    onTap: () => onSelect(tab),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final MobileTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textTertiary;
    return Semantics(
      label: tab.label,
      selected: selected,
      button: true,
      child: InkWell(
        key: ValueKey<String>('mobile-tab-${tab.name}'),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 22,
              color: color,
            ),
            const SizedBox(height: 2),
            Text(
              tab.label,
              style: AppText.micro.copyWith(
                fontSize: 10.5,
                height: 1.1,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 平板左侧导航栏（84dp，图标 + 文字）。
class MobileNavRail extends StatelessWidget {
  const MobileNavRail({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final MobileTab current;
  final ValueChanged<MobileTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MobileMetrics.navRailWidth,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: <Widget>[
            const SizedBox(height: AppSpacing.md),
            for (final tab in MobileTab.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _RailItem(
                  tab: tab,
                  selected: tab == current,
                  onTap: () => onSelect(tab),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final MobileTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textTertiary;
    return InkWell(
      key: ValueKey<String>('mobile-rail-${tab.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        width: 68,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          children: <Widget>[
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 22,
              color: color,
            ),
            const SizedBox(height: 3),
            Text(
              tab.label,
              style: AppText.micro.copyWith(
                fontSize: 10.5,
                height: 1.1,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
