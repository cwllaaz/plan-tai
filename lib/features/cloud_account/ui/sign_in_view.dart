import 'package:material_ui/material_ui.dart';

import '../../../core/theme/theme.dart';
import '../state/cloud_account_controller.dart';
import 'cloud_widgets.dart';

/// 未登录状态：服务器地址 + 账号 + 密码 + 连接并登录。
///
/// 密码只存在于本 State 的 [TextEditingController]，提交后也不进
/// [CloudAccountController]；界面重建不会把密码重新填回去。
class CloudSignInView extends StatefulWidget {
  const CloudSignInView({super.key, required this.controller});

  final CloudAccountController controller;

  @override
  State<CloudSignInView> createState() => _CloudSignInViewState();
}

class _CloudSignInViewState extends State<CloudSignInView> {
  late final TextEditingController _server;
  late final TextEditingController _account;
  late final TextEditingController _password;
  bool _obscurePassword = true;
  bool _rememberServer = true;
  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.controller.serverInput)
      ..addListener(_onServerTextChanged);
    _account = TextEditingController(text: widget.controller.accountInput);
    _password = TextEditingController();
    _rememberServer = widget.controller.rememberServer;
  }

  @override
  void didUpdateWidget(covariant CloudSignInView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prefill = widget.controller.serverInput;
    if (prefill.isNotEmpty &&
        _server.text.isEmpty &&
        prefill != oldWidget.controller.serverInput) {
      _server.text = prefill;
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
    _server
      ..removeListener(_onServerTextChanged)
      ..dispose();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onServerTextChanged() {
    // 只为了在输入 http:// 时立刻出现"开发环境"提示，不影响输入焦点。
    setState(() {});
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (controller.notice != null) ...<Widget>[
          CloudBanner(
            tone: CloudBannerTone.warning,
            title: '需要重新登录',
            message: controller.notice,
            onDismiss: controller.dismissNotice,
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
        const SizedBox(height: AppSpacing.md),
        CloudField(
          label: '服务器地址',
          caption: '正式连接必须使用 HTTPS；本机 localhost 调试可用 HTTP。',
          child: TextField(
            key: const ValueKey<String>('cloud-server-field'),
            controller: _server,
            enabled: !authenticating,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'https://sync.example.com',
              prefixIcon: Icon(Icons.dns_outlined, size: 16),
              prefixIconConstraints: BoxConstraints(minWidth: 34),
            ),
          ),
        ),
        if (_looksHttpDev) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          const CloudBanner(
            tone: CloudBannerTone.warning,
            title: '开发环境例外',
            message: '正在使用 HTTP 明文连接，仅限本机 localhost / 127.0.0.1 调试。',
            hint: '正式环境请改用 https:// 地址，避免账号密码在网络上明文传输。',
          ),
        ],
        const SizedBox(height: AppSpacing.md + AppSpacing.xxs),
        CloudField(
          label: '账号或邮箱',
          child: TextField(
            key: const ValueKey<String>('cloud-account-field'),
            controller: _account,
            enabled: !authenticating,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'name@example.com',
              prefixIcon: Icon(Icons.person_outline_rounded, size: 16),
              prefixIconConstraints: BoxConstraints(minWidth: 34),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md + AppSpacing.xxs),
        CloudField(
          label: '密码',
          caption: '密码只用于本次登录，不会保存在本机。',
          child: TextField(
            key: const ValueKey<String>('cloud-password-field'),
            controller: _password,
            enabled: !authenticating,
            obscureText: _obscurePassword,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '输入云端账号密码',
              prefixIcon: const Icon(Icons.lock_outline_rounded, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              suffixIcon: IconButton(
                key: const ValueKey<String>('cloud-password-toggle'),
                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                iconSize: 16,
                onPressed: () {
                  setState(() => _obscurePassword = !_obscurePassword);
                },
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        InkWell(
          borderRadius: AppRadius.control,
          onTap: () {
            setState(() => _rememberServer = !_rememberServer);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            child: Row(
              children: <Widget>[
                Checkbox(
                  key: const ValueKey<String>('cloud-remember-server'),
                  value: _rememberServer,
                  onChanged: authenticating
                      ? null
                      : (bool? value) {
                          setState(() => _rememberServer = value ?? false);
                        },
                ),
                const SizedBox(width: AppSpacing.xxs),
                Expanded(
                  child: Text(
                    '记住服务器地址（只保存地址，不保存密码）',
                    style: AppText.small.copyWith(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (controller.isServerAddressSaved)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text('上次使用的地址已从本机普通配置读取。', style: AppText.caption),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: CloudTextAction(
            key: const ValueKey<String>('cloud-dev-notes-toggle'),
            label: _advancedOpen ? '收起开发环境说明' : '开发环境说明',
            icon: _advancedOpen
                ? Icons.expand_less_rounded
                : Icons.expand_more_rounded,
            onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
          ),
        ),
        if (_advancedOpen)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: AppSpacing.xs),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surfaceSunken,
              borderRadius: AppRadius.card,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '开发环境允许 HTTP 的条件',
                  style: AppText.bodyStrong.copyWith(fontSize: 12.5),
                ),
                const SizedBox(height: AppSpacing.xs),
                const CloudHintText(
                  '只有本机地址（localhost / 127.0.0.1）允许 http:// 明文连接，'
                  '其余地址必须使用 https://。连接方式会在「云端账号」卡片里标注，'
                  '正式使用请务必改回 HTTPS。',
                ),
              ],
            ),
          ),
        if (controller.loginErrorTitle != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          CloudBanner(
            key: const ValueKey<String>('cloud-login-error'),
            tone: CloudBannerTone.danger,
            title: controller.loginErrorTitle!,
            message: controller.loginErrorMessage,
            hint: controller.loginErrorHint,
          ),
        ],
        const SizedBox(height: AppSpacing.md + AppSpacing.xxs),
        CloudPrimaryButton(
          key: const ValueKey<String>('cloud-signin-submit'),
          label: '连接并登录',
          busy: authenticating,
          busyLabel: controller.isLoggingIn ? '正在登录…' : '正在连接…',
          icon: Icons.login_rounded,
          onPressed: _submit,
        ),
        const SizedBox(height: AppSpacing.sm + AppSpacing.xxs),
        const CloudHintText('登录只在本机建立会话，不会上传、覆盖或删除本机数据。'),
      ],
    );
  }
}
