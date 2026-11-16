import 'package:flutter/widgets.dart';

import '../core/contracts/contracts.dart';
import 'shell_state.dart';

/// 应用作用域：把仓储与 UI 状态注入整棵树。
///
/// 依赖 [InheritedNotifier]，[PlannerShellState] 变化时只重建依赖它的 widget。
/// 业务数据不走这里，各模块自行订阅仓储流。
class AppScope extends InheritedNotifier<PlannerShellState> {
  const AppScope({
    super.key,
    required this.repository,
    required PlannerShellState shell,
    required super.child,
  }) : super(notifier: shell);

  final PlannerRepository repository;

  PlannerShellState get shell => notifier!;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, '找不到 AppScope，PlannerApp 之外不能直接使用');
    return scope!;
  }

  @override
  bool updateShouldNotify(covariant AppScope oldWidget) =>
      super.updateShouldNotify(oldWidget) || repository != oldWidget.repository;
}
