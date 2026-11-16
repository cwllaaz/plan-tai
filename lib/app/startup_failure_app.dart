import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/theme/theme.dart';
import '../data/planner_paths.dart';

/// 数据库打不开时的兜底界面：给出可读原因与数据位置，不静默退出、不重建库。
///
/// Windows 与 Android 共用：两端都遵守「不删除用户数据、不自动重建库」的约定。
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    String? dataPath;
    try {
      dataPath = PlannerPaths.defaultDatabasePath();
    } on Object {
      dataPath = null;
    }
    return MaterialApp(
      title: '计划台',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: ColoredBox(
        color: AppColors.canvas,
        child: Center(
          child: Container(
            width: 540,
            padding: const EdgeInsets.all(AppSpacing.xxl),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.panel,
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.danger,
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Text('无法启动计划台', style: AppText.h1),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(message, style: AppText.body),
                if (dataPath != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  const Text('数据位置', style: AppText.caption),
                  const SizedBox(height: AppSpacing.xxs),
                  SelectableText(
                    dataPath,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                const Text(
                  '数据文件没有被删除。请检查磁盘空间与文件权限后重新打开；'
                  '如需在无数据库的情况下演示界面，可设置环境变量 JIHUATAI_DEMO=1。',
                  style: AppText.caption,
                ),
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => exit(1),
                    child: const Text('退出'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
