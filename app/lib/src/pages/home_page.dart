import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../progress.dart';
import '../settings.dart';
import '../sync.dart';
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
    WatchProgress.instance.version.addListener(_refreshContinue);
    LiveSync.instance.vods.addListener(_vodsChanged);
  }

  bool _stale = false;

  /// VODs appeared, finished or were deleted on the server. Reloaded quietly
  /// (no skeleton); while the player is on top, once it closes.
  void _vodsChanged() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent == false) {
      _stale = true;
      return;
    }
    _load(silent: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    WatchProgress.instance.version.removeListener(_refreshContinue);
    LiveSync.instance.vods.removeListener(_vodsChanged);
    super.dispose();
  }

  Future<VodPage> _fetchContinue() => _api.vods(inProgress: true, status: 'all', limit: 12);

  static List<Vod> _continueFrom(List<Vod> vods) =>
      vods.where((v) => v.playable && WatchProgress.instance.inProgress(v) && WatchProgress.instance.resumeOf(v) > 0).toList();

  /// Progress changed (player closed, marked as watched): update "continue
  /// watching"; watched VODs drop out of the list below.
  Future<void> _refreshContinue() async {
    if (!mounted) return;
    if (_stale && ModalRoute.of(context)?.isCurrent != false) {
      _stale = false;
      return _load(silent: true);
    }
    setState(() {});
    try {
      final page = await _fetchContinue();
      if (mounted) setState(() => _continue = _continueFrom(page.items));
    } catch (_) {}
  }

  List<Vod> get _visibleVods => Settings.instance.showWatched ? _vods : _vods.where((v) => !WatchProgress.instance.watchedOf(v)).toList();

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        _api.live(),
        _api.channels(),
        _api.vods(limit: 36, unwatched: !Settings.instance.showWatched),
        _api.info(),
        _fetchContinue(),
      ]);
      final page = results[2] as VodPage;
      final cont = (results[4] as VodPage).items;
      if (!mounted) return;
      setState(() {
        _live = results[0] as List<LiveRecording>;
        _channels = results[1] as List<Channel>;
        _vods = page.items;
        _total = page.total;
        _info = results[3] as ServerInfo;
        _continue = _continueFrom(cont);
        _loading = false;
      });
    } catch (e) {
      if (silent || !mounted) return;
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
      final p = await _api.vods(limit: 36, offset: _vods.length, unwatched: !Settings.instance.showWatched);
      setState(() => _vods = [..._vods, ...p.items]);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: ErrorBox(error: _error!, onRetry: _load));
    final vods = _visibleVods;
    return RefreshIndicator(
      onRefresh: _load,
      color: C.primary,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 800) _more();
          return false;
        },
        child: LayoutBuilder(builder: (context, c) {
          // side panel next to the hero once there is room for both
          final wide = c.maxWidth >= 1100;
          final phone = c.maxWidth < 600;
          final panel = _live.isNotEmpty || _continue.isNotEmpty;
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: _loading
                      ? const _HeroSkeleton()
                      : wide
                          ? SizedBox(
                              height: 400,
                              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                Expanded(child: _Hero(vod: vods.firstOrNull, info: _info, live: _live)),
                                const SizedBox(width: 20),
                                SizedBox(
                                  width: 440,
                                  child: panel ? _SidePanel(live: _live, cont: _continue) : _ChannelPanel(channels: _channels),
                                ),
                              ]),
                            )
                          : _Hero(vod: vods.firstOrNull, info: _info, live: _live),
                ),
              ),
            ),
            if (!wide && _live.isNotEmpty)
              ..._section(
                'Gerade live',
                leading: const RecDot(size: 10),
                trailing: Text('${_live.length} / ${_info?.maxConcurrent ?? 3}', style: const TextStyle(color: C.muted)),
                grid: (w) => SliverGrid(
                  gridDelegate: cardGrid(w, maxItem: 460, textBlock: 76),
                  delegate: SliverChildBuilderDelegate((_, i) => LiveCard(rec: _live[i]), childCount: _live.length),
                ),
              ),
            if (phone && _continue.isNotEmpty) ...[
              const SliverToBoxAdapter(child: ContentWidth(child: SectionHeader('Weiterschauen'))),
              SliverToBoxAdapter(
                child: ContentWidth(child: Column(children: [for (final v in _continue.take(4)) CompactVodRow(vod: v)])),
              ),
            ] else if (!wide && _continue.isNotEmpty) ...[
              const SliverToBoxAdapter(child: ContentWidth(child: SectionHeader('Weiterschauen'))),
              SliverToBoxAdapter(
                child: _HorizontalRow(
                  height: 250,
                  itemWidth: 300,
                  count: _continue.length,
                  builder: (i) => VodCard(vod: _continue[i]),
                ),
              ),
            ],
            if (_channels.isNotEmpty && (!wide || panel)) ...[
              SliverToBoxAdapter(
                child: ContentWidth(
                  child: SectionHeader('Kanäle', trailing: TextButton(onPressed: () => context.go('/channels'), child: const Text('Alle anzeigen'))),
                ),
              ),
              SliverToBoxAdapter(
                child: _HorizontalRow(
                  height: ChannelChip.height,
                  count: _channels.length,
                  gap: 12,
                  builder: (i) => ChannelChip(channel: _channels[i]),
                ),
              ),
            ],
            ..._section(
              'Neueste Aufnahmen',
              trailing: _channels.isEmpty ? null : ShowWatchedToggle(onChanged: _load),
              grid: (w) {
                if (_loading) {
                  return SliverGrid(
                    gridDelegate: cardGrid(w, maxItem: 340, textBlock: 78),
                    delegate: SliverChildBuilderDelegate((_, i) => const _CardSkeleton(), childCount: 10),
                  );
                }
                if (vods.isEmpty && !Settings.instance.showWatched && (_info?.vods ?? 0) > 0) {
                  return const SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.done_all_rounded,
                      title: 'Alles gesehen',
                      subtitle: 'Neue Aufnahmen erscheinen hier automatisch. Gesehene lassen sich oben rechts wieder einblenden.',
                    ),
                  );
                }
                if (vods.isEmpty) {
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
                  gridDelegate: cardGrid(w, maxItem: 340, textBlock: 78),
                  delegate: SliverChildBuilderDelegate((_, i) => VodCard(vod: vods[i]), childCount: vods.length),
                );
              },
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(child: _loadingMore ? const CircularProgressIndicator(color: C.primary) : const SizedBox.shrink()),
              ),
            ),
          ]);
        }),
      ),
    );
  }

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

