import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../../cloud_account/cloud_account.dart';
import '../../cloud_account/ui/binding_card.dart';
import '../../cloud_account/ui/cloud_widgets.dart';
import 'mobile_account_card.dart';
import 'mobile_cloud_keys.dart';
import 'mobile_conflict_page.dart';
import 'mobile_sign_in_view.dart';
import 'mobile_sync_section.dart';

/// 打开「云端账号与同步」全屏页（手机/平板通用）。
///
/// 月历模块 在移动端导航里放一个入口调用本函数；Agent D 统一接线时保证
/// [controller] 与 `CloudScope` 里的是同一个实例（不要重复创建控制器）。
Future<void> openMobileCloudAccount(
  BuildContext context,
  CloudAccountController controller,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          MobileCloudAccountPage(controller: controller),
    ),
  );
}

/// Android 专用的账号与同步页面。
///
/// 展示要求（任务 §5）全部覆盖：当前登录账号、当前服务器、已连接/未连接、
/// 正在同步、待同步数量、上次成功同步时间、同步失败信息、立即同步按钮、
/// 自动同步开关、退出账号入口、冲突处理入口。
///
/// 页面只依赖 `CloudAccountController`（冻结契约的编排层），不直接发 HTTP、
/// 不碰 SQLite、不读写安全存储。
class MobileCloudAccountPage extends StatefulWidget {
  const MobileCloudAccountPage({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  State<MobileCloudAccountPage> createState() => _MobileCloudAccountPageState();
}

class _MobileCloudAccountPageState extends State<MobileCloudAccountPage> {
  @override
  void initState() {
    super.initState();
    // 打开页面时主动刷新一次数据归属/记录数（与桌面面板一致的语义）。
    // 必须放到首帧之后：openPanel 会同步 notifyListeners，在 build 期间通知
    // 其它监听者（例如顶栏入口按钮）会触发 setState-during-build。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.openPanel();
    });
  }

  @override
  void dispose() {
    // 不在这里调用 closePanel：页面退出时的同步 notify 可能落在其它控件的
    // build/dispose 阶段。面板开关状态只影响桌面抽屉，Android 页面不使用它。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: MobileCloudKeys.page,
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('云端账号与同步', style: AppText.h2.copyWith(fontSize: 16)),
        actions: <Widget>[
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: AppColors.border),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (BuildContext context, Widget? _) => _body(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final controller = widget.controller;
    final signedIn = controller.isSignedIn;
    final showBindingCard =
        controller.bindingStage != CloudBindingStage.ready &&
        controller.bindingStage != CloudBindingStage.idle;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xxxl,
      ),
      children: <Widget>[
        if (controller.banner != null) ...<Widget>[
          CloudBanner(
            key: MobileCloudKeys.actionBanner,
            tone: controller.bannerIsError
                ? CloudBannerTone.danger
                : CloudBannerTone.success,
            title: controller.bannerIsError ? '操作未完成' : '操作完成',
            message: controller.banner,
            onDismiss: controller.dismissBanner,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (!signedIn)
          MobileCloudSignInView(controller: controller)
        else ...<Widget>[
          if (showBindingCard) ...<Widget>[
            CloudBindingCard(controller: controller),
            const SizedBox(height: AppSpacing.md),
          ],
          MobileAccountCard(controller: controller),
          const SizedBox(height: AppSpacing.md),
          MobileSyncSection(
            controller: controller,
            onOpenConflicts: () => unawaited(
              openMobileCloudConflicts(context, controller),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          const CloudHintText(
            'Android 首版只在应用前台自动同步：打开应用、回到前台、保存改动后'
            '会自动尝试；应用被彻底关闭后不会实时同步，下次打开会把待同步的操作补传。',
          ),
        ],
      ],
    );
  }
}
