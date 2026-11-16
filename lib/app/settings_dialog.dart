import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/theme/theme.dart';
import '../features/cloud_account/cloud_account.dart';
import '../platform/open_directory.dart';

/// 「设置」对话框：环境信息 + 云同步状态入口。
///
/// V1 的离线能力保持不变；登录、绑定、冲突处理都在顶栏云图标对应的面板里，
/// 这里只做只读汇总，避免出现第二个入口导致状态不一致。
Future<void> showSettingsDialog(
  BuildContext context, {
  required String? databasePath,
  required bool isDemoData,
  CloudAccountController? cloud,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _row('应用版本', '计划台 v2.0.0'),
            _row('数据位置', databasePath ?? (isDemoData ? '演示数据（不落盘）' : '未知')),
            _row('运行模式', isDemoData ? '演示数据模式' : '本地数据库模式'),
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.md),
            const Text('云同步', style: AppText.bodyStrong),
            const SizedBox(height: AppSpacing.sm),
            if (isDemoData)
              const Text('演示模式不连接云端，数据只存在内存中。', style: AppText.caption)
            else if (cloud == null)
              const Text('云同步未初始化。', style: AppText.caption)
            else
              ListenableBuilder(
                listenable: cloud,
                builder: (BuildContext context, Widget? _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _row('账号', cloud.isSignedIn ? cloud.accountLabel : '未登录'),
                      _row('服务器', cloud.serverUrl?.toString() ?? '未连接'),
                      _row(
                        '自动上传',
                        cloud.syncStatus.autoUploadEnabled ? '已开启' : '已关闭',
                      ),
                      _row(
                        '自动下载',
                        cloud.syncStatus.autoDownloadEnabled ? '已开启' : '已关闭',
                      ),
                      _row('待上传', '${cloud.syncStatus.pendingOperations} 项'),
                      if (cloud.syncStatus.lastError != null)
                        _row('最近错误', cloud.syncStatus.lastError!),
                    ],
                  );
                },
              ),
            const SizedBox(height: AppSpacing.md),
            const Text('登录、首次绑定与冲突处理在顶栏云图标中完成。', style: AppText.caption),
          ],
        ),
      ),
      actions: <Widget>[
        if (databasePath != null)
          TextButton.icon(
            onPressed: () async {
              final directory = File(databasePath).parent.path;
              try {
                await openDirectory(directory);
              } on Object {
                // 打不开文件管理器时保持对话框，不阻断用户。
              }
            },
            icon: const Icon(Icons.folder_open_rounded, size: AppSizes.iconSm),
            label: const Text('打开数据文件夹'),
          ),
        if (cloud != null && !isDemoData)
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              cloud.openPanel();
            },
            icon: const Icon(Icons.cloud_outlined, size: AppSizes.iconSm),
            label: const Text('打开云同步面板'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Widget _row(String label, String value) => Padding(
  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(width: 76, child: Text(label, style: AppText.caption)),
      Expanded(
        child: SelectableText(
          value,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      ),
    ],
  ),
);
