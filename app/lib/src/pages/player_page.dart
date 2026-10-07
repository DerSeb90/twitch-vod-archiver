import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../models.dart';
import '../player/background.dart';
import '../player/chat_replay.dart';
import '../player/controls.dart';
import '../player/player_extras.dart';
import '../player/player_info.dart';
import '../progress.dart';
import '../settings.dart';
import '../sync.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/shell.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.id});
  final String id;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  Vod? _vod;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
    ServerSync.instance.vods.addListener(_vodsChanged);
  }

  @override
  void dispose() {
    ServerSync.instance.vods.removeListener(_vodsChanged);
    super.dispose();
  }

  /// Still recording or processing: opens on its own once it is finished.
  void _vodsChanged() {
    if (_vod != null && !_vod!.playable) _load();
  }

  Future<void> _load() async {
    try {
      final v = await Api.instance.vod(widget.id);
      if (mounted) {
        setState(() {
          _vod = v;
          _error = null;
        });
      }
    } catch (e) {
      // a failed quiet reload keeps showing the recording state
      if (mounted && _vod == null) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: ErrorBox(error: _error!, onRetry: _load));
    if (_vod == null) return const Center(child: CircularProgressIndicator(color: C.primary));
    if (!_vod!.playable) {
      return Center(
        child: EmptyState(
          icon: Icons.hourglass_top_rounded,
          title: _vod!.recording ? 'Wird noch aufgenommen' : 'Noch nicht verfügbar',
          subtitle: _vod!.status == 'failed'
              ? 'Verarbeitung fehlgeschlagen: ${_vod!.error}'
              : 'Abspielbar, sobald die Aufnahme abgeschlossen und verarbeitet ist. Die Seite lädt dann von selbst.',
        ),
      );
    }
    return _Player(key: ValueKey(_vod!.id), vod: _vod!);
  }
}

