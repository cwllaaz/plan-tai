import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import 'cloud_account_panel.dart';

/// 右侧抽屉式的云账号浮层。
///
/// 用法（Agent D 在 `app_shell.dart` 里接入）：
/// ```dart
/// Stack(
///   children: <Widget>[
///     existingShell,
///     CloudAccountOverlay(controller: cloudController),
///   ],
/// )
/// ```
///
/// - 不改变月历布局：面板浮在右侧，宽度 420，左缘 1px 边框；
/// - 关闭方式：右上角 ×、点击面板外、Esc；
/// - 面板关闭时返回零尺寸，不拦截任何点击。
class CloudAccountOverlay extends StatelessWidget {
  const CloudAccountOverlay({
    super.key,
    required this.controller,
    this.width = AppSizes.drawerWidth,
  });

  final CloudAccountController controller;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        if (!controller.isPanelOpen) return const SizedBox.shrink();
        return SizedBox.expand(
          // 面板里有 TextField / InkWell：浮层要自带 Material 祖先，
          // 否则嵌在 AppShell 之外的 Stack 里会报 "No Material widget found"。
          child: Material(
            type: MaterialType.transparency,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.escape):
                    controller.closePanel,
              },
              child: Focus(
                autofocus: true,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: controller.closePanel,
                        child: const ColoredBox(color: Colors.transparent),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 1, end: 0),
                        duration: AppMotion.drawer,
                        curve: AppMotion.curve,
                        builder:
                            (
                              BuildContext context,
                              double value,
                              Widget? child,
                            ) {
                              return Opacity(
                                opacity: 1 - value * 0.35,
                                child: Transform.translate(
                                  offset: Offset(value * 32, 0),
                                  child: child,
                                ),
                              );
                            },
                        child: ClipRect(
                          child: CloudAccountPanel(
                            controller: controller,
                            width: width,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
