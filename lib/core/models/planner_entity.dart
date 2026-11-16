/// 所有业务实体的公共基类。
///
/// 四个实体（Project / PlanSpan / PlannerTask / DailyNote）都带同一组同步基础字段，
/// 为将来接入云端同步预留，V1 只写不读：
///
/// | 字段 | 语义 |
/// |---|---|
/// | [id] | UUIDv7，客户端生成，永不变更 |
/// | [createdAt] | 创建时刻，**UTC** |
/// | [updatedAt] | 最后一次写入时刻，**UTC** |
/// | [revision] | 每次成功写入 +1，乐观并发控制依据 |
/// | [deletedAt] | 软删除时刻；非 null 表示已删除（查询默认过滤） |
///
/// 注意区分两类时间：[createdAt] / [updatedAt] / [deletedAt] 是**时刻**
/// （UTC DateTime），而业务上的"哪一天"一律用 `LocalDate`。
abstract class PlannerEntity {
  PlannerEntity({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    this.deletedAt,
  }) : assert(revision >= 1, 'revision 从 1 开始'),
       assert(createdAt.isUtc, 'createdAt 必须是 UTC'),
       assert(updatedAt.isUtc, 'updatedAt 必须是 UTC');

  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// 供子类实现值相等比较时复用。
  int baseHashCode() =>
      Object.hash(id, createdAt, updatedAt, revision, deletedAt);

  bool baseEquals(PlannerEntity other) =>
      id == other.id &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt &&
      revision == other.revision &&
      deletedAt == other.deletedAt;
}
