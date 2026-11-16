import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../../cloud_account/state/cloud_account_controller.dart';
import '../../cloud_account/ui/cloud_widgets.dart';
import 'mobile_cloud_keys.dart';

/// 未登录：服务器地址 + 账号/邮箱 + 密码 + 登录。
///
/// 与桌面登录视图语义一致（都是调用 `controller.signIn`，由
/// `CloudAccountService.connectServer/login` 强制 HTTPS 与协议校验），但按手机
/// 触屏重新排版：单列、字段高度 ≥ 48、主按钮整宽。
///
/// 密码只存在于本 State 的 [TextEditingController] 与一次登录调用的局部变量；
/// 不写入控制器、不落盘、不进安全存储。
class MobileCloudSignInView extends StatefulWidget {
  const MobileCloudSignInView({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  State<MobileCloudSignInView> createState() => _MobileCloudSignInViewState();
}

class _MobileCloudSignInViewState extends State<MobileCloudSignInView> {
  late final TextEditingController _server;
  late final TextEditingController _account;
  late final TextEditingController _password;
  bool _obscurePassword = true;
  bool _rememberServer = true;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.controller.serverInput);
    _account = TextEditingController(text: widget.controller.accountInput);
    _password = TextEditingController();
    _rememberServer = widget.controller.rememberServer;
  }

  @override
  void didUpdateWidget(covariant MobileCloudSignInView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 控制器可能在「切换服务器」等场景回填输入；只在用户没输入时预填。
    final serverPrefill = widget.controller.serverInput;
    if (serverPrefill.isNotEmpty &&
        _server.text.isEmpty &&
        serverPrefill != oldWidget.controller.serverInput) {
      _server.text = serverPrefill;
    }
    final accountPrefill = widget.controller.accountInput;
    if (accountPrefill.isNotEmpty &&
        _account.text.isEmpty &&
        accountPrefill != oldWidget.controller.accountInput) {
      _account.text = accountPrefill;
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _looksHttpDev =>
      _server.text.trim().toLowerCase().startsWith('http://');

  Future<void> _submit() async {
    if (widget.controller.isAuthenticating) return;
    await widget.controller.signIn(
      server: _server.text,
      account: _account.text,
      password: _password.text,
      rememberServer: _rememberServer,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final authenticating = controller.isAuthenticating;
    final savedServer = controller.savedServerAddress;
    final errorMessage = controller.loginErrorMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (controller.notice != null) ...<Widget>[
          CloudBanner(
            key: MobileCloudKeys.noticeBanner,
            tone: CloudBannerTone.warning,
            title: '需要重新登录',
            message: controller.notice,
            onDismiss: controller.dismissNotice,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (errorMessage != null) ...<Widget>[
          CloudBanner(
            key: MobileCloudKeys.loginError,
            tone: CloudBannerTone.danger,
            title: controller.loginErrorTitle ?? '登录失败',
            message: errorMessage,
            hint: controller.loginErrorHint,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          children: <Widget>[
            const CloudStatusPill(
              label: '未连接',
              tone: CloudStatusTone.neutral,
              icon: Icons.cloud_off_outlined,
            ),
            const Spacer(),
            Text(
              '数据只保存在本机',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        CloudField(
          label: '服务器地址',
          caption: '正式连接必须使用 HTTPS；仅本机 localhost 调试允许 HTTP。',
          child: TextField(
            key: MobileCloudKeys.serverField,
            controller: _server,
            enabled: !authenticating,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'https://sync.example.com',
              prefixIcon: const Icon(Icons.dns_outlined, size: 18),
              suffixIcon: savedServer == null
                  ? null
                  : IconButton(
                      tooltip: '填入上次使用的服务器',
                      icon: const Icon(Icons.history_rounded, size: 18),
                      onPressed: authenticating
                          ? null
                          : () => setState(() {
                              _server.text = savedServer;
                            }),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_looksHttpDev) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          const CloudBanner(
            tone: CloudBannerTone.warning,
            title: '开发环境例外',
            message: '正在使用 HTTP 明文连接，仅限本机 localhost / 127.0.0.1 调试。',
            hint: '正式环境请改用 https:// 地址；客户端不会关闭证书校验。',
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        CloudField(
          label: '账号或邮箱',
          child: TextField(
            key: MobileCloudKeys.accountField,
            controller: _account,
            enabled: !authenticating,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'you@example.com',
              prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        CloudField(
          label: '密码',
          child: TextField(
            key: MobileCloudKeys.passwordField,
            controller: _password,
            enabled: !authenticating,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '服务器账号密码',
              prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  _obscurePassword = !_obscurePassword;
                }),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '记住服务器地址',
                style: AppText.small.copyWith(fontSize: 13),
              ),
            ),
            Switch(
              key: MobileCloudKeys.rememberServer,
              value: _rememberServer,
              onChanged: authenticating
                  ? null
                  : (value) => setState(() {
                      _rememberServer = value;
                    }),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            key: MobileCloudKeys.signInSubmit,
            onPressed: authenticating ? null : _submit,
            icon: authenticating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: AppColors.textInverse,
                    ),
                  )
                : const Icon(Icons.login_rounded, size: 18),
            label: Text(authenticating ? '正在连接…' : '登录'),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const CloudHintText(
          '使用服务器上的普通用户账号登录；请勿使用管理员账号访问客户端数据。'
          '密码只用于本次登录，不会保存在本机；登录令牌存入系统安全存储（Android Keystore）。',
        ),
      ],
    );
  }
}
