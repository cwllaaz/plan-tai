import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'day_detail_math.dart';

/// 面板头部：日期卡、前后一天/关闭、完成率进度条、当天跨天阶段胶囊。
class DayDetailHeader extends StatelessWidget {
  const DayDetailHeader({
    super.key,
    required this.date,
    required this.today,
    required this.stats,
    required this.spans,
    required this.projects,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final LocalDate date;
  final LocalDate today;
  final DayTaskStats stats;
  final List<PlanSpan> spans;
  final List<Project> projects;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final isToday = date == today;
    final diff = date.differenceInDays(today);
    // 头部已有「11月22日 周日」，副标题只补「今天/明天/昨天」这类相对信息，
    // 更远的日期只留周数，避免同一行日期重复两遍。
    final relative = switch (diff) {
      0 => ' · 今天',
      1 => ' · 明天',
      -1 => ' · 昨天',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md + AppSpacing.xxs,
        AppSpacing.sm + AppSpacing.xxs,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              _DateBadge(date: date, isToday: isToday),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            monthDayWithWeekday(date),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyStrong.copyWith(fontSize: 15),
                          ),
                        ),
                        if (isToday) ...<Widget>[
                          const SizedBox(width: AppSpacing.xs + 2),
                          const _TodayBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${weekNumberLabel(date)}$relative',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              _HeaderIconButton(
                icon: Icons.chevron_left_rounded,
                tooltip: '前一天',
                onTap: onPrevious,
              ),
              _HeaderIconButton(
                icon: Icons.chevron_right_rounded,
                tooltip: '后一天',
                onTap: onNext,
              ),
              const SizedBox(width: AppSpacing.xxs),
              _HeaderIconButton(
                icon: Icons.close_rounded,
                tooltip: '关闭（Esc）',
                onTap: onClose,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Text(
                stats.countLabel,
                style: AppText.numeric.copyWith(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${stats.percent}%',
                style: AppText.numeric.copyWith(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: stats.allDone ? AppColors.success : AppColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _ProgressBar(ratio: stats.ratio, complete: stats.allDone),
          if (spans.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text(
                  '阶段',
                  style: AppText.micro.copyWith(
                    fontSize: 10.5,
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs + 2),
                Expanded(
                  child: _SpanChips(spans: spans, projects: projects),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 头部日期卡：今天用 accent 实底，其余用 surfaceSunken。
class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.date, required this.isToday});

  final LocalDate date;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday ? AppColors.accent : AppColors.surfaceSunken,
        borderRadius: AppRadius.card,
        border: isToday ? null : Border.all(color: AppColors.border),
      ),
      child: Text(
        dayNumber(date),
        style: AppText.numericLarge.copyWith(
          fontSize: 20,
          color: isToday ? AppColors.textInverse : AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _TodayBadge extends StatelessWidget {
  const _TodayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '今天',
        style: AppText.micro.copyWith(fontSize: 10, color: AppColors.accent),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: AppRadius.control,
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 18, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// 4px 完成率进度条；全部完成时换成 success 色。
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.ratio, required this.complete});

  final double ratio;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final safe = ratio.isNaN ? 0.0 : ratio.clamp(0.0, 1.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: <Widget>[
            const Positioned.fill(child: ColoredBox(color: AppColors.border)),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: safe),
              duration: AppMotion.drawer,
              curve: AppMotion.curve,
              builder: (BuildContext context, double value, Widget? child) {
                return FractionallySizedBox(
                  widthFactor: value,
                  heightFactor: 1,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(
                    color: complete ? AppColors.success : AppColors.accent,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 当天覆盖的跨天阶段（只展示，不编辑，见 docs/MODULE_API.md §3.4）。
class _SpanChips extends StatelessWidget {
  const _SpanChips({required this.spans, required this.projects});

  final List<PlanSpan> spans;
  final List<Project> projects;

  @override
  Widget build(BuildContext context) {
    const visibleLimit = 3;
    final visible = spans.take(visibleLimit).toList(growable: false);
    final hidden = spans.length - visible.length;
    return SizedBox(
      height: 22,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          for (final span in visible) ...<Widget>[
            _SpanChip(span: span, color: _colorOf(span)),
            const SizedBox(width: AppSpacing.xs + 2),
          ],
          if (hidden > 0)
            Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '+$hidden 条安排',
                style: AppText.micro.copyWith(fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  Color _colorOf(PlanSpan span) {
    final explicit = span.color;
    if (explicit != null) return explicit.uiColor;
    for (final project in projects) {
      if (project.id == span.projectId) return project.color.uiColor;
    }
    return AppColors.accent;
  }
}

class _SpanChip extends StatelessWidget {
  const _SpanChip({required this.span, required this.color});

  final PlanSpan span;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          '${span.title}\n${monthDay(span.startDate)}–${monthDay(span.endDate)}'
          ' · ${span.lengthInDays} 天',
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.xs + 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                span.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.micro.copyWith(
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
