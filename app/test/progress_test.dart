import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/progress.dart';

({String vodId, int positionMs, bool watched, int updatedAt}) p(String id, int pos, {bool watched = false}) =>
    (vodId: id, positionMs: pos, watched: watched, updatedAt: 0);

void main() {
  test('remote progress notifies only when something changed', () {
    final w = WatchProgress.instance;
    var n = 0;
    void count() => n++;
    w.version.addListener(count);
    addTearDown(() => w.version.removeListener(count));

    w.applyRemote([p('a', 50000)]);
    expect(n, 1);
    w.applyRemote([p('a', 50000)]); // this device's own save coming back
    expect(n, 1);
    w.applyRemote([p('a', 60000)]);
    expect(n, 2);
    w.applyRemote([p('a', 60000), p('b', 20000)]);
    expect(n, 3);
    w.applyRemote([p('a', 90000, watched: true)]);
    expect(n, 4);
    w.applyRemote([p('a', 0, watched: true)]); // watched: the position doesn't matter
    expect(n, 4);
    w.applyRemote(const []);
    expect(n, 4);
  });
}
