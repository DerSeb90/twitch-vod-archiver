import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/player/chat_replay.dart';

void main() {
  test('keeps only chunks around the position', () {
    final w = ChunkWindow<String>();
    for (var i = 0; i <= 4; i++) {
      w.put(i, 'c$i');
    }
    expect(w.keys, unorderedEquals([0, 1, 2])); // 3 and 4 are too far from 0

    w.moveTo(3);
    w.put(3, 'c3');
    w.put(4, 'c4');
    w.put(5, 'c5');
    expect(w.keys, unorderedEquals([1, 2, 3, 4, 5]));
    expect(w[4], 'c4');

    w.moveTo(10); // seek far ahead: everything old is dropped
    expect(w.keys, isEmpty);
  });

  test('ignores responses for chunks the position already left', () {
    final w = ChunkWindow<String>()..moveTo(20);
    w.put(2, 'late');
    expect(w.contains(2), isFalse);
    expect(w.covers(22), isTrue);
    expect(w.covers(23), isFalse);
  });
}
