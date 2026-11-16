/// 手工验收辅助：在真实服务器上登录一次，把会话写入 Windows 凭据管理器，
/// 并创建一个空的账号工作区 + 指针文件，供**正式 release exe** 启动时恢复会话、
/// 自动拉取云端数据（用于截图/验收，不参与默认测试）。
///
/// 运行：
/// ```powershell
/// $env:JIHUATAI_E2E='1'
/// $env:JIHUATAI_E2E_SERVER='http://127.0.0.1:8090'
/// $env:JIHUATAI_E2E_USER='sync-test@jihuatai.local'
/// $env:JIHUATAI_E2E_PASS='TestPass12345'
/// $env:JIHUATAI_E2E_DATA_DIR='...\build\exe-demo'
/// flutter test test/integration/seed_exe_session_test.dart
/// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/app/cloud_workspace.dart';
import 'package:jihuatai/core/cloud/cloud.dart';
import 'package:jihuatai/data/cloud/cloud.dart';
import 'package:jihuatai/data/sqlite_planner_repository.dart';
import 'package:jihuatai/data/sync/sync.dart';

void main() {
  final enabled = Platform.environment['JIHUATAI_E2E'] == '1';

  test('seed Windows session + account workspace for release exe', () async {
    final dataRoot = Platform.environment['JIHUATAI_E2E_DATA_DIR']!;
    final server = Platform.environment['JIHUATAI_E2E_SERVER']!;
    final email = Platform.environment['JIHUATAI_E2E_USER']!;
    final password = Platform.environment['JIHUATAI_E2E_PASS']!;

    final dataDirectory = '$dataRoot${Platform.pathSeparator}data';
    Directory(dataDirectory).createSync(recursive: true);

    final repo = SqlitePlannerRepository.open(
      databasePath: '$dataDirectory${Platform.pathSeparator}app.db',
    );
    final account = PocketBaseAccountService(
      tokenStore: WindowsCredentialStore(),
    );
    final sync = SqliteCloudSyncService(
      repository: repo,
      account: account,
      credentials: account,
      api: PlannerApi(),
      layout: WorkspaceLayout(dataDirectory),
      autoStart: false,
    );

    try {
      await account.connectServer(Uri.parse(server));
      final signedIn = await account.login(
        username: email,
        password: password,
      );
      final inspection = await sync.inspectBinding();
      expect(
        inspection.situation,
        anyOf(
          BindingSituation.freshInstallCloudHasData,
          BindingSituation.freshInstallCloudEmpty,
        ),
      );
      final result = await sync.applyBinding(
        BindingChoice.useCloudAndArchiveLocal,
      );
      expect(result.requiresRestart, isTrue, reason: result.message);
      final workspaceDb = WorkspaceLayout(
        dataDirectory,
      ).accountDatabasePath(signedIn.ownerId);
      expect(File(workspaceDb).existsSync(), isTrue);
      CloudWorkspaceStore(dataDirectory).remember(signedIn.ownerId, workspaceDb);
      // 让账号服务在关闭前把 token 写入凭据管理器（login 已写入）。
      expect(account.currentAccount()?.ownerId, signedIn.ownerId);
    } finally {
      await sync.close();
      await account.close();
      await repo.close();
    }
  }, skip: enabled ? false : '设置 JIHUATAI_E2E=1 后运行');
}