class _Player extends StatefulWidget {
  const _Player({super.key, required this.vod});
  final Vod vod;
  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> with RouteAware {
  late final Player _player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024, title: 'rewind'));
  late final VideoController _video = VideoController(_player);
  late final ChatReplayController _chat = ChatReplayController(widget.vod);
  late final PlayerExtras _extras = PlayerExtras(vod: widget.vod, onToggleChat: _toggleChat);
  Timer? _tick, _saveTimer;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Timer? _errorCheck;

  /// Why playback failed; shown over the video with a retry button.
  String? _failed;
  final _videoKey = GlobalKey<VideoState>();

  /// Last position sent to the server; whether this session marked it watched.
  int _savedMs = -1;
  bool _watched = false;

  /// Set after "mark (un)watched" in the menu: from then on this session no
  /// longer saves, so it can't undo the manual choice.
  bool _manual = false;

  /// Another page (channel, a second player) was pushed on top: this one is
  /// paused and neither saves progress nor marks the VOD watched meanwhile.
  bool _covered = false;
  PageRoute<dynamic>? _route;

  Vod get vod => widget.vod;

  /// Phones rotate into fullscreen (video only, no chat).
  bool get _rotateToFullscreen =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) &&
      MediaQuery.sizeOf(context).shortestSide < 600;
  Orientation? _orientation;
  bool _fullscreenByRotation = false;

  @override
  void initState() {
    super.initState();
    _open(Duration(milliseconds: WatchProgress.instance.resumeOf(vod)));
    _chat.init();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _chat.update(_player.state.position.inMilliseconds));
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    BackgroundPlayback.attach(_player, vod);
    _errorSub = _player.stream.error.listen(_onError);
    _completedSub = _player.stream.completed.listen((done) {
      if (done && !_covered) _markWatched();
    });
    _loadActivity();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) shellRouteObserver.unsubscribe(this);
      _route = route;
      shellRouteObserver.subscribe(this, route);
    }
    final o = MediaQuery.orientationOf(context);
    if (o == _orientation) return;
    _orientation = o;
    if (!_rotateToFullscreen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final v = _videoKey.currentState;
      if (!mounted || v == null || _orientation != o) return;
      final fs = v.isFullscreen();
      if (o == Orientation.landscape && !fs) {
        _fullscreenByRotation = true;
        v.enterFullscreen();
      } else if (o == Orientation.portrait && fs && _fullscreenByRotation) {
        v.exitFullscreen();
      }
    });
  }

  @override
  void didPushNext() {
    _saveProgress(closing: true);
    _covered = true;
    _player.pause();
    BackgroundPlayback.detach(_player);
  }

  @override
  void didPopNext() {
    _covered = false;
    BackgroundPlayback.attach(_player, vod);
  }

  /// Like media_kit's default, but fullscreen entered by rotating the phone
  /// doesn't lock the orientation: turning it back to portrait leaves it.
  Future<void> _enterFullscreen() async {
    if (!_rotateToFullscreen) return defaultEnterNativeFullscreen();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
    if (!_fullscreenByRotation) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
  }

  Future<void> _exitFullscreen() async {
    _fullscreenByRotation = false;
    await defaultExitNativeFullscreen();
  }

  Future<void> _open(Duration start) async {
    await _player.setVolume(Settings.instance.volume);
    final media = Api.instance.url(vod.video);
    if (start == Duration.zero) {
      await _player.open(Media(media));
    } else if (!kIsWeb) {
      // mpv: `start` is only the initial position, seeking back stays possible
      await _player.open(Media(media, start: start));
    } else {
      // Web: media_kit turns Media.start into a clip start (no seeking before
      // it). Load paused, jump as soon as the duration is known, then play.
      await _player.open(Media(media), play: false);
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
      await _player.seek(start);
      await _player.play();
    }
  }

  /// mpv also reports harmless hiccups (a broken frame, a reconnect) as
  /// errors, the browser a blocked autoplay. Playback counts as failed only
  /// if a few seconds later the media still has no duration or is stuck
  /// buffering at the same spot.
  void _onError(String e) {
    debugPrint('player: $e');
    if (_failed != null || (_errorCheck?.isActive ?? false)) return;
    final at = _player.state.position;
    _errorCheck = Timer(const Duration(seconds: 8), () {
      final s = _player.state;
      if (!mounted || _failed != null) return;
      if (s.duration == Duration.zero || (s.buffering && s.position == at)) {
        _videoKey.currentState?.exitFullscreen(); // the message is on the page
        setState(() => _failed = e);
      }
    });
  }

  Future<void> _retry() async {
    final at = _player.state.position;
    setState(() => _failed = null);
    await _open(at > Duration.zero ? at : Duration(milliseconds: WatchProgress.instance.resumeOf(vod)));
  }

  Future<void> _loadActivity() async {
    try {
      final j = await Api.instance.mediaJson('${vod.base}chat/activity.json') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _extras.activity = [for (final c in j['counts'] as List) (c as num).toInt()];
        _extras.activityBucketMs = (j['bucketMs'] as num).toInt();
      });
    } catch (_) {}
  }

  void _saveProgress({bool closing = false}) {
    if (_manual || _covered) return;
    final p = _player.state.position.inMilliseconds;
    final dur = _player.state.duration.inMilliseconds > 0 ? _player.state.duration.inMilliseconds : vod.durationMs;
    if (p > WatchProgress.resumeMinMs && p >= dur - WatchProgress.endMarginMs) {
      _markWatched(closing: closing);
      return;
    }
    // Short views don't count (and don't un-watch a watched VOD).
    if (p < WatchProgress.resumeMinMs || (!closing && (p - _savedMs).abs() < 2000)) {
      if (closing && _savedMs >= 0) WatchProgress.instance.version.value++;
      return;
    }
    _savedMs = p;
    _watched = false;
    WatchProgress.instance.save(vod.id, p, notify: closing);
  }

  void _markWatched({bool closing = false}) {
    if (_manual || _watched) {
      if (closing) WatchProgress.instance.version.value++;
      return;
    }
    _watched = true;
    _savedMs = 0;
    WatchProgress.instance.save(vod.id, 0, watched: true, notify: true);
  }

  Future<void> _setWatched(bool watched) async {
    try {
      await WatchProgress.instance.setWatched(vod.id, watched);
      _manual = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(watched ? 'Als gesehen markiert' : 'Fortschritt zurückgesetzt')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nicht gespeichert: $e')));
    }
  }

  void _toggleChat() => Settings.instance.chatVisible = !Settings.instance.chatVisible;

  void _seek(int ms) {
    _extras.seek(_player, ms);
    _player.play();
  }

  @override
  void dispose() {
    shellRouteObserver.unsubscribe(this);
    _saveProgress(closing: true);
    BackgroundPlayback.detach(_player);
    _completedSub?.cancel();
    _errorSub?.cancel();
    _errorCheck?.cancel();
    _tick?.cancel();
    _saveTimer?.cancel();
    _chat.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Settings.instance,
        builder: (context, _) => LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 1080;
          // phone browser held sideways: video and chat side by side (the
          // apps switch to fullscreen instead)
          final sideways = !wide && c.maxWidth > c.maxHeight * 1.2;
          final chatOn = Settings.instance.chatVisible;
          _extras.chatButton = wide || sideways;
          Widget videoWidget = Video(
            key: _videoKey,
            controller: _video,
            controls: (state) => RewindControls(state: state, extras: _extras),
            fill: Colors.black,
            // keep playing with the app in the background / the screen locked
            pauseUponEnteringBackgroundMode: false,
            onEnterFullscreen: _enterFullscreen,
            onExitFullscreen: _exitFullscreen,
          );
          if (_failed != null) {
            videoWidget = Stack(fit: StackFit.expand, children: [
              videoWidget,
              ColoredBox(
                color: Colors.black87,
                child: Center(
                  child: SingleChildScrollView(child: ErrorBox(title: 'Wiedergabe fehlgeschlagen', error: _failed!, onRetry: _retry)),
                ),
              ),
            ]);
          }
          if (sideways) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: Container(color: Colors.black, child: videoWidget)),
              if (chatOn) SizedBox(width: math.min(340.0, c.maxWidth * 0.34), child: ChatPanel(controller: _chat, onClose: _toggleChat)),
            ]);
          }
          if (wide) {
            final chatW = math.min(400.0, c.maxWidth * 0.26);
            final videoW = c.maxWidth - (chatOn ? chatW : 0);
            final videoH = math.min(videoW * 9 / 16, c.maxHeight * 0.8);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: ListView(padding: EdgeInsets.zero, children: [
                  Container(color: Colors.black, height: videoH, child: videoWidget),
                  PlayerInfo(vod: vod, onSeek: _seek, player: _player, onSetWatched: _setWatched, nerd: _extras.nerdStats),
                ]),
              ),
              if (chatOn) SizedBox(width: chatW, height: c.maxHeight, child: ChatPanel(controller: _chat, onClose: _toggleChat)),
            ]);
          }
          return DefaultTabController(
            length: 2,
            child: Column(children: [
              AspectRatio(aspectRatio: 16 / 9, child: Container(color: Colors.black, child: videoWidget)),
              Container(
                decoration: const BoxDecoration(color: C.surface, border: Border(bottom: BorderSide(color: C.border))),
                child: const TabBar(
                  indicatorColor: C.primary,
                  labelColor: C.text,
                  unselectedLabelColor: C.faint,
                  dividerColor: Colors.transparent,
                  tabs: [Tab(text: 'Chat'), Tab(text: 'Infos')],
                ),
              ),
              Expanded(
                child: TabBarView(children: [
                  ChatPanel(controller: _chat, header: false),
                  ListView(children: [PlayerInfo(vod: vod, onSeek: _seek, player: _player, onSetWatched: _setWatched, nerd: _extras.nerdStats)]),
                ]),
              ),
            ]),
          );
        }),
      );
}
