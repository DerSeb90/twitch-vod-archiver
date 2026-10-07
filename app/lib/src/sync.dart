import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'progress.dart';
import 'settings.dart';

/// Keeps every open app in step with the server: a long poll on
/// /api/changes wakes up as soon as another device saves progress or a VOD
/// appears, finishes or is deleted.
class ServerSync {
  ServerSync._();
  static final instance = ServerSync._();

  /// Bumped when the VOD lists changed on the server (reload them).
  final vods = ValueNotifier<int>(0);

  /// Recordings running right now (top bar badge), refreshed when VODs
  /// change and once a minute (viewer counts, durations).
  final recordings = ValueNotifier<List<LiveRecording>>(const []);
  Timer? _recordingsTimer;

  Future<void> refreshRecordings() async {
    if (_server.isEmpty) return;
    try {
      recordings.value = await Api.instance.recordings();
    } catch (_) {}
  }

  int? _seq, _vodsSeq, _since;
  int _generation = 0;
  String _server = '';

  void start() {
    Settings.instance.addListener(_serverMaybeChanged);
    _serverMaybeChanged();
    vods.addListener(refreshRecordings);
    _recordingsTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => refreshRecordings(),
    );
  }

  void _serverMaybeChanged() {
    final url = Settings.instance.serverUrl;
    if (url == _server) return;
    _server = url;
    _seq = _vodsSeq = _since = null;
    recordings.value = const [];
    refreshRecordings();
    poke();
  }

  /// Checks right away (app back in the foreground) and restarts the poll.
  void poke() {
    final gen = ++_generation;
    if (_server.isNotEmpty) _loop(gen);
  }

  Future<void> _loop(int gen) async {
    var failures = 0;
    while (gen == _generation) {
      try {
        final s = await Api.instance.changes(_seq ?? 0);
        if (gen != _generation) return;
        await _apply(s);
        failures = 0;
      } catch (_) {
        if (gen != _generation) return;
        failures++;
        await Future<void>.delayed(
          Duration(seconds: math.min(30, 2 * failures)),
        );
      }
    }
  }

  Future<void> _apply(({int seq, int vods, int now}) s) async {
    if (_seq == null) {
      _seq = s.seq;
      _vodsSeq = s.vods;
      _since = s.now;
      return;
    }
    if (s.vods != _vodsSeq) {
      _vodsSeq = s.vods;
      vods.value++;
    }
    if (s.seq != _seq) {
      final list = await Api.instance.progressSince(_since ?? s.now);
      _seq = s.seq;
      if (list.isNotEmpty) {
        _since = list.map((p) => p.updatedAt).reduce(math.max);
        WatchProgress.instance.applyRemote(list);
      }
    }
  }
}
