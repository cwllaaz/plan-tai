import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jihuatai/core/models/models.dart';
import 'package:jihuatai/data/data.dart';
import 'package:path/path.dart' as p;

/// 正式数据链路：真实 SQLite 文件 → 关闭 → 重新打开 → 数据完整；
/// 以及备份导出 → 删除数据 → 从备份恢复 → 数据回来。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jihuatai_it_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上文件句柄可能延迟释放，测试清理失败不影响断言。
    }
  });

  test('重启持久化：关闭后重新打开，项目/任务/备注都在', () async {
    final dbPath = p.join(tempDir.path, 'app.db');
    var repository = SqlitePlannerRepository.open(databasePath: dbPath);

    final project = await repository.createProject(
      const ProjectDraft(name: '持久化项目', description: '重启后应还在'),
    );
    await repository.createTask(
      PlannerTaskDraft(
        title: '持久化任务',
        projectId: project.id,
        scheduledDate: LocalDate(2026, 11, 14),
      ),
    );
    await repository.saveDailyNote(
      LocalDate(2026, 11, 14),
      body: '当晚复盘',
    );
    await repository.close();

    repository = SqlitePlannerRepository.open(databasePath: dbPath);
    final projects = await repository.watchProjects().first;
    final tasks = await repository.watchAllTasks().first;
    final note = await repository.findDailyNote(LocalDate(2026, 11, 14));

    expect(projects.single.name, '持久化项目');
    expect(tasks.single.title, '持久化任务');
    expect(note?.body, '当晚复盘');
    await repository.close();
  });

  test('备份导出 → 删除 → 恢复，数据与备份一致', () async {
    final dbPath = p.join(tempDir.path, 'app.db');
    final repository = SqlitePlannerRepository.open(databasePath: dbPath);
    final service = BackupService(
      repository,
      backupDirectory: p.join(tempDir.path, 'backups'),
    );

    final project = await repository.createProject(
      const ProjectDraft(name: '备份项目'),
    );
    await repository.createTask(
      PlannerTaskDraft(
        title: '备份任务',
        projectId: project.id,
        scheduledDate: LocalDate(2026, 11, 15),
      ),
    );
    await repository.saveDailyNote(
      LocalDate(2026, 11, 15),
      body: '备份前写入',
    );

    final backupPath = await service.exportJson(
      targetPath: p.join(tempDir.path, 'backup.json'),
    );
    expect(File(backupPath).existsSync(), isTrue);

    final decoded = jsonDecode(File(backupPath).readAsStringSync());
    expect(decoded, isA<Map<String, Object?>>());
    expect((decoded as Map<String, Object?>)['schemaVersion'], 2);

    // 清空数据：删除项目会级联删除任务。
    await repository.deleteProject(project.id);
    expect(await repository.watchProjects().first, isEmpty);
    expect(await repository.watchAllTasks().first, isEmpty);

    final preview = await service.inspect(backupPath);
    expect(preview.content.liveProjectCount, 1);
    expect(preview.content.liveTaskCount, 1);

    final result = await service.restore(preview, confirmOverwrite: true);
    expect(result.projects, 1);
    expect(result.tasks, 1);
    expect(result.safetyCopyPath, isNotEmpty);

    final projects = await repository.watchProjects().first;
    final tasks = await repository.watchAllTasks().first;
    final note = await repository.findDailyNote(LocalDate(2026, 11, 15));
    expect(projects.single.name, '备份项目');
    expect(tasks.single.title, '备份任务');
    expect(note?.body, '备份前写入');

    await repository.close();
  });
}
