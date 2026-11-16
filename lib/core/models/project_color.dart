import 'planner_exception.dart';

/// 项目颜色，统一存 `#RRGGBB`（不透明）。
///
/// 数据层与同步层只认这个格式；不做命名色、不存 ARGB。
/// 调色板取自 docs/01 §2.8，8 色同明度、低饱和，并排不刺眼。
final class ProjectColor {
  const ProjectColor._(this.rgb);

  factory ProjectColor.fromHex(String hex) {
    final normalized = hex.trim().toUpperCase();
    if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalized)) {
      throw PlannerValidationException('颜色必须是 #RRGGBB 格式：$hex');
    }
    return ProjectColor._(int.parse(normalized.substring(1), radix: 16));
  }

  factory ProjectColor.fromRgb(int rgb) {
    if (rgb < 0 || rgb > 0xFFFFFF) {
      throw PlannerValidationException('颜色超出 #RRGGBB 范围：$rgb');
    }
    return ProjectColor._(rgb);
  }

  /// 24 位 RGB（不含 alpha）。
  final int rgb;

  String get hex => '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static const ProjectColor blue = ProjectColor._(0x3E63DD);
  static const ProjectColor teal = ProjectColor._(0x12A594);
  static const ProjectColor green = ProjectColor._(0x30A46C);
  static const ProjectColor amber = ProjectColor._(0xF5A524);
  static const ProjectColor red = ProjectColor._(0xE5484D);
  static const ProjectColor purple = ProjectColor._(0x8E4EC6);
  static const ProjectColor sky = ProjectColor._(0x0D8BD1);
  static const ProjectColor magenta = ProjectColor._(0xD6409F);

  /// 新建项目时的默认色板（顺序即默认优先级）。
  static const List<ProjectColor> palette = <ProjectColor>[
    blue,
    teal,
    green,
    amber,
    red,
    purple,
    sky,
    magenta,
  ];

  static ProjectColor get defaultColor => palette.first;

  /// 根据已有项目数量挑一个尚未使用的颜色（用完则回环）。
  static ProjectColor suggestFor(int existingProjectCount) =>
      palette[existingProjectCount % palette.length];

  @override
  bool operator ==(Object other) => other is ProjectColor && rgb == other.rgb;

  @override
  int get hashCode => rgb.hashCode;

  @override
  String toString() => hex;
}
