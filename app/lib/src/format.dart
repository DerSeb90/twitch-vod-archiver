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

String fmtRelative(int unixMs) {
  if (unixMs <= 0) return '';
  final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unixMs));
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min.';
  if (diff.inHours < 24) return 'vor ${diff.inHours} Std.';
  if (diff.inDays == 1) return 'gestern';
  if (diff.inDays < 7) return 'vor ${diff.inDays} Tagen';
  return fmtDate(unixMs);
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
