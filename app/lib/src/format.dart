String fmtDuration(int ms, {bool alwaysHours = false}) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0 || alwaysHours) return '$h:$m:$s';
  return '${d.inMinutes}:$s';
}

String fmtHours(int ms) {
  final h = ms / 3600000;
  if (h >= 100) return '${h.round()} Std.';
  if (h >= 1) return '${h.toStringAsFixed(1).replaceAll('.', ',')} Std.';
  return '${(ms / 60000).round()} Min.';
}

const _weekdays = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
const _weekdaysShort = ['Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.', 'So.'];
const _months = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];

String _two(int v) => v.toString().padLeft(2, '0');

/// Local calendar day of a timestamp (for grouping lists by day).
DateTime dayOf(int unixMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(unixMs);
  return DateTime(d.year, d.month, d.day);
}

/// "Heute", "Gestern", "Dienstag, 23. September" (year only when not this year).
String fmtDayHeading(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Heute';
  if (diff == 1) return 'Gestern';
  final s = '${_weekdays[day.weekday - 1]}, ${day.day}. ${_months[day.month - 1]}';
  return day.year == now.year ? s : '$s ${day.year}';
}

/// "20:15 Uhr".
String fmtTime(int unixMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(unixMs);
  return '${_two(d.hour)}:${_two(d.minute)} Uhr';
}

/// Start of a recording, always with a concrete date: "Heute, 20:15",
/// "Gestern, 20:15", "Di. 23.09., 20:15".
String fmtWhen(int unixMs) {
  if (unixMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(unixMs);
  final time = '${_two(d.hour)}:${_two(d.minute)}';
  final day = dayOf(unixMs);
  final heading = fmtDayHeading(day);
  if (heading == 'Heute' || heading == 'Gestern') return '$heading, $time';
  final y = d.year == DateTime.now().year ? '' : '${d.year}';
  return '${_weekdaysShort[d.weekday - 1]} ${_two(d.day)}.${_two(d.month)}.$y, $time';
}

String fmtDate(int unixMs, {bool time = false}) {
  final d = DateTime.fromMillisecondsSinceEpoch(unixMs);
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${two(d.day)}.${two(d.month)}.${d.year}';
  return time ? '$date, ${two(d.hour)}:${two(d.minute)} Uhr' : date;
}

String fmtBytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1).replaceAll('.', ',')} ${units[i]}';
}

String fmtCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',')} Mio.';
  if (n >= 10000) return '${(n / 1000).round()}k';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1).replaceAll('.', ',')}k';
  return '$n';
}
