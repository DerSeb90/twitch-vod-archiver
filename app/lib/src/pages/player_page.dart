import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../player/background.dart';
import '../player/chat_replay.dart';
import '../player/controls.dart';
import '../player/native_options.dart';
import '../progress.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

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
  }

  Future<void> _load() async {
    try {
      final v = await Api.instance.vod(widget.id);
      setState(() => _vod = v);
    } catch (e) {
      setState(() => _error = e);
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
          subtitle: _vod!.status == 'failed' ? 'Verarbeitung fehlgeschlagen: ${_vod!.error}' : 'Das VOD ist abspielbar, sobald die Verarbeitung abgeschlossen ist.',
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

class _PlayerState extends State<_Player> {
  late final Player _player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024, title: 'rewind'));
  late final VideoController _video = VideoController(_player);
  late final ChatReplayController _chat = ChatReplayController(widget.vod);
  late final PlayerExtras _extras = PlayerExtras(vod: widget.vod, onToggleChat: _toggleChat);
  Timer? _tick, _saveTimer, _liveTimer;
  StreamSubscription<bool>? _completedSub;
  final _videoKey = GlobalKey<VideoState>();

  /// Last position sent to the server; whether this session marked it watched.
  int _savedMs = -1;
  bool _watched = false;

  /// Set after "mark (un)watched" in the menu: from then on this session no
  /// longer saves, so it can't undo the manual choice.
  bool _manual = false;

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
    _completedSub = _player.stream.completed.listen((done) {
      if (done && !vod.growing) _markWatched();
    });
    if (!vod.live) _loadActivity();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    if (vod.live) await startLivePlaylistsAtZero(_player);
    final media = Api.instance.url(vod.video);
    if (vod.growing) {
      await _player.open(Media(media));
      _seekOnceStarted(() => start > Duration.zero ? start.inMilliseconds : _extras.liveDurationMs.value - 10000);
      _liveTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
        try {
          _extras.liveDurationMs.value = (await Api.instance.vod(vod.id)).durationMs;
        } catch (_) {}
      });
    } else if (start == Duration.zero) {
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

  /// Seeks as soon as playback is actually running (earlier seeks are dropped
  /// by the players while the playlist is still loading).
  void _seekOnceStarted(int Function() targetMs) {
    StreamSubscription<Duration>? sub;
    sub = _player.stream.position.listen((p) {
      if (p < const Duration(milliseconds: 500)) return;
      sub?.cancel();
      final target = targetMs();
      if ((target - p.inMilliseconds).abs() > 3000) _player.seek(Duration(milliseconds: math.max(0, target)));
    });
  }

  Future<void> _loadActivity() async {
    try {
      final j = await Api.instance.mediaJson('${vod.base}chat/activity.json') as Map<String, dynamic>;
      setState(() {
        _extras.activity = [for (final c in j['counts'] as List) (c as num).toInt()];
        _extras.activityBucketMs = (j['bucketMs'] as num).toInt();
      });
    } catch (_) {}
  }

  void _saveProgress({bool closing = false}) {
    if (_manual) return;
    final p = _player.state.position.inMilliseconds;
    final dur = _player.state.duration.inMilliseconds > 0 ? _player.state.duration.inMilliseconds : vod.durationMs;
    if (!vod.growing && p > WatchProgress.resumeMinMs && p >= dur - WatchProgress.endMarginMs) {
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
    _player.seek(Duration(milliseconds: ms));
    _player.play();
  }

  @override
  void dispose() {
    _saveProgress(closing: true);
    BackgroundPlayback.detach(_player);
    _completedSub?.cancel();
    _tick?.cancel();
    _saveTimer?.cancel();
    _liveTimer?.cancel();
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
          final videoWidget = Video(
            key: _videoKey,
            controller: _video,
            controls: (state) => RewindControls(state: state, extras: _extras),
            fill: Colors.black,
            // keep playing with the app in the background / the screen locked
            pauseUponEnteringBackgroundMode: false,
            onEnterFullscreen: _enterFullscreen,
            onExitFullscreen: _exitFullscreen,
          );
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
                  _Info(vod: vod, onSeek: _seek, player: _player, onSetWatched: _setWatched, nerd: _extras.nerdStats),
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
                  ListView(children: [_Info(vod: vod, onSeek: _seek, player: _player, onSetWatched: _setWatched, nerd: _extras.nerdStats)]),
                ]),
              ),
            ]),
          );
        }),
      );
}

