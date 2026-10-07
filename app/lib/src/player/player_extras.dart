import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models.dart';

/// Extra data the custom controls render on the seek bar.
class PlayerExtras {
  PlayerExtras({
    required this.vod,
    this.activity = const [],
    this.activityBucketMs = 30000,
    this.onToggleChat,
  });
  final Vod vod;

  /// Best known total length for [player].
  int durationMs(Player player) => math.max(
    math.max(player.state.duration.inMilliseconds, vod.durationMs),
    player.state.position.inMilliseconds,
  );
  List<int> activity;
  int activityBucketMs;
  final VoidCallback? onToggleChat;

  /// "Stats for nerds" overlay on the video (menu / key I).
  final nerdStats = ValueNotifier<bool>(false);

  /// The chat button only makes sense where the chat sits next to the video
  /// (on narrow screens it is a tab below it).
  bool chatButton = true;

  /// Where the last seek goes. Until the player reports it, seek bar and time
  /// show the target instead of jumping back to the old position.
  int? _seekTarget;
  Timer? _seekTimer;

  int positionMs(Player player) {
    final p = player.state.position.inMilliseconds;
    final t = _seekTarget;
    if (t == null) return p;
    if ((p - t).abs() < 1500) {
      _seekTarget = null;
      return p;
    }
    return t;
  }

  void seek(Player player, int ms) {
    ms = ms.clamp(0, math.max(0, durationMs(player)));
    _seekTarget = ms;
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(seconds: 3), () => _seekTarget = null);
    player.seek(Duration(milliseconds: ms));
  }
}
