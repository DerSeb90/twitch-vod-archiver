import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/format.dart';

void main() {
  int at(DateTime d) => d.millisecondsSinceEpoch;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 20, 15);

  test('fmtWhenShort: today and yesterday with the time', () {
    expect(fmtWhenShort(at(today)), 'Heute, 20:15');
    final yesterday = DateTime(now.year, now.month, now.day - 1, 9, 2);
    expect(fmtWhenShort(at(yesterday)), 'Gestern, 09:02');
  });

  test('fmtWhenShort: older ones by date, the year only when needed', () {
    // 29.09.2025 was a Monday
    expect(fmtWhenShort(at(DateTime(2025, 9, 29, 18))), 'Mo., 29.09.2025');
    final old = DateTime(now.year, now.month, now.day - 3, 18);
    const days = ['Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.', 'So.'];
    String two(int v) => v.toString().padLeft(2, '0');
    final year = old.year == now.year ? '' : '${old.year}';
    expect(
      fmtWhenShort(at(old)),
      '${days[old.weekday - 1]}, ${two(old.day)}.${two(old.month)}.$year',
    );
    expect(fmtWhenShort(0), '');
  });

  test('fmtWhen: always with the time', () {
    expect(fmtWhen(at(today)), 'Heute, 20:15');
    expect(fmtWhen(at(DateTime(2025, 9, 29, 18, 5))), 'Mo., 29.09.2025, 18:05');
  });
}
