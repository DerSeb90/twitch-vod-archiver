import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api.dart';
import 'models.dart';
import 'progress.dart';
import 'settings.dart';

/// Keeps every open app in step with the server: a long poll on
/// /api/changes wakes up as soon as another device saves progress or a VOD
/// appears, finishes or is deleted.
class LiveSync {
  LiveSync._();
  static final instance = LiveSync._();

  /// Bumped when the VOD lists changed on the server (reload them).
  final vods = ValueNotifier<int>(0);

  /// Recordings running right now (top bar badge), refreshed when VODs
  /// change and once a minute (viewer counts, durations).
  final live = ValueNotifier<List<LiveRecording>>(const []);
  Timer? _liveTimer;

  Future<void> refreshLive() async {
    if (_server.isEmpty) return;
    try {
      live.value = await Api.instance.live();
    } catch (_) {}
  }

  int? _seq, _vodsSeq, _since;
  int _generation = 0;
  String _server = '';

  void start() {
    Settings.instance.addListener(_serverMaybeChanged);
    _serverMaybeChanged();
    vods.addListener(refreshLive);
    _liveTimer ??= Timer.periodic(const Duration(minutes: 1), (_) => refreshLive());
  }

  void _serverMaybeChanged() {
    final url = Settings.instance.serverUrl;
    if (url == _server) return;
    _server = url;
    _seq = _vodsSeq = _since = null;
    live.value = const [];
    refreshLive();
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
        await Future<void>.delayed(Duration(seconds: math.min(30, 2 * failures)));
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

/// Version shown in the top bar: the app's own one in the native apps, the
/// server's (which serves the web app) in the browser.
class AppVersion {
  AppVersion._();
  static final label = ValueNotifier<String>('');

  static Future<void> load() async {
    try {
      if (kIsWeb) {
        final v = (await Api.instance.info()).version;
        label.value = RegExp(r'^\d').hasMatch(v) ? 'v$v' : v; // "1.2.3" → v1.2.3; "v1.2.3-4-gabc", "dev" as is
      } else {
        label.value = 'v${(await PackageInfo.fromPlatform()).version}';
      }
    } catch (_) {}
  }
}
