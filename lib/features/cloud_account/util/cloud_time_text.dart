/// 同步时间的展示文案。
///
/// 「今天/昨天」必须由调用方传入 [now]，模块内不读 `DateTime.now()`，
/// 这样测试与截图可以固定时钟（与 V1 的同一约束）。
library;

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime local) => '${_two(local.hour)}:${_two(local.minute)}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 相对时间：刚刚 / N 分钟前 / 今天 14:03 / 昨天 09:12 / 11月14日 09:12。
String formatSyncTime(DateTime? time, {required DateTime now}) {
  if (time == null) return '还没有成功同步过';
  final local = time.toLocal();
  final current = now.toLocal();
  final diff = current.difference(local);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60 && _sameDay(local, current)) {
    return '${diff.inMinutes} 分钟前';
  }
  if (_sameDay(local, current)) return '今天 ${_clock(local)}';
  final yesterday = DateTime(
    current.year,
    current.month,
    current.day,
  ).subtract(const Duration(days: 1));
  if (_sameDay(local, yesterday)) return '昨天 ${_clock(local)}';
  if (local.year == current.year) {
    return '${local.month}月${local.day}日 ${_clock(local)}';
  }
  return '${local.year}年${local.month}月${local.day}日 ${_clock(local)}';
}

/// 绝对时间，用于 tooltip 或需要精确时刻的行。
String formatSyncTimeAbsolute(DateTime? time) {
  if (time == null) return '从未同步';
  final local = time.toLocal();
  return '${local.year}年${local.month}月${local.day}日 ${_clock(local)}';
}

/// 连接时刻等需要「日期 + 时间」的场景。
String formatConnectedAt(DateTime time) => formatSyncTimeAbsolute(time);
