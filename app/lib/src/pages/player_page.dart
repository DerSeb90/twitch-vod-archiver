import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../player/chat_replay.dart';
import '../player/controls.dart';
import '../settings.dart';
import '../theme.dart';
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
  Timer? _tick, _saveTimer;
  final _videoKey = GlobalKey<VideoState>();

  Vod get vod => widget.vod;

  @override
  void initState() {
    super.initState();
    final saved = Settings.instance.progressMs(vod.id);
    // live: the player starts at the live edge by itself
    final start = !vod.recording && saved > 30000 && saved < vod.durationMs - 60000 ? Duration(milliseconds: saved) : Duration.zero;
    _player.setVolume(Settings.instance.volume);
    _player.open(Media(Api.instance.url(vod.video), start: start));
    _chat.init();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _chat.update(_player.state.position.inMilliseconds));
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    if (!vod.live) _loadActivity();
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

  void _saveProgress() {
    final p = _player.state.position.inMilliseconds;
    if (p < 5000) return;
    final dur = _player.state.duration.inMilliseconds > 0 ? _player.state.duration.inMilliseconds : vod.durationMs;
    if (!vod.recording && p > dur - 60000) {
      Settings.instance.clearProgress(vod.id);
    } else {
      Settings.instance.setProgress(vod.id, p);
    }
  }

  void _toggleChat() => Settings.instance.chatVisible = !Settings.instance.chatVisible;

  void _seek(int ms) {
    _player.seek(Duration(milliseconds: ms));
    _player.play();
  }

  @override
  void dispose() {
    _saveProgress();
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
          final chatOn = Settings.instance.chatVisible;
          final videoWidget = Video(
            key: _videoKey,
            controller: _video,
            controls: (state) => RewindControls(state: state, extras: _extras),
            fill: Colors.black,
          );
          if (wide) {
            final chatW = math.min(400.0, c.maxWidth * 0.26);
            final videoW = c.maxWidth - (chatOn ? chatW : 0);
            final videoH = math.min(videoW * 9 / 16, c.maxHeight * 0.8);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: ListView(padding: EdgeInsets.zero, children: [
                  Container(color: Colors.black, height: videoH, child: videoWidget),
                  _Info(vod: vod, onSeek: _seek, player: _player),
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
                  ListView(children: [_Info(vod: vod, onSeek: _seek, player: _player)]),
                ]),
              ),
            ]),
          );
        }),
      );
}

class _Info extends StatelessWidget {
  const _Info({required this.vod, required this.onSeek, required this.player});
  final Vod vod;
  final ValueChanged<int> onSeek;
  final Player player;

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
            OutlinedButton(onPressed: () => context.push('/c/${ch.login}'), child: const Text('Kanal')),
          ] else
            const Spacer(),
          const SizedBox(width: 8),
          _ViewerMenu(vod: vod),
        ]),
        const SizedBox(height: 18),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Chip(Icons.event_rounded, fmtDate(vod.startedAt, time: true)),
          _Chip(Icons.schedule_rounded, fmtDuration(vod.durationMs)),
          if (vod.category.isNotEmpty) _Chip(Icons.sports_esports_rounded, vod.category),
          if (vod.qualityLabel.isNotEmpty) _Chip(Icons.high_quality_rounded, '${vod.qualityLabel} · ${vod.videoCodec.toUpperCase()}'),
          _Chip(Icons.forum_rounded, '${fmtCount(vod.chatCount)} Nachrichten'),
          if (vod.peakViewers > 0) _Chip(Icons.visibility_rounded, 'Peak ${fmtCount(vod.peakViewers)}'),
          if (vod.sizeBytes > 0) _Chip(Icons.save_rounded, fmtBytes(vod.sizeBytes)),
        ]),
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
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
          child: const Text(
            'Tastatur: Leertaste Play/Pause · ←/→ 10 s · J/L 30 s · ↑/↓ Lautstärke · F Vollbild · M Stumm · C Chat',
            style: TextStyle(color: C.faint, fontSize: 12.5),
          ),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(30), border: Border.all(color: C.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: C.primarySoft),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        ]),
      );
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
  const _ViewerMenu({required this.vod});
  final Vod vod;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'Mehr',
        icon: const Icon(Icons.more_vert_rounded, color: C.muted),
        onSelected: (v) {
          Settings.instance.clearProgress(vod.id);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fortschritt zurückgesetzt')));
        },
        itemBuilder: (_) => const [PopupMenuItem(value: 'reset', child: Text('Als ungesehen markieren'))],
      );
}
