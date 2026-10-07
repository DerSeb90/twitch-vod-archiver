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
import '../widgets/shell.dart';

/// Start page: "continue watching", running recordings, then one row per
/// channel with its newest recordings (the channel with the newest first).
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RouteAware {
  final _api = Api.instance;
  List<LiveRecording> _live = [];
  List<Channel> _channels = [];
  List<Vod> _continue = [];
  List<ChannelVods> _latest = [];
  ServerInfo? _info;
  Object? _error;
  bool _loading = true;
  Timer? _poll, _progressTimer;

  /// VODs per channel row ("Alle" opens the channel for the rest).
  static const _perChannel = 10;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _refreshLive());
    WatchProgress.instance.version.addListener(_progressChanged);
    ServerSync.instance.vods.addListener(_vodsChanged);
  }

  bool _stale = false;
  PageRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) shellRouteObserver.unsubscribe(this);
      _route = route;
      shellRouteObserver.subscribe(this, route);
    }
  }

  /// VODs appeared, finished or were deleted on the server. Reloaded quietly
  /// (no skeleton); while another page (the player) is on top, once it closes.
  void _vodsChanged() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent == false) {
      _stale = true;
      return;
    }
    _load(silent: true);
  }

  @override
  void didPopNext() {
    if (!_stale) return;
    _stale = false;
    _load(silent: true);
  }

  @override
  void dispose() {
    shellRouteObserver.unsubscribe(this);
    _poll?.cancel();
    _progressTimer?.cancel();
    WatchProgress.instance.version.removeListener(_progressChanged);
    ServerSync.instance.vods.removeListener(_vodsChanged);
    super.dispose();
  }

  Future<VodPage> _fetchContinue() =>
      _api.vods(inProgress: true, status: 'all', limit: 12);

  Future<List<ChannelVods>> _fetchLatest() => _api.latest(
    limit: _perChannel,
    unwatched: !Settings.instance.showWatched,
  );

  static List<Vod> _continueFrom(List<Vod> vods) => vods
      .where(
        (v) =>
            v.playable &&
            WatchProgress.instance.inProgress(v) &&
            WatchProgress.instance.resumeOf(v) > 0,
      )
      .toList();

  /// Progress changed (player closed, marked as watched): watched VODs drop
  /// out of the rows at once; once the changes settle, the rows (refilled,
  /// counts updated) and "continue watching" are fetched again.
  void _progressChanged() {
    if (!mounted) return;
    setState(() {});
    _progressTimer?.cancel();
    _progressTimer = Timer(const Duration(seconds: 1), _refreshLists);
  }

  Future<void> _refreshLists() async {
    if (!mounted) return;
    try {
      final r = await Future.wait([_fetchContinue(), _fetchLatest()]);
      if (!mounted) return;
      setState(() {
        _continue = _continueFrom((r[0] as VodPage).items);
        _latest = r[1] as List<ChannelVods>;
      });
    } catch (_) {}
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        _api.recordings(),
        _api.channels(),
        _fetchLatest(),
        _api.info(),
        _fetchContinue(),
      ]);
      if (!mounted) return;
      setState(() {
        _live = results[0] as List<LiveRecording>;
        _channels = results[1] as List<Channel>;
        _latest = results[2] as List<ChannelVods>;
        _info = results[3] as ServerInfo;
        _continue = _continueFrom((results[4] as VodPage).items);
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
      final l = await _api.recordings();
      if (mounted) setState(() => _live = l);
    } catch (_) {}
  }

  /// Channel rows as shown: VODs marked watched since loading drop out
  /// (unless watched ones are shown) and rows left empty disappear.
  List<({Channel channel, List<Vod> vods, int count})> get _rows {
    final showWatched = Settings.instance.showWatched;
    final rows = <({Channel channel, List<Vod> vods, int count})>[];
    for (final g in _latest) {
      final vods = showWatched
          ? g.items
          : g.items.where((v) => !WatchProgress.instance.watchedOf(v)).toList();
      if (vods.isEmpty) continue;
      rows.add((
        channel: g.channel,
        vods: vods,
        count: g.total - (g.items.length - vods.length),
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: ErrorBox(error: _error!, onRetry: _load),
      );
    }
    final rows = _rows;
    final showWatched = Settings.instance.showWatched;
    final liveIds = {for (final l in _live) l.channel.id};
    return RefreshIndicator(
      onRefresh: _load,
      color: C.primary,
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          if (_continue.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: ContentWidth(child: SectionHeader('Weiterschauen')),
            ),
            SliverToBoxAdapter(
              child: CardRow(
                children: [for (final v in _continue) VodCard(vod: v)],
              ),
            ),
          ],
          // running recordings: a slim strip, not the main thing on the page
          if (_live.isNotEmpty)
            SliverToBoxAdapter(child: _LiveStrip(live: _live)),
          SliverToBoxAdapter(
            child: ContentWidth(
              child: SectionHeader(
                showWatched ? 'Aufnahmen' : 'Neue Aufnahmen',
                trailing: _loading || (_info?.vods ?? 0) == 0
                    ? null
                    : ShowWatchedToggle(onChanged: _load),
              ),
            ),
          ),
          if (_loading)
            for (var i = 0; i < 2; i++)
              const SliverToBoxAdapter(child: _ChannelRowSkeleton())
          else if (rows.isEmpty)
            SliverToBoxAdapter(child: _empty())
          else
            for (final r in rows)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ChannelHeader(
                        channel: r.channel,
                        live: liveIds.contains(r.channel.id),
                        count: showWatched
                            ? (r.count == 1
                                  ? '1 Aufnahme'
                                  : '${r.count} Aufnahmen')
                            : '${r.count} neu',
                        highlight: !showWatched,
                      ),
                      CardRow(
                        children: [
                          for (final v in r.vods)
                            VodCard(vod: v, showChannel: false),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
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
          ? FilledButton.icon(
              onPressed: () => context.go('/admin'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Zur Verwaltung'),
            )
          : null,
    );
  }
}

/// Heading of a channel's row: avatar, name, how many there are, whether it
/// is being recorded right now and "Alle" (the channel page).
class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.channel,
    required this.live,
    required this.count,
    required this.highlight,
  });
  final Channel channel;
  final bool live;
  final String count;

  /// A count of new ones (accent colour) rather than of all.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    void open() => context.push('/c/${channel.login}');
    final phone = MediaQuery.sizeOf(context).width < 600;
    return ContentWidth(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Hoverable(
                  onTap: open,
                  builder: (context, hover) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(
                        src: channel.avatar,
                        size: phone ? 38 : 44,
                        live: live,
                      ),
                      SizedBox(width: phone ? 10 : 14),
                      Flexible(
                        child: Text(
                          channel.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontSize: phone ? 19 : 22,
                                color: hover ? C.primarySoft : C.text,
                              ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _CountBadge(count, highlight: highlight),
                      if (live) ...[
                        const SizedBox(width: 10),
                        const Tooltip(
                          message: 'Wird gerade aufgenommen',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RecDot(size: 7),
                              SizedBox(width: 5),
                              Text(
                                'LIVE',
                                style: TextStyle(
                                  color: C.live,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: open,
              style: TextButton.styleFrom(
                foregroundColor: C.muted,
                visualDensity: VisualDensity.compact,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Alle'),
                  SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.text, {required this.highlight});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: highlight ? C.primary.withValues(alpha: 0.18) : C.surface2,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: highlight ? C.primary.withValues(alpha: 0.45) : C.border,
      ),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: highlight ? C.primarySoft : C.muted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _ChannelRowSkeleton extends StatelessWidget {
  const _ChannelRowSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ContentWidth(
          child: Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Skeleton(width: 44, height: 44, radius: 22),
                SizedBox(width: 14),
                Skeleton(width: 160, height: 20, radius: 4),
              ],
            ),
          ),
        ),
        CardRow(children: [for (var i = 0; i < 6; i++) const _CardSkeleton()]),
      ],
    ),
  );
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();
  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Skeleton(aspectRatio: 16 / 9),
      SizedBox(height: 12),
      Skeleton(height: 14, radius: 4),
      SizedBox(height: 8),
      Skeleton(height: 12, width: 160, radius: 4),
    ],
  );
}

/// Running recordings as small pills ("● gronkh · 2:14 h · 1,2k").
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({required this.live});
  final List<LiveRecording> live;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: ContentWidth(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RecDot(size: 8),
                SizedBox(width: 6),
                Text(
                  'Gerade live',
                  style: TextStyle(
                    color: C.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
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
                  border: Border.all(
                    color: C.live.withValues(alpha: hover ? 0.6 : 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Avatar(src: r.channel.avatar, size: 24),
                    const SizedBox(width: 8),
                    Text(
                      r.channel.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      r.paused ? Icons.pause_rounded : Icons.schedule_rounded,
                      size: 13,
                      color: C.faint,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      fmtDuration(
                        DateTime.now().millisecondsSinceEpoch - r.startedAt,
                      ),
                      style: const TextStyle(color: C.faint, fontSize: 12),
                    ),
                    if (r.viewers > 0) ...[
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.person_rounded,
                        size: 13,
                        color: C.faint,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        fmtCount(r.viewers),
                        style: const TextStyle(color: C.faint, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