class _Info extends StatelessWidget {
  const _Info({required this.vod, required this.onSeek, required this.player, required this.onSetWatched, required this.nerd});
  final Vod vod;
  final ValueChanged<int> onSeek;
  final Player player;
  final ValueChanged<bool> onSetWatched;
  final ValueNotifier<bool> nerd;

  @override
  Widget build(BuildContext context) {
    final ch = vod.channel;
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 28, 22, compact ? 16 : 28, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(vod.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: compact ? 19 : 24, height: 1.25)),
        const SizedBox(height: 16),
        Row(children: [
          if (ch != null) ...[
            GestureDetector(onTap: () => context.push('/c/${ch.login}'), child: Avatar(src: ch.avatar, size: 44, live: ch.live)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ch.displayName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                Text('${ch.vodCount} Aufnahmen', style: const TextStyle(color: C.faint, fontSize: 12.5)),
              ]),
            ),
            if (!compact) OutlinedButton(onPressed: () => context.push('/c/${ch.login}'), child: const Text('Kanal')),
          ] else
            const Spacer(),
          const SizedBox(width: 8),
          ValueListenableBuilder<int>(
            valueListenable: WatchProgress.instance.version,
            builder: (context, _, _) {
              final watched = WatchProgress.instance.watchedOf(vod);
              return Tooltip(
                message: watched ? 'Als ungesehen markieren' : 'Als gesehen markieren',
                child: watched
                    ? FilledButton.tonalIcon(
                        onPressed: () => onSetWatched(false),
                        style: FilledButton.styleFrom(backgroundColor: C.success.withValues(alpha: 0.18), foregroundColor: C.success),
                        icon: const Icon(Icons.check_circle_rounded, size: 18),
                        label: const Text('Gesehen'),
                      )
                    : OutlinedButton.icon(
                        onPressed: () => onSetWatched(true),
                        icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                        label: const Text('Gesehen'),
                      ),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: nerd,
            builder: (_, on, _) => IconButton(
              tooltip: 'Statistiken für Nerds (I)',
              onPressed: () => nerd.value = !on,
              icon: Icon(Icons.query_stats_rounded, color: on ? C.primarySoft : C.muted),
            ),
          ),
          _ViewerMenu(vod: vod, onSetWatched: onSetWatched),
        ]),
        const SizedBox(height: 18),
        _Details(vod: vod),
        if (vod.chapters.length > 1) ...[
          const SizedBox(height: 28),
          Text('Kapitel', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SizedBox(
            height: 92,
            child: StreamBuilder<Duration>(
              stream: player.stream.position,
              builder: (context, _) {
                final pos = player.state.position.inMilliseconds;
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: vod.chapters.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final c = vod.chapters[i];
                    final end = i + 1 < vod.chapters.length ? vod.chapters[i + 1].offsetMs : vod.durationMs;
                    final active = pos >= c.offsetMs && pos < end;
                    return _ChapterCard(chapter: c, lengthMs: end - c.offsetMs, active: active, onTap: () => onSeek(c.offsetMs));
                  },
                );
              },
            ),
          ),
        ],
        if (!compact) ...[
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
            child: const Text(
              'Tastatur: Leertaste Play/Pause · ←/→ 10 s · J/L 30 s · ↑/↓ Lautstärke · F Vollbild · M Stumm · C Chat · I Statistiken · Doppelklick Vollbild',
              style: TextStyle(color: C.faint, fontSize: 12.5),
            ),
          ),
        ] else ...[
          const SizedBox(height: 20),
          const Text('Doppelt tippen links/rechts: 10 s zurück/vor · Handy quer: Vollbild', style: TextStyle(color: C.faint, fontSize: 12.5)),
        ],
      ]),
    );
  }
}

