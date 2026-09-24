import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../api.dart';
import '../models.dart';

/// Android: keeps playback running in the background and with the screen
/// locked (foreground service + wake lock via audio_service) and shows the
/// media controls on the lock screen and in the notification.
class BackgroundPlayback extends BaseAudioHandler with SeekHandler {
  BackgroundPlayback._();
  static BackgroundPlayback? _handler;

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> init() async {
    if (!supported || _handler != null) return;
    try {
      _handler = await AudioService.init(
        builder: BackgroundPlayback._,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'de.derseb90.rewind.playback',
          androidNotificationChannelName: 'Wiedergabe',
          // stays a foreground service while paused: Android 12+ doesn't allow
          // restarting it from the background (play on the lock screen)
          androidStopForegroundOnPause: false,
          // the launcher's monochrome layer: a proper white status bar icon
          androidNotificationIcon: 'drawable/ic_launcher_monochrome',
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      debugPrint('background playback unavailable: $e');
    }
  }

  static void attach(Player player, Vod vod) {
    _requestNotificationPermission();
    _handler?._attach(player, vod);
  }

  static bool _asked = false;

  /// Android 13+ shows the media notification / lock screen controls only
  /// with POST_NOTIFICATIONS (asked once, when something is played first).
  static Future<void> _requestNotificationPermission() async {
    if (_asked || !supported) return;
    _asked = true;
    try {
      await const MethodChannel('de.derseb90.rewind/platform').invokeMethod<bool>('requestNotificationPermission');
    } catch (e) {
      debugPrint('notification permission: $e');
    }
  }

  static void detach(Player player) => _handler?._detach(player);

  Player? _player;
  bool _live = false;
  final _subs = <StreamSubscription>[];
  DateTime _lastPositionUpdate = DateTime(0);

  void _attach(Player player, Vod vod) {
    _detach(_player);
    _player = player;
    _live = vod.growing;
    mediaItem.add(MediaItem(
      id: vod.id,
      title: vod.title.isEmpty ? 'Ohne Titel' : vod.title,
      artist: vod.channel?.displayName,
      album: vod.category.isEmpty ? 'rewind' : vod.category,
      duration: vod.growing || vod.durationMs <= 0 ? null : Duration(milliseconds: vod.durationMs),
      artUri: vod.thumbnail.isEmpty ? null : Uri.tryParse(Api.instance.url(vod.thumbnail)),
    ));
    _subs.addAll([
      player.stream.playing.listen((_) => _update()),
      player.stream.buffering.listen((_) => _update()),
      player.stream.completed.listen((_) => _update()),
      player.stream.duration.listen((d) {
        final item = mediaItem.value;
        if (!_live && item != null && d > Duration.zero && item.duration != d) mediaItem.add(item.copyWith(duration: d));
      }),
      // the system extrapolates the position while playing; resend now and
      // then and after jumps (seeks)
      player.stream.position.listen((p) {
        final expected = playbackState.value.position;
        if (DateTime.now().difference(_lastPositionUpdate) > const Duration(seconds: 5) || (p - expected).abs() > const Duration(seconds: 2)) {
          _update();
        }
      }),
    ]);
    _update();
  }

  void _detach(Player? player) {
    if (player == null || player != _player) return;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player = null;
    playbackState.add(PlaybackState(processingState: AudioProcessingState.idle, playing: false));
    mediaItem.add(null);
  }

  void _update() {
    final p = _player;
    if (p == null) return;
    _lastPositionUpdate = DateTime.now();
    final s = p.state;
    playbackState.add(PlaybackState(
      controls: [MediaControl.rewind, s.playing ? MediaControl.pause : MediaControl.play, MediaControl.fastForward],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: s.completed
          ? AudioProcessingState.completed
          : (s.buffering ? AudioProcessingState.buffering : AudioProcessingState.ready),
      playing: s.playing,
      updatePosition: s.position,
      speed: s.rate,
    ));
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> fastForward() async => _skip(const Duration(seconds: 10));

  @override
  Future<void> rewind() async => _skip(const Duration(seconds: -10));

  Future<void> _skip(Duration by) async {
    final p = _player;
    if (p == null) return;
    var to = p.state.position + by;
    if (to < Duration.zero) to = Duration.zero;
    await p.seek(to);
  }

  @override
  Future<void> stop() async {
    await _player?.pause();
    await super.stop();
  }
}
