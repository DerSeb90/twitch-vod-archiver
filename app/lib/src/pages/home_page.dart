import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = Api.instance;
  List<LiveRecording> _live = [];
  List<Channel> _channels = [];
  List<Vod> _vods = [];
  List<Vod> _continue = [];
  ServerInfo? _info;
  int _total = 0;
  Object? _error;
  bool _loading = true, _loadingMore = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _refreshLive());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final recent = Settings.instance.recentlyWatched.take(12).toList();
      final results = await Future.wait([
        _api.live(),
        _api.channels(),
        _api.vods(limit: 36),
        _api.info(),
        if (recent.isNotEmpty) _api.vods(ids: recent, limit: 12),
      ]);
      final page = results[2] as VodPage;
      final cont = recent.isEmpty ? <Vod>[] : (results[4] as VodPage).items;
      cont.sort((a, b) => recent.indexOf(a.id).compareTo(recent.indexOf(b.id)));
      setState(() {
        _live = results[0] as List<LiveRecording>;
        _channels = results[1] as List<Channel>;
        _vods = page.items;
        _total = page.total;
        _info = results[3] as ServerInfo;
        _continue = cont.where((v) {
          final p = Settings.instance.progressMs(v.id);
          return p > 0 && p < v.durationMs - 60000;
        }).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _refreshLive() async {
    try {
      final l = await _api.live();
      if (mounted) setState(() => _live = l);
    } catch (_) {}
  }

  Future<void> _more() async {
    if (_loadingMore || _vods.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final p = await _api.vods(limit: 36, offset: _vods.length);
      setState(() => _vods = [..._vods, ...p.items]);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: ErrorBox(error: _error!, onRetry: _load));
    return RefreshIndicator(
      onRefresh: _load,
      color: C.primary,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 800) _more();
          return false;
        },
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: _loading ? const _HeroSkeleton() : _Hero(vod: _vods.firstOrNull, info: _info, live: _live)),
          if (_live.isNotEmpty) ..._section(
            'Gerade live',
            leading: const RecDot(size: 10),
            trailing: Text('${_live.length} / ${_info?.maxConcurrent ?? 3} Aufnahmen', style: const TextStyle(color: C.muted)),
            grid: (w) => SliverGrid(
              gridDelegate: cardGrid(w, maxItem: 460, textBlock: 76),
              delegate: SliverChildBuilderDelegate((_, i) => LiveCard(rec: _live[i]), childCount: _live.length),
            ),
          ),
          if (_continue.isNotEmpty) ..._section(
            'Weiterschauen',
            grid: (w) => SliverGrid(
              gridDelegate: cardGrid(w),
              delegate: SliverChildBuilderDelegate((_, i) => VodCard(vod: _continue[i]), childCount: _continue.length.clamp(0, _colsFor(w))),
            ),
          ),
          if (_channels.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: ContentWidth(
                child: SectionHeader('Kanäle',
                    trailing: TextButton(onPressed: () => context.go('/channels'), child: const Text('Alle anzeigen'))),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 140,
                child: LayoutBuilder(builder: (context, c) {
                  final pad = ContentWidth.pad(c.maxWidth.clamp(0, kMaxContentWidth));
                  final extra = ((c.maxWidth - kMaxContentWidth) / 2).clamp(0.0, double.infinity);
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: pad + extra),
                    itemCount: _channels.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) => ChannelTile(channel: _channels[i], size: 80),
                  );
                }),
              ),
            ),
          ],
          ..._section(
            'Neueste Aufnahmen',
            trailing: _total > 0 ? Text('$_total VODs', style: const TextStyle(color: C.muted)) : null,
            grid: (w) {
              if (_loading) {
                return SliverGrid(
                  gridDelegate: cardGrid(w),
                  delegate: SliverChildBuilderDelegate((_, i) => const _CardSkeleton(), childCount: 8),
                );
              }
              if (_vods.isEmpty) {
                return SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.video_library_rounded,
                    title: 'Noch keine Aufnahmen',
                    subtitle: _channels.isEmpty
                        ? 'Füge in der Verwaltung einen Twitch-Kanal hinzu. Sobald er live geht, wird automatisch in bester Qualität mitgeschnitten – inklusive Chat.'
                        : 'Sobald einer deiner Kanäle live geht, wird automatisch mitgeschnitten.',
                    action: _channels.isEmpty
                        ? FilledButton.icon(onPressed: () => context.go('/admin'), icon: const Icon(Icons.add_rounded), label: const Text('Zur Verwaltung'))
                        : null,
                  ),
                );
              }
              return SliverGrid(
                gridDelegate: cardGrid(w),
                delegate: SliverChildBuilderDelegate((_, i) => VodCard(vod: _vods[i]), childCount: _vods.length),
              );
            },
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: _loadingMore ? const CircularProgressIndicator(color: C.primary) : const SizedBox.shrink()),
            ),
          ),
        ]),
      ),
    );
  }

  int _colsFor(double w) => (w / 380).ceil();

  List<Widget> _section(String title, {Widget? leading, Widget? trailing, required Widget Function(double width) grid}) => [
        SliverToBoxAdapter(child: ContentWidth(child: SectionHeader(title, leading: leading, trailing: trailing))),
        SliverLayoutBuilder(builder: (context, c) {
          final w = c.crossAxisExtent;
          final inner = w.clamp(0.0, kMaxContentWidth);
          final pad = ContentWidth.pad(inner) + (w - inner) / 2;
          return SliverPadding(padding: EdgeInsets.symmetric(horizontal: pad), sliver: grid(w - pad * 2));
        }),
      ];
}

