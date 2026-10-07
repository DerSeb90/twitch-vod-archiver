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

const _weekdaysShort = ['Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.', 'So.'];

String _two(int v) => v.toString().padLeft(2, '0');

/// "Heute" / "Gestern" for those two days, else null.
String? _relativeDay(DateTime d) {
  final now = DateTime.now();
  final diff = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(d.year, d.month, d.day)).inDays;
  return switch (diff) {
    0 => 'Heute',
    1 => 'Gestern',
    _ => null,
  };
}

/// "Mo., 29.09." (with the year when it isn't this year).
String _shortDate(DateTime d) {
  final y = d.year == DateTime.now().year ? '' : '${d.year}';
  return '${_weekdaysShort[d.weekday - 1]}, ${_two(d.day)}.${_two(d.month)}.$y';
}

/// Start of a recording, always with a concrete date: "Heute, 20:15",
/// "Gestern, 20:15", "Di., 23.09., 20:15".
String fmtWhen(int unixMs) {
  if (unixMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(unixMs);
  final time = '${_two(d.hour)}:${_two(d.minute)}';
  return '${_relativeDay(d) ?? _shortDate(d)}, $time';
}

/// Compact start of a recording for cards: "Heute, 20:15", "Gestern, 19:02",
/// older ones by date only ("Mo., 29.09.", "Mo., 29.09.2025").
String fmtWhenShort(int unixMs) {
  if (unixMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(unixMs);
  final rel = _relativeDay(d);
  return rel == null
      ? _shortDate(d)
      : '$rel, ${_two(d.hour)}:${_two(d.minute)}';
}

/// "6,2 Mbit/s".
String fmtMbit(double mbit) =>
    '${mbit.toStringAsFixed(1).replaceAll('.', ',')} Mbit/s';

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
  if (n >= 1000000) {
    return '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',')} Mio.';
  }
  if (n >= 10000) return '${(n / 1000).round()}k';
  if (n >= 1000) {
    return '${(n / 1000).toStringAsFixed(1).replaceAll('.', ',')}k';
  }
  return '$n';
}
