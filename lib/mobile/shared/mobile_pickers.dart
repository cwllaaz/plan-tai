import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import '../theme/mobile_metrics.dart';
import 'mobile_sheets.dart';
import 'mobile_widgets.dart';

/// 项目选择的返回值：`projectId == null` 表示「未归项目」，整个 Future 为 null 表示取消。
final class MobileProjectChoice {
  const MobileProjectChoice(this.projectId);

  final String? projectId;
}

/// 跨天安排颜色的返回值：`color == null` 表示跟随项目颜色。
final class MobileSpanColorChoice {
  const MobileSpanColorChoice.followProject() : color = null;

  const MobileSpanColorChoice.color(this.color);

  final ProjectColor? color;

  bool get followsProject => color == null;
}

/// 通用单选底部面板：列表项 ≥56dp，选中项打勾。
Future<T?> showMobileChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<T> items,
  required T? selected,
  required String Function(T item) labelOf,
  String Function(T item)? subtitleOf,
  Widget Function(T item)? leadingOf,
  String? footerHint,
}) {
  return showMobileSheet<T>(
    context,
    heightFactor: 0.72,
    builder: (BuildContext sheetContext) {
      return Column(
        children: <Widget>[
          MobileSheetHeader(
            title: title,
            subtitle: subtitle,
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              itemCount: items.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const Divider(height: 1, indent: AppSpacing.lg),
              itemBuilder: (BuildContext context, int index) {
                final item = items[index];
                final isSelected = item == selected;
                return InkWell(
                  onTap: () => Navigator.of(sheetContext).pop(item),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: MobileMetrics.listRowMinHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.sm,
                      ),
                      child: Row(
                        children: <Widget>[
                          if (leadingOf != null) ...<Widget>[
                            leadingOf(item),
                            const SizedBox(width: AppSpacing.md),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  labelOf(item),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.bodyStrong.copyWith(
                                    fontSize: 14,
                                    color: isSelected
                                        ? AppColors.accent
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                if (subtitleOf != null)
                                  Text(
                                    subtitleOf(item),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.caption.copyWith(
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isSelected)
                            const Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: AppColors.accent,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (footerHint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Text(footerHint, style: AppText.caption),
            ),
        ],
      );
    },
  );
}

/// 选择项目；返回 null = 取消，`projectId == null` = 未归项目。
Future<MobileProjectChoice?> pickMobileProject(
  BuildContext context, {
  required List<Project> projects,
  required String? selectedId,
}) async {
  final items = <String>['', for (final project in projects) project.id];
  final picked = await showMobileChoiceSheet<String>(
    context,
    title: '选择项目',
    subtitle: '任务会按项目颜色标记在月历上',
    items: items,
    selected: selectedId ?? '',
    labelOf: (String id) => id.isEmpty ? '未归项目' : _projectName(projects, id),
    leadingOf: (String id) => ProjectColorDot(
      color: id.isEmpty ? null : _projectColor(projects, id),
      size: 12,
    ),
  );
  if (picked == null) return null;
  return MobileProjectChoice(picked.isEmpty ? null : picked);
}

String _projectName(List<Project> projects, String id) {
  for (final project in projects) {
    if (project.id == id) return project.name;
  }
  return '未归项目';
}

ProjectColor? _projectColor(List<Project> projects, String id) {
  for (final project in projects) {
    if (project.id == id) return project.color;
  }
  return null;
}

/// 选择优先级。
Future<TaskPriority?> pickMobilePriority(
  BuildContext context, {
  required TaskPriority selected,
}) {
  return showMobileChoiceSheet<TaskPriority>(
    context,
    title: '优先级',
    items: TaskPriority.values,
    selected: selected,
    labelOf: (TaskPriority priority) => priority.label,
    leadingOf: (TaskPriority priority) =>
        PriorityBadge(priority: priority, compact: false),
  );
}

/// 选择项目颜色（8 色固定调色板）。
Future<ProjectColor?> pickMobileProjectColor(
  BuildContext context, {
  required ProjectColor selected,
}) {
  return showMobileChoiceSheet<ProjectColor>(
    context,
    title: '项目颜色',
    subtitle: '低饱和色板，月历与列表共用同一颜色',
    items: ProjectColor.palette,
    selected: selected,
    labelOf: _colorLabel,
    leadingOf: (ProjectColor color) => Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(color: color.uiColor, shape: BoxShape.circle),
    ),
  );
}

String _colorLabel(ProjectColor color) {
  const names = <String, String>{
    '#3E63DD': '雾紫蓝',
    '#12A594': '青绿',
    '#30A46C': '绿',
    '#F5A524': '琥珀',
    '#E5484D': '红',
    '#8E4EC6': '紫',
    '#0D8BD1': '天蓝',
    '#D6409F': '品红',
  };
  return names[color.hex] ?? color.hex;
}

/// 选择跨天安排颜色（含「跟随项目」）。
Future<MobileSpanColorChoice?> pickMobileSpanColor(
  BuildContext context, {
  required ProjectColor? selected,
}) async {
  final items = <String>[
    '',
    for (final color in ProjectColor.palette) color.hex,
  ];
  final picked = await showMobileChoiceSheet<String>(
    context,
    title: '安排颜色',
    items: items,
    selected: selected?.hex ?? '',
    labelOf: (String hex) =>
        hex.isEmpty ? '跟随项目颜色' : _colorLabel(ProjectColor.fromHex(hex)),
    leadingOf: (String hex) => hex.isEmpty
        ? const Icon(
            Icons.palette_outlined,
            size: 18,
            color: AppColors.textTertiary,
          )
        : Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: ProjectColor.fromHex(hex).uiColor,
              shape: BoxShape.circle,
            ),
          ),
  );
  if (picked == null) return null;
  if (picked.isEmpty) return const MobileSpanColorChoice.followProject();
  return MobileSpanColorChoice.color(ProjectColor.fromHex(picked));
}

/// 选择安排状态。
Future<PlanSpanStatus?> pickMobileSpanStatus(
  BuildContext context, {
  required PlanSpanStatus selected,
}) {
  return showMobileChoiceSheet<PlanSpanStatus>(
    context,
    title: '安排状态',
    items: PlanSpanStatus.values,
    selected: selected,
    labelOf: (PlanSpanStatus status) => status.label,
  );
}

/// 选择日期（移动端日期选择器，中文文案）。
Future<LocalDate?> pickMobileDate(
  BuildContext context, {
  required LocalDate initial,
  String helpText = '选择日期',
}) async {
  final picked = await showDatePicker(
    context: context,
    initialDate: initial.startOfDay,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
    helpText: helpText,
    cancelText: '取消',
    confirmText: '确定',
    initialEntryMode: DatePickerEntryMode.calendarOnly,
  );
  if (picked == null) return null;
  return LocalDate.fromDateTime(picked);
}

/// 表单里的「标签 + 当前值 + ›」行（触摸目标 56dp 起）。
class MobileFormField extends StatelessWidget {
  const MobileFormField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.icon,
    this.placeholder = false,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final IconData? icon;
  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: MobileMetrics.listRowMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: AppColors.textTertiary),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      style: AppText.caption.copyWith(
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong.copyWith(
                        fontSize: 14,
                        color: placeholder
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 日期/时间的可点击值块，用于新建任务表单的日期与时间。
class MobileValueChip extends StatelessWidget {
  const MobileValueChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.active = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: active ? AppColors.accentSoft : AppColors.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: active ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(
                icon,
                size: 16,
                color: active ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.xs + 2),
            ],
            Text(
              label,
              style: AppText.bodyStrong.copyWith(
                fontSize: 13.5,
                color: active ? AppColors.accent : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 表单提示文案（例如"未排具体时间"）。
class MobileFieldHint extends StatelessWidget {
  const MobileFieldHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(
          Icons.info_outline_rounded,
          size: 14,
          color: AppColors.textTertiary,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: AppText.micro.copyWith(fontSize: 11.5, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// 时间编辑：`09:00 – 10:00` 两个可点时间块。
class MobileTimeRangeField extends StatelessWidget {
  const MobileTimeRangeField({
    super.key,
    required this.startLabel,
    required this.endLabel,
    required this.onPickStart,
    required this.onPickEnd,
  });

  final String startLabel;
  final String endLabel;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: MobileValueChip(
            label: startLabel,
            icon: Icons.schedule_rounded,
            onTap: onPickStart,
            active: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Text(
            '–',
            style: AppText.body.copyWith(color: AppColors.textTertiary),
          ),
        ),
        Expanded(
          child: MobileValueChip(
            label: endLabel,
            icon: Icons.schedule_rounded,
            onTap: onPickEnd,
            active: true,
          ),
        ),
      ],
    );
  }
}

/// 日期显示：`11 月 15 日 · 周六`。
String mobileDayLabel(LocalDate date, LocalDate today) {
  if (date == today) return '今天 · ${monthDayWithWeekday(date)}';
  return monthDayWithWeekday(date);
}
