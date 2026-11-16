/// 云端错误与状态文案的唯一来源。
///
/// 界面不各自拼句子：同一类错误在登录面板、同步面板、冲突页显示一致的说法。
/// 契约要求 UI 不暴露 HTTP 状态码、JSON 异常或堆栈，这里只翻译成用户语言。
library;

import '../../../core/cloud/cloud.dart';

/// 用户视角的简短标题。
String cloudErrorTitle(CloudErrorKind kind) => switch (kind) {
  CloudErrorKind.unauthorized => '登录失败',
  CloudErrorKind.forbidden => '没有权限',
  CloudErrorKind.notFound => '找不到服务器接口',
  CloudErrorKind.rateLimited => '操作太频繁',
  CloudErrorKind.protocol => '请检查输入',
  CloudErrorKind.conflict => '数据冲突',
  CloudErrorKind.network => '无法连接服务器',
  CloudErrorKind.timeout => '连接超时',
  CloudErrorKind.server => '服务器暂时不可用',
  CloudErrorKind.cancelled => '操作已取消',
  CloudErrorKind.unknown => '操作失败',
};

/// 主文案：说明发生了什么。
String cloudErrorMessage(CloudException error) {
  final message = error.message.trim();
  if (message.isNotEmpty) return message;
  return cloudErrorTitle(error.kind);
}

/// 补充建议：告诉用户下一步怎么做。
String? cloudErrorHint(CloudErrorKind kind) => switch (kind) {
  CloudErrorKind.unauthorized => '请检查账号和密码是否正确，注意大小写与首尾空格。',
  CloudErrorKind.forbidden => '该账号没有访问这个服务器的权限，请联系服务器管理员。',
  CloudErrorKind.notFound => '服务器地址可能填错了，或服务端未部署计划台同步接口（/api/planner）。',
  CloudErrorKind.rateLimited => '请稍等片刻再试。',
  CloudErrorKind.protocol => '请确认服务器地址与客户端版本；正式连接必须使用 HTTPS。',
  CloudErrorKind.network => '请检查网络连接、服务器地址和端口是否可访问。',
  CloudErrorKind.timeout => '网络较慢或服务器繁忙，请稍后重试。',
  CloudErrorKind.server => '同步服务暂时不可用，请稍后重试；本地改动已保存在本机。',
  CloudErrorKind.conflict => '请先在冲突处理页选择保留哪一版。',
  CloudErrorKind.cancelled => null,
  CloudErrorKind.unknown => '请重试；如果反复失败，请记录服务器地址后联系维护者。',
};

/// 绑定场景的标题。
String bindingTitle(BindingSituation situation) => switch (situation) {
  BindingSituation.freshInstallCloudEmpty => '首次使用',
  BindingSituation.freshInstallCloudHasData => '云端已有数据',
  BindingSituation.localDataCloudEmpty => '关联本机数据',
  BindingSituation.bothHaveData => '本机与云端都有数据',
  BindingSituation.boundSameAccount => '已关联当前账号',
  BindingSituation.boundOtherAccount => '本机数据属于其他账号',
};

/// 每类场景的推荐按钮文案（主操作）。
String bindingPrimaryLabel(BindingInspection inspection) {
  return switch (inspection.situation) {
    BindingSituation.localDataCloudEmpty => '上传本机数据到该账号',
    BindingSituation.freshInstallCloudHasData => '创建本机工作区并下载云端数据',
    BindingSituation.bothHaveData => '以云端为准（先备份并归档本机数据）',
    BindingSituation.boundOtherAccount => '为当前账号新建空工作区',
    BindingSituation.freshInstallCloudEmpty => '创建账号工作区',
    BindingSituation.boundSameAccount => '继续同步',
  };
}

/// 主操作对应的 [BindingChoice]。
BindingChoice bindingPrimaryChoice(BindingInspection inspection) {
  return switch (inspection.situation) {
    BindingSituation.localDataCloudEmpty => BindingChoice.uploadLocalToAccount,
    BindingSituation.freshInstallCloudHasData =>
      BindingChoice.useCloudAndArchiveLocal,
    BindingSituation.bothHaveData => BindingChoice.useCloudAndArchiveLocal,
    BindingSituation.boundOtherAccount => BindingChoice.keepLocalUnbound,
    BindingSituation.freshInstallCloudEmpty => BindingChoice.keepLocalUnbound,
    BindingSituation.boundSameAccount => BindingChoice.keepLocalUnbound,
  };
}

/// 绑定选项对应的中文说明。
String bindingChoiceLabel(BindingChoice choice) => switch (choice) {
  BindingChoice.uploadLocalToAccount => '上传本机数据到当前账号',
  BindingChoice.useCloudAndArchiveLocal => '以云端为准，先归档备份本机数据',
  BindingChoice.keepLocalUnbound => '保持本地数据不绑定',
  BindingChoice.cancel => '取消本次登录',
};

/// 冲突解决方式的中文名。
String conflictResolutionLabel(ConflictResolution resolution) =>
    switch (resolution) {
      ConflictResolution.keepLocal => '保留本机修改',
      ConflictResolution.keepServer => '使用云端修改',
      ConflictResolution.manual => '手动合并',
    };