/// Facts about the recording as small tiles with icons.
class _Details extends StatelessWidget {
  const _Details({required this.vod});
  final Vod vod;

  @override
  Widget build(BuildContext context) {
    final mins = vod.durationMs / 60000;
    final mbit = vod.sizeBytes > 0 && vod.durationMs > 0 ? vod.sizeBytes * 8 / (vod.durationMs / 1000) / 1e6 : 0.0;
    final tiles = <(IconData, String, String)>[
      (Icons.play_circle_outline_rounded, 'Gestartet', fmtWhen(vod.startedAt)),
      if (vod.endedAt > 0) (Icons.stop_circle_outlined, 'Beendet', fmtWhen(vod.endedAt)),
      (Icons.schedule_rounded, 'Länge', fmtDuration(vod.durationMs)),
      if (vod.category.isNotEmpty) (Icons.sports_esports_rounded, 'Kategorie', vod.category),
      if (vod.height > 0) (Icons.high_quality_rounded, 'Video', '${vod.width}×${vod.height} · ${vod.fps.round()} fps'),
      if (vod.videoCodec.isNotEmpty) (Icons.memory_rounded, 'Codec', vod.videoCodec.toUpperCase()),
      if (mbit > 0) (Icons.speed_rounded, 'Ø Bitrate', '${mbit.toStringAsFixed(1).replaceAll('.', ',')} Mbit/s'),
      if (vod.sizeBytes > 0) (Icons.save_rounded, 'Größe', fmtBytes(vod.sizeBytes)),
      (Icons.forum_rounded, 'Chat', mins > 1 ? '${fmtCount(vod.chatCount)} · Ø ${(vod.chatCount / mins).toStringAsFixed(vod.chatCount / mins < 10 ? 1 : 0).replaceAll('.', ',')}/min' : fmtCount(vod.chatCount)),
      if (vod.peakViewers > 0) (Icons.visibility_rounded, 'Peak-Zuschauer', fmtCount(vod.peakViewers)),
      if (vod.chapters.length > 1) (Icons.bookmarks_rounded, 'Kapitel', '${vod.chapters.length}'),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / 210).floor().clamp(2, 5);
      final w = (c.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (icon, label, value) in tiles)
          Container(
            width: w,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
            child: Row(children: [
              Icon(icon, size: 18, color: C.primarySoft),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(color: C.faint, fontSize: 11.5)),
                  const SizedBox(height: 1),
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ]),
              ),
            ]),
          ),
      ]);
    });
  }
}

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({required this.chapter, required this.lengthMs, required this.active, required this.onTap});
  final Chapter chapter;
  final int lengthMs;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: onTap,
        builder: (context, hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 260,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: active ? C.primary.withValues(alpha: 0.14) : (hover ? C.surface2 : C.surface),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? C.primary : C.border),
          ),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(width: 54, height: 72, child: NetImg(chapter.boxArt, cacheWidth: 160)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(chapter.category.isEmpty ? 'Unbekannt' : chapter.category, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
                const SizedBox(height: 4),
                Text('${fmtDuration(chapter.offsetMs)} · ${fmtHours(lengthMs)}', style: const TextStyle(color: C.faint, fontSize: 11.5)),
              ]),
            ),
          ]),
        ),
      );
}

class _ViewerMenu extends StatelessWidget {
  const _ViewerMenu({required this.vod, required this.onSetWatched});
  final Vod vod;
  final ValueChanged<bool> onSetWatched;

  @override
  Widget build(BuildContext context) => PopupMenuButton<bool>(
        tooltip: 'Mehr',
        icon: const Icon(Icons.more_vert_rounded, color: C.muted),
        onSelected: onSetWatched,
        itemBuilder: (_) => watchedMenuItems(vod),
      );
}
