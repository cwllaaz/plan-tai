import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:material_ui/material_ui.dart';

import '../../core/format/format.dart';
import '../../core/models/models.dart';
import '../../core/theme/theme.dart';
import 'calendar_style.dart';
import 'month_layout.dart';

/// 一条跨天阶段的**周内片段**。
///
/// 视觉规则（同 UI_SPEC §5）：
/// - 实心低饱和填充 + 左侧 3px 项目色竖条；
/// - 只有真实起点带左圆角、真实终点带右圆角；跨周/跨月的两端是直角并紧贴格子边界，
///   与相邻周的片段拼成一条连续的横条；
/// - 直角端用小箭头提示"还会继续"；
/// - 文字用压深的项目色（与浅底对比度 ≥ 4.5:1），超长省略，不换行。
class SpanBar extends StatefulWidget {
  const SpanBar({
    super.key,
    required this.segment,
    required this.color,
    required this.projectName,
    required this.onTap,
    this.onOpen,
  });

  final SpanSegment segment;
  final ProjectColor color;

  /// 用于 tooltip / 无障碍文案；项目已删除时可为空串。
  final String projectName;

  /// 单击：交给上层"选中阶段起始日"。
  final VoidCallback onTap;

  /// 双击：交给上层编辑 / 归类该阶段；为空时双击无动作。
  final VoidCallback? onOpen;

  @override
  State<SpanBar> createState() => _SpanBarState();
}

class _SpanBarState extends State<SpanBar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final color = widget.color;
    final ink = CalendarPalette.spanInk(color);
    final fill = _hovered
        ? CalendarPalette.spanFillHover(color)
        : CalendarPalette.spanFill(color);

    final radius = BorderRadius.only(
      topLeft: Radius.circular(
        segment.beginsHere ? CalendarMetrics.spanRadius : 0,
      ),
      bottomLeft: Radius.circular(
        segment.beginsHere ? CalendarMetrics.spanRadius : 0,
      ),
      topRight: Radius.circular(
        segment.endsHere ? CalendarMetrics.spanRadius : 0,
      ),
      bottomRight: Radius.circular(
        segment.endsHere ? CalendarMetrics.spanRadius : 0,
      ),
    );

    return Tooltip(
      message: _tooltip(segment, widget.projectName),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        // 单击用 Listener 在按下时立刻响应（注册 onDoubleTap 后 onTap 会等 300ms），
        // 双击交给 GestureDetector，用于打开编辑弹窗。
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if ((event.buttons & kPrimaryButton) != 0) widget.onTap();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onOpen,
            child: Semantics(
              button: true,
              label: _semanticsLabel(segment, widget.projectName),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 56;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: radius,
                      border: Border.all(
                        color: Color.alphaBlend(
                          color.uiColor.withValues(alpha: 0.18),
                          AppColors.surface,
                        ),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: Row(
                        children: <Widget>[
                          if (segment.beginsHere)
                            SizedBox(
                              width: CalendarMetrics.spanStripeWidth,
                              height: double.infinity,
                              child: ColoredBox(
                                color: CalendarPalette.spanStripe(color),
                              ),
                            ),
                          if (segment.continuesBefore && !compact)
                            _ContinuationCue(forward: false, color: ink),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              segment.span.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1.1,
                                fontWeight: FontWeight.w500,
                                color: ink,
                                fontFamilyFallback: AppText.fontFamilyFallback,
                              ),
                            ),
                          ),
                          if (segment.continuesAfter && !compact)
                            _ContinuationCue(forward: true, color: ink),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _tooltip(SpanSegment segment, String projectName) {
    final span = segment.span;
    final parts = <String>[
      if (projectName.isNotEmpty) projectName,
      '${monthDay(span.startDate)}–${monthDay(span.endDate)} · ${span.lengthInDays} 天',
      span.status.label,
    ];
    return '阶段：${span.title}\n${parts.join('｜')}';
  }

  static String _semanticsLabel(SpanSegment segment, String projectName) {
    final span = segment.span;
    return '跨天安排 ${span.title}，${projectName.isEmpty ? '未归属项目' : projectName}，'
        '${monthDay(span.startDate)} 到 ${monthDay(span.endDate)}，${span.status.label}';
  }
}

/// 跨周/跨月片段边缘的"还会继续"小箭头。
///
/// 自己画而不是用 [Icons.chevron_left_rounded] —— 外壳的翻月按钮用的是同一个图标，
/// 复用会让 `find.byIcon` 之类的自动化测试变得二义。
class _ContinuationCue extends StatelessWidget {
  const _ContinuationCue({required this.forward, required this.color});

  final bool forward;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: forward ? 2 : 0, right: forward ? 0 : 2),
      child: CustomPaint(
        size: const Size(6, 9),
        painter: _ChevronPainter(forward: forward, color: color),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter({required this.forward, required this.color});

  final bool forward;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    if (forward) {
      path
        ..moveTo(1, 1)
        ..lineTo(size.width - 1, size.height / 2)
        ..lineTo(1, size.height - 1);
    } else {
      path
        ..moveTo(size.width - 1, 1)
        ..lineTo(1, size.height / 2)
        ..lineTo(size.width - 1, size.height - 1);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) =>
      oldDelegate.forward != forward || oldDelegate.color != color;
}
