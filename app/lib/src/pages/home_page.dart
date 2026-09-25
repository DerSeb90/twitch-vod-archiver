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
          final phone = c.maxWidth < 600;
          return CustomScrollView(slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            if (_continue.isNotEmpty) ...[
              const SliverToBoxAdapter(child: ContentWidth(child: SectionHeader('Weiterschauen'))),
              SliverToBoxAdapter(
                child: phone
                    ? ContentWidth(child: Column(children: [for (final v in _continue.take(4)) CompactVodRow(vod: v)]))
                    : _HorizontalRow(height: 260, itemWidth: 320, count: _continue.length, builder: (i) => VodCard(vod: _continue[i])),
              ),
            ],
            // running recordings: a slim strip, not the main thing on the page
            if (_live.isNotEmpty) SliverToBoxAdapter(child: _LiveStrip(live: _live)),
            SliverToBoxAdapter(
              child: ContentWidth(
                child: SectionHeader('Aufnahmen', trailing: _loading || (_info?.vods ?? 0) == 0 ? null : ShowWatchedToggle(onChanged: _load)),
              ),
            ),
            if (_loading)
              _grid((w) => SliverGrid(
                    gridDelegate: cardGrid(w, maxItem: 340, textBlock: 78),
                    delegate: SliverChildBuilderDelegate((_, i) => const _CardSkeleton(), childCount: 8),
                  ))
            else if (vods.isEmpty)
              SliverToBoxAdapter(child: _empty())
            else
              // one block per day: heading + grid, so it's obvious what is from when
              for (final (day, items) in _byDay(vods)) ...[
                SliverToBoxAdapter(child: ContentWidth(child: _DayHeading(day: day, count: items.length))),
                _grid((w) => SliverGrid(
                      gridDelegate: cardGrid(w, maxItem: 340, textBlock: 78),
                      delegate: SliverChildBuilderDelegate((_, i) => VodCard(vod: items[i], timeOnly: true), childCount: items.length),
                    )),
              ],
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

  /// Consecutive VODs of the same local day (the list is sorted newest first).
  static List<(DateTime, List<Vod>)> _byDay(List<Vod> vods) {
    final out = <(DateTime, List<Vod>)>[];
    for (final v in vods) {
      final d = dayOf(v.startedAt);
      if (out.isEmpty || out.last.$1 != d) out.add((d, []));
      out.last.$2.add(v);
    }
    return out;
  }

  Widget _empty() {
    if (!Settings.instance.showWatched && (_info?.vods ?? 0) > 0) {
      return const EmptyState(
        icon: Icons.done_all_rounded,
        title: 'Alles gesehen',
        subtitle: 'Neue Aufnahmen erscheinen hier automatisch. Gesehene lassen sich oben rechts wieder einblenden.',
      );
    }
    return EmptyState(
      icon: Icons.video_library_rounded,
      title: 'Noch keine Aufnahmen',
      subtitle: _channels.isEmpty
          ? 'Füge in der Verwaltung einen Twitch-Kanal hinzu. Sobald er live geht, wird automatisch in bester Qualität mitgeschnitten – inklusive Chat.'
          : 'Sobald einer deiner Kanäle live geht, wird automatisch mitgeschnitten.',
      action: _channels.isEmpty
          ? FilledButton.icon(onPressed: () => context.go('/admin'), icon: const Icon(Icons.add_rounded), label: const Text('Zur Verwaltung'))
          : null,
    );
  }

  Widget _grid(Widget Function(double width) grid) => SliverLayoutBuilder(builder: (context, c) {
        final w = c.crossAxisExtent;
        final inner = w.clamp(0.0, kMaxContentWidth);
        final pad = ContentWidth.pad(inner) + (w - inner) / 2;
        return SliverPadding(padding: EdgeInsets.fromLTRB(pad, 0, pad, 8), sliver: grid(w - pad * 2));
      });
}

/// Day heading inside "Aufnahmen": "Heute", "Gestern", "Dienstag, 23. September".
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day, required this.count});
  final DateTime day;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 14),
        child: Row(children: [
          Container(width: 4, height: 18, decoration: BoxDecoration(gradient: C.brandGradient, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 10),
          Text(fmtDayHeading(day), style: const TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(width: 10),
          Text(count == 1 ? '1 Aufnahme' : '$count Aufnahmen', style: const TextStyle(color: C.faint, fontSize: 12.5)),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: C.border, height: 1)),
        ]),
      );
}

/// Horizontally scrolling row aligned with the content column.
class _HorizontalRow extends StatelessWidget {
  const _HorizontalRow({required this.height, required this.count, required this.builder, this.itemWidth});
  final double height;
  final double? itemWidth;
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
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (_, i) => itemWidth == null ? builder(i) : SizedBox(width: itemWidth, child: builder(i)),
          );
        }),
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

/// Running recordings as small pills ("● gronkh · 2:14 h · 1,2k").
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({required this.live});
  final List<LiveRecording> live;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 28),
        child: ContentWidth(
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                RecDot(size: 8),
                SizedBox(width: 6),
                Text('Gerade live', style: TextStyle(color: C.muted, fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
            for (final r in live)
              Hoverable(
                onTap: () => context.push('/c/${r.channel.login}'),
                builder: (context, hover) => AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  decoration: BoxDecoration(
                    color: hover ? C.surface2 : C.surface,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: C.live.withValues(alpha: hover ? 0.6 : 0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Avatar(src: r.channel.avatar, size: 24),
                    const SizedBox(width: 8),
                    Text(r.channel.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(width: 6),
                    Icon(r.paused ? Icons.pause_rounded : Icons.schedule_rounded, size: 13, color: C.faint),
                    const SizedBox(width: 3),
                    Text(fmtDuration(DateTime.now().millisecondsSinceEpoch - r.startedAt), style: const TextStyle(color: C.faint, fontSize: 12)),
                    if (r.viewers > 0) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.person_rounded, size: 13, color: C.faint),
                      const SizedBox(width: 2),
                      Text(fmtCount(r.viewers), style: const TextStyle(color: C.faint, fontSize: 12)),
                    ],
                  ]),
                ),
              ),
          ]),
        ),
      );
}
