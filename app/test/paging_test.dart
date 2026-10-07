import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/models.dart';
import 'package:rewind/src/paging.dart';

Vod vod(int i) => Vod.fromJson({'id': 'v$i', 'status': 'ready'});

VodPage page(int from, int count, int total) =>
    VodPage([for (var i = from; i < from + count; i++) vod(i)], total);

void main() {
  test(
    'asks for the next page at the number of items the server returned',
    () async {
      final offsets = <int>[];
      final pager = VodPager(
        (offset, limit) async {
          offsets.add(offset);
          return page(offset, 2, 5);
        },
        onChange: () {},
        pageSize: 2,
      );
      pager.reset(page(0, 2, 5));
      await pager.more();
      await pager.more();
      expect(offsets, [2, 4]);
      expect(pager.items.map((v) => v.id), [
        'v0',
        'v1',
        'v2',
        'v3',
        'v4',
        'v5',
      ]);
      expect(pager.hasMore, isFalse);
    },
  );

  test('a failed page stops loading until retry', () async {
    var fail = true;
    var calls = 0;
    final pager = VodPager(
      (offset, limit) async {
        calls++;
        if (fail) throw Exception('offline');
        return page(offset, 2, 4);
      },
      onChange: () {},
      pageSize: 2,
    );
    pager.reset(page(0, 2, 4));
    await pager.more();
    expect(pager.error, isNotNull);
    await pager.more(); // scrolling again doesn't hammer the server
    expect(calls, 1);
    fail = false;
    pager.retry();
    await Future<void>.delayed(Duration.zero);
    expect(pager.error, isNull);
    expect(pager.items.length, 4);
  });

  test('a page arriving after a reload is dropped', () async {
    late void Function(VodPage) answer;
    final pager = VodPager(
      (offset, limit) {
        final c = Completer<VodPage>();
        answer = c.complete;
        return c.future;
      },
      onChange: () {},
      pageSize: 2,
    );
    pager.reset(page(0, 2, 6));
    final pending = pager.more();
    pager.reset(page(10, 2, 6)); // pull to refresh meanwhile
    answer(page(2, 2, 6));
    await pending;
    expect(pager.items.map((v) => v.id), ['v10', 'v11']);
    expect(pager.loading, isFalse);
  });

  test('stops when the server has fewer items than announced', () async {
    var calls = 0;
    final pager = VodPager(
      (offset, limit) async {
        calls++;
        return VodPage(const [], 9);
      },
      onChange: () {},
      pageSize: 2,
    );
    pager.reset(page(0, 2, 9));
    await pager.more();
    await pager.more();
    expect(calls, 1);
    expect(pager.hasMore, isFalse);
  });
}