class _Hero extends StatelessWidget {
  const _Hero({required this.vod, required this.info, required this.live});
  final Vod? vod;
  final ServerInfo? info;
  final List<LiveRecording> live;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final compact = w < 760;
    final v = vod;
    return SizedBox(
      height: compact ? 300 : 340,
      child: Stack(fit: StackFit.expand, children: [
        if (v != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 0.5, sigmaY: 0.5),
            child: Opacity(opacity: 0.55, child: NetImg(v.thumbnail, cacheWidth: 1920)),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x55090909), Color(0xCC09090B), C.bg], stops: [0, 0.65, 1]),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [Color(0xEE09090B), Color(0x0009090B)], stops: [0.1, 0.8]),
          ),
        ),
        // ambient glow
        Positioned(
          left: -120,
          top: -160,
          child: Container(
            width: 520,
            height: 520,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [C.primary.withValues(alpha: 0.28), Colors.transparent])),
          ),
        ),
        ContentWidth(
          child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (v == null) ...[
              const GradientText('Dein Stream-Archiv.', style: TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 34, letterSpacing: -1)),
              const SizedBox(height: 12),
              const Text('Livestreams in Originalqualität – mit komplettem Chat-Replay.', style: TextStyle(color: C.muted, fontSize: 16)),
            ] else ...[
              Row(children: [
                const Pill('NEUESTE AUFNAHME', color: C.primary),
                const SizedBox(width: 8),
                Text(fmtRelative(v.startedAt), style: const TextStyle(color: C.muted, fontWeight: FontWeight.w500)),
              ]),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Text(v.title, maxLines: compact ? 2 : 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontSize: compact ? 22 : 30)),
              ),
              const SizedBox(height: 10),
              Row(children: [
                if (v.channel != null) ...[
                  Avatar(src: v.channel!.avatar, size: 28, live: v.channel!.live),
                  const SizedBox(width: 8),
                  Text(v.channel!.displayName, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Text('  ·  ', style: TextStyle(color: C.faint)),
                ],
                Flexible(
                  child: Text([fmtDuration(v.durationMs), if (v.category.isNotEmpty) v.category, if (v.qualityLabel.isNotEmpty) v.qualityLabel].join('  ·  '),
                      overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted)),
                ),
              ]),
              const SizedBox(height: 16),
              Wrap(spacing: 10, runSpacing: 10, children: [
                FilledButton.icon(
                  onPressed: () => context.push('/v/${v.id}'),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Jetzt ansehen'),
                ),
                if (v.channel != null)
                  OutlinedButton(onPressed: () => context.push('/c/${v.channel!.login}'), child: const Text('Zum Kanal')),
              ]),
            ],
            const SizedBox(height: 20),
            if (info != null && !compact) _Stats(info: info!, live: live.length),
            const SizedBox(height: 4),
          ]),
        ),
      ]),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.info, required this.live});
  final ServerInfo info;
  final int live;

  @override
  Widget build(BuildContext context) {
    Widget stat(String value, String label) => Padding(
          padding: const EdgeInsets.only(right: 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: const TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 17)),
            Text(label, style: const TextStyle(color: C.faint, fontSize: 12)),
          ]),
        );
    return Wrap(runSpacing: 12, children: [
      stat('${info.vods}', 'Aufnahmen'),
      stat(fmtHours(info.totalMs), 'Material'),
      stat(fmtCount(info.chatCount), 'Chat-Nachrichten'),
      stat(fmtBytes(info.totalBytes), 'Archiv'),
      if (live > 0) stat('$live', 'Live-Aufnahmen'),
    ]);
  }
}

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 320,
        child: ContentWidth(
          child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Skeleton(width: 160, height: 22, radius: 6),
            SizedBox(height: 16),
            Skeleton(width: 560, height: 44, radius: 8),
            SizedBox(height: 14),
            Skeleton(width: 300, height: 18, radius: 6),
            SizedBox(height: 60),
          ]),
        ),
      );
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();
  @override
  Widget build(BuildContext context) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Skeleton(aspectRatio: 16 / 9),
        SizedBox(height: 12),
        Skeleton(height: 14, radius: 4),
        SizedBox(height: 8),
        Skeleton(height: 12, width: 160, radius: 4),
      ]);
}
