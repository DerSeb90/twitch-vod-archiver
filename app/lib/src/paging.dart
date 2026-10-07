import 'dart:ui' show VoidCallback;

import 'models.dart';

/// Offset paging for VOD lists. The offset counts what the server returned,
/// not what is shown (lists hide VODs marked watched meanwhile), and a page
/// that failed stops loading on scroll until [retry].
class VodPager {
  VodPager(this._fetch, {required this.onChange, this.pageSize = 36});
  final Future<VodPage> Function(int offset, int limit) _fetch;

  /// Called when [loading], [error] or [items] changed after [more].
  final VoidCallback onChange;
  final int pageSize;

  List<Vod> items = const [];
  int total = 0;
  bool loading = false;
  Object? error;
  int _generation = 0;

  bool get hasMore => items.length < total;

  /// Starts over with [first] (fetched by the page along with its other data).
  void reset(VodPage first) {
    _generation++;
    items = first.items;
    total = first.total;
    loading = false;
    error = null;
  }

  /// Loads the next page unless one is loading, the last one failed or
  /// everything is there.
  Future<void> more() async {
    if (loading || error != null || !hasMore) return;
    final gen = _generation;
    loading = true;
    onChange();
    try {
      final p = await _fetch(items.length, pageSize);
      if (gen != _generation) return; // reloaded meanwhile
      items = [...items, ...p.items];
      // fewer than announced (deleted meanwhile): stop instead of asking again
      total = p.items.isEmpty ? items.length : p.total;
    } catch (e) {
      if (gen == _generation) error = e;
    } finally {
      if (gen == _generation) {
        loading = false;
        onChange();
      }
    }
  }

  void retry() {
    error = null;
    more();
  }
}
