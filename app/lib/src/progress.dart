import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'settings.dart';

/// Watch progress. The server is the source of truth, so every device sees the
/// same position. Changes made here are also kept locally until the lists are
/// reloaded, so cards and rows update right away.
class WatchProgress {
  WatchProgress._();
  static final instance = WatchProgress._();

  /// From this position on a VOD counts as started (same as the server).
  static const resumeMinMs = 10000;

  /// Closer than this to the end counts as watched completely.
  static const endMarginMs = 30000;

  /// Bumped on every change that lists should reflect.
  final version = ValueNotifier<int>(0);
  final _local = <String, ({int positionMs, bool watched, DateTime at})>{};

  ({int positionMs, bool watched})? _newer(Vod v) {
    final l = _local[v.id];
    return l != null && l.at.isAfter(v.loadedAt) ? (positionMs: l.positionMs, watched: l.watched) : null;
  }

  int positionOf(Vod v) => _newer(v)?.positionMs ?? v.positionMs;
  bool watchedOf(Vod v) => _newer(v)?.watched ?? v.watched;

  /// Resume point for [v], or 0 to start from the beginning.
  int resumeOf(Vod v) {
    if (watchedOf(v)) return 0;
    final p = positionOf(v);
    if (p < resumeMinMs) return 0;
    // live: resume only if clearly behind the live edge
    if (v.growing) return v.durationMs - p > 60000 ? p : 0;
    return p < v.durationMs - endMarginMs ? p : 0;
  }

  /// Started but not finished.
  bool inProgress(Vod v) => !watchedOf(v) && positionOf(v) >= resumeMinMs;

  /// Saves a playback position. Failures are ignored: the player saves again
  /// a few seconds later.
  Future<void> save(String vodId, int positionMs, {bool watched = false, bool notify = false}) async {
    _local[vodId] = (positionMs: watched ? 0 : positionMs, watched: watched, at: DateTime.now());
    try {
      await Api.instance.putProgress(vodId, positionMs, watched: watched);
    } catch (_) {}
    if (notify) version.value++;
  }

  /// Marks a VOD as watched or resets it to unwatched (throws on failure).
  Future<void> setWatched(String vodId, bool watched) async {
    if (watched) {
      await Api.instance.putProgress(vodId, 0, watched: true);
    } else {
      await Api.instance.deleteProgress(vodId);
    }
    _local[vodId] = (positionMs: 0, watched: watched, at: DateTime.now());
    version.value++;
  }

  /// Progress another device saved (see LiveSync): shown right away.
  void applyRemote(Iterable<({String vodId, int positionMs, bool watched, int updatedAt})> list) {
    final now = DateTime.now();
    for (final p in list) {
      _local[p.vodId] = (positionMs: p.positionMs, watched: p.watched, at: now);
    }
    version.value++;
  }

  /// Moves progress that older app versions kept on this device to the server.
  Future<void> migrateLocal() async {
    final s = Settings.instance;
    if (s.serverUrl.isEmpty) return;
    final legacy = s.legacyProgress;
    for (final e in legacy.entries) {
      try {
        if (e.value >= resumeMinMs) await Api.instance.putProgress(e.key, e.value);
        s.dropLegacyProgress(e.key);
      } on ApiException catch (err) {
        if (err.status == 404) s.dropLegacyProgress(e.key); // VOD deleted meanwhile
      } catch (_) {
        return; // server not reachable: try again on the next start
      }
    }
    s.dropLegacyRecent();
    if (legacy.isNotEmpty) version.value++;
  }
}
