import 'package:flutter/widgets.dart';

import '../features/cloud_account/cloud_account.dart';

/// 云账号作用域：注入 [CloudServices] 与 [CloudAccountController]。
///
/// 与 `AppScope` 分离，保证离线版（演示模式）完全不构造云依赖：
/// 只有 `main` 在正式模式下创建 CloudScope，其他 widget 用
/// [maybeOf] 读取，拿不到就退化为 V1 的离线行为。
class CloudScope extends InheritedNotifier<CloudAccountController> {
  const CloudScope({
    super.key,
    required this.services,
    required CloudAccountController controller,
    required super.child,
  }) : super(notifier: controller);

  final CloudServices services;

  static CloudScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CloudScope>();

  static CloudAccountController? controllerOf(BuildContext context) =>
      maybeOf(context)?.notifier;
}
