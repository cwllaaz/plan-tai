import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/contracts/contracts.dart';
import '../../core/models/models.dart';
import '../shared/mobile_sheets.dart';
import '../util/mobile_tasks.dart';
import 'mobile_task_editor_sheet.dart';

/// 打开任务编辑面板，并处理「删除后可撤销」的反馈。
///
/// 删除发生在编辑面板内部（`deleteTask`），这里拿到被删任务快照后弹
/// SnackBar「已删除 · 撤销」；撤销按原字段重建一条（软删除无法复活原 id）。
Future<void> openMobileTaskEditor(
  BuildContext context, {
  required PlannerRepository repository,
  required List<Project> projects,
  required LocalDate defaultDate,
  required LocalDate today,
  PlannerTask? initial,
  String? defaultProjectId,
}) async {
  final result = await showMobileTaskEditorSheet(
    context,
    repository: repository,
    projects: projects,
    defaultDate: defaultDate,
    today: today,
    initial: initial,
    defaultProjectId: defaultProjectId,
  );
  if (!context.mounted) return;
  final deleted = result.deletedTask;
  if (deleted != null) {
    _showUndoDelete(context, repository, deleted);
  }
}

void _showUndoDelete(
  BuildContext context,
  PlannerRepository repository,
  PlannerTask task,
) {
  showMobileSnack(
    context,
    '已删除「${task.title}」',
    actionLabel: '撤销',
    duration: const Duration(seconds: 5),
    onAction: () {
      unawaited(_restoreTask(context, repository, task));
    },
  );
}

Future<void> _restoreTask(
  BuildContext context,
  PlannerRepository repository,
  PlannerTask task,
) async {
  try {
    await repository.createTask(draftForRecreate(task));
    if (!context.mounted) return;
    showMobileSnack(context, '已恢复「${task.title}」');
  } on Object {
    if (!context.mounted) return;
    showMobileSnack(context, '恢复失败，请稍后重试', error: true);
  }
}

/// 任务勾选/取消完成，失败时就地提示（列表由仓储流自动回滚）。
Future<void> toggleMobileTaskDone(
  BuildContext context, {
  required PlannerRepository repository,
  required PlannerTask task,
}) async {
  final next = task.isDone ? TaskStatus.todo : TaskStatus.done;
  try {
    await repository.updateTask(task.copyWith(status: next));
  } on PlannerException catch (error) {
    if (!context.mounted) return;
    showMobileSnack(context, error.message, error: true);
  } on Object {
    if (!context.mounted) return;
    showMobileSnack(context, '更新任务状态失败，请稍后重试', error: true);
  }
}

/// 错误文案：只暴露给用户可理解的一句话。
String mobileReadableError(Object error) {
  if (error is PlannerException) return error.message;
  return '操作失败，请稍后重试';
}

/// 通用错误提示。
void showMobileError(BuildContext context, Object error) {
  showMobileSnack(context, mobileReadableError(error), error: true);
}