/// Horizontally scrolling row aligned with the content column.
class _HorizontalRow extends StatelessWidget {
  const _HorizontalRow({required this.height, required this.count, required this.builder, this.itemWidth, this.gap = 16});
  final double height;
  final double? itemWidth;
  final double gap;
  final int count;
  final Widget Function(int i) builder;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: LayoutBuilder(builder: (context, c) {
          final pad = ContentWidth.pad(c.maxWidth.clamp(0, kMaxContentWidth));
          final extra = ((c.maxWidth - kMaxContentWidth) / 2).clamp(0.0, double.infinity);
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad + extra),
            itemCount: count,
            separatorBuilder: (_, _) => SizedBox(width: gap),
            itemBuilder: (_, i) => itemWidth == null ? builder(i) : SizedBox(width: itemWidth, child: builder(i)),
          );
        }),
      );
}

/// Featured recording: newest one not watched yet.
class _Hero extends StatelessWidget {
  const _Hero({required this.vod, required this.info, required this.live});
  final Vod? vod;
  final ServerInfo? info;
  final List<LiveRecording> live;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final v = vod;
    return Hoverable(
      onTap: v == null ? null : () => context.push('/v/${v.id}'),
      builder: (context, hover) => Container(
        height: compact ? 280 : (MediaQuery.sizeOf(context).width < 1100 ? 340 : 400),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: hover ? C.primary.withValues(alpha: 0.5) : C.border),
        ),
        child: Stack(fit: StackFit.expand, children: [
          if (v != null)
            AnimatedScale(
              scale: hover ? 1.03 : 1,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              child: Opacity(opacity: 0.75, child: NetImg(v.thumbnail, cacheWidth: 1600)),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xCC09090B), Color(0xF209090B)], stops: [0.25, 0.75, 1]),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [Color(0xCC09090B), Color(0x0009090B)], stops: [0, 0.7]),
            ),
          ),
          if (v == null)
            Positioned(
              left: -120,
              top: -160,
              child: Container(
                width: 520,
                height: 520,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [C.primary.withValues(alpha: 0.28), Colors.transparent])),
              ),
            ),
          Padding(
            padding: EdgeInsets.all(compact ? 20 : 32),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (v == null) ...[
                const GradientText('Dein Stream-Archiv.', style: TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 34, letterSpacing: -1)),
                const SizedBox(height: 12),
                const Text('Livestreams in Originalqualität – mit komplettem Chat-Replay.', style: TextStyle(color: C.muted, fontSize: 16)),
              ] else ...[
                Row(children: [
                  const Pill('NEU', color: C.primary),
                  const SizedBox(width: 8),
                  Text(fmtRelative(v.startedAt), style: const TextStyle(color: C.muted, fontWeight: FontWeight.w500)),
                ]),
                const SizedBox(height: 10),
                Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontSize: compact ? 22 : 30, height: 1.15)),
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
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => context.push('/v/${v.id}'),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Jetzt ansehen'),
                ),
              ],
              if (info != null && !compact) ...[
                const SizedBox(height: 22),
                _Stats(info: info!, live: live.length),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Right of the hero: live recordings and "continue watching".
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.live, required this.cont});
  final List<LiveRecording> live;
  final List<Vod> cont;

  @override
  Widget build(BuildContext context) {
    Widget header(String t, {Widget? leading}) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            if (leading != null) ...[leading, const SizedBox(width: 8)],
            Text(t, style: const TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
      child: ListView(padding: EdgeInsets.zero, children: [
        if (live.isNotEmpty) ...[
          header('Gerade live', leading: const RecDot(size: 9)),
          for (final l in live) CompactLiveRow(rec: l),
          if (cont.isNotEmpty) const SizedBox(height: 12),
        ],
        if (cont.isNotEmpty) ...[
          header('Weiterschauen'),
          for (final v in cont) CompactVodRow(vod: v),
        ],
      ]),
    );
  }
}

/// Right of the hero when nothing is live or started: the channels.
class _ChannelPanel extends StatelessWidget {
  const _ChannelPanel({required this.channels});
  final List<Channel> channels;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
            child: Row(children: [
              const Text('Kanäle', style: TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 16)),
              const Spacer(),
              TextButton(onPressed: () => context.go('/channels'), child: const Text('Alle')),
            ]),
          ),
          Expanded(
            child: channels.isEmpty
                ? const Center(child: Text('Noch keine Kanäle', style: TextStyle(color: C.faint)))
                : ListView(padding: EdgeInsets.zero, children: [for (final c in channels) ChannelRow(channel: c)]),
          ),
        ]),
      );
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
            Text(value, style: const TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 16)),
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
  Widget build(BuildContext context) => const Skeleton(height: 400, radius: 20);
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
