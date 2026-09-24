import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../progress.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

/// Grid of all archived channels.
class ChannelsPage extends StatefulWidget {
  const ChannelsPage({super.key});
  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  late Future<List<Channel>> _f = Api.instance.channels();

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: ErrorBox(error: snap.error!, onRetry: () => setState(() => _f = Api.instance.channels())));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: C.primary));
          final chs = snap.data!;
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(top: 40, bottom: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Kanäle', style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 6),
                    Text('${chs.length} Kanäle werden archiviert', style: const TextStyle(color: C.muted)),
                  ]),
                ),
              ),
            ),
            if (chs.isEmpty)
              SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.person_add_alt_1_rounded,
                  title: 'Noch keine Kanäle',
                  subtitle: 'Kanäle werden in der Verwaltung hinzugefügt.',
                  action: FilledButton(onPressed: () => context.go('/admin'), child: const Text('Zur Verwaltung')),
                ),
              )
            else
              SliverLayoutBuilder(builder: (context, c) {
                final w = c.crossAxisExtent;
                final inner = w.clamp(0.0, kMaxContentWidth);
                final pad = ContentWidth.pad(inner) + (w - inner) / 2;
                return SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, 24, pad, 48),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 320, mainAxisExtent: 124, crossAxisSpacing: 16, mainAxisSpacing: 16),
                    delegate: SliverChildBuilderDelegate((_, i) => _ChannelCard(channel: chs[i]), childCount: chs.length),
                  ),
                );
              }),
          ]);
        },
      );
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: () => context.push('/c/${channel.login}'),
        builder: (context, hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(kRadius + 2),
            border: Border.all(color: hover ? C.primary.withValues(alpha: 0.5) : C.border),
          ),
          child: Stack(children: [
            Positioned.fill(
              child: Opacity(
                opacity: hover ? 0.35 : 0.18,
                child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30), child: NetImg(channel.avatar, cacheWidth: 120)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                Avatar(src: channel.avatar, size: 72, live: channel.live),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(channel.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text('${channel.vodCount} VODs · ${fmtHours(channel.totalMs)}', style: const TextStyle(color: C.muted, fontSize: 13)),
                    if (channel.live) ...[
                      const SizedBox(height: 6),
                      const Row(children: [RecDot(size: 7), SizedBox(width: 6), Text('Wird aufgenommen', style: TextStyle(color: C.live, fontSize: 12, fontWeight: FontWeight.w700))]),
                    ] else if (!channel.enabled) ...[
                      const SizedBox(height: 6),
                      const Text('Pausiert', style: TextStyle(color: C.faint, fontSize: 12)),
                    ],
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      );
}

/// Single channel with all of its VODs.
class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key, required this.login});
  final String login;
  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  Channel? _ch;
  List<Vod> _vods = [];
  List<LiveRecording> _live = [];
  int _total = 0;
  Object? _error;
  bool _more = false;

  @override
  void initState() {
    super.initState();
    _load();
    WatchProgress.instance.version.addListener(_progressChanged);
  }

  @override
  void dispose() {
    WatchProgress.instance.version.removeListener(_progressChanged);
    super.dispose();
  }

  void _progressChanged() {
    if (mounted) setState(() {});
  }

  bool get _unwatched => !Settings.instance.showWatched;

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        Api.instance.channel(widget.login),
        Api.instance.vods(channel: widget.login, status: 'all', limit: 48, unwatched: _unwatched),
        Api.instance.live(),
      ]);
      final page = r[1] as VodPage;
      final ch = r[0] as Channel;
      setState(() {
        _ch = ch;
        _vods = page.items.where((v) => v.status != 'recording').toList();
        _total = page.total;
        _live = (r[2] as List<LiveRecording>).where((l) => l.channel.id == ch.id).toList();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _loadMore() async {
    if (_more || _vods.length >= _total) return;
    _more = true;
    try {
      final p = await Api.instance.vods(channel: widget.login, status: 'all', limit: 48, offset: _vods.length, unwatched: _unwatched);
      setState(() => _vods = [..._vods, ...p.items.where((v) => v.status != 'recording')]);
    } finally {
      _more = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: ErrorBox(error: _error!, onRetry: _load));
    final ch = _ch;
    if (ch == null) return const Center(child: CircularProgressIndicator(color: C.primary));
    final compact = MediaQuery.sizeOf(context).width < 700;
    final vods = _unwatched ? _vods.where((v) => !WatchProgress.instance.watchedOf(v)).toList() : _vods;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 800) _loadMore();
        return false;
      },
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: compact ? 280 : 380,
            child: Stack(fit: StackFit.expand, children: [
              if (ch.banner.isNotEmpty)
                Opacity(opacity: 0.55, child: NetImg(ch.banner, cacheWidth: 1920))
              else
                Opacity(
                  opacity: 0.5,
                  child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60), child: NetImg(ch.avatar, cacheWidth: 200)),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x33090909), C.bg], stops: [0.2, 1]),
                ),
              ),
              ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Avatar(src: ch.avatar, size: compact ? 88 : 128, live: ch.live),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (ch.live)
                          const Padding(padding: EdgeInsets.only(bottom: 8), child: Pill('LIVE · REC', color: C.live, icon: RecDot(size: 7))),
                        Text(ch.displayName, style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontSize: compact ? 30 : 44)),
                        const SizedBox(height: 6),
                        Text('${ch.vodCount} Aufnahmen · ${fmtHours(ch.totalMs)} · twitch.tv/${ch.login}', style: const TextStyle(color: C.muted)),
                        if (ch.description.isNotEmpty && !compact) ...[
                          const SizedBox(height: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: Text(ch.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, height: 1.4)),
                          ),
                        ],
                      ]),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        if (_live.isNotEmpty)
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(alignment: Alignment.centerLeft, child: SizedBox(width: 460, child: LiveCard(rec: _live.first))),
              ),
            ),
          ),
        SliverToBoxAdapter(child: ContentWidth(child: SectionHeader('Aufnahmen', trailing: ShowWatchedToggle(onChanged: _load)))),
        if (vods.isEmpty && ch.vodCount > 0 && _unwatched)
          const SliverToBoxAdapter(
            child: EmptyState(icon: Icons.done_all_rounded, title: 'Alles gesehen', subtitle: 'Gesehene Aufnahmen lassen sich oben rechts wieder einblenden.'),
          )
        else if (vods.isEmpty)
          const SliverToBoxAdapter(child: EmptyState(icon: Icons.videocam_off_rounded, title: 'Noch keine Aufnahmen', subtitle: 'Sobald der Kanal live geht, wird mitgeschnitten.'))
        else
          SliverLayoutBuilder(builder: (context, c) {
            final w = c.crossAxisExtent;
            final inner = w.clamp(0.0, kMaxContentWidth);
            final pad = ContentWidth.pad(inner) + (w - inner) / 2;
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 48),
              sliver: SliverGrid(
                gridDelegate: cardGrid(w - pad * 2, textBlock: 76),
                delegate: SliverChildBuilderDelegate((_, i) => VodCard(vod: vods[i], showChannel: false), childCount: vods.length),
              ),
            );
          }),
      ]),
    );
  }
}

/// Full-text search over titles, categories and channel names.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.query});
  final String query;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _c = TextEditingController(text: widget.query);
  Future<VodPage>? _f;

  @override
  void initState() {
    super.initState();
    if (widget.query.isNotEmpty) _f = Api.instance.vods(query: widget.query, limit: 96);
  }

  @override
  void didUpdateWidget(SearchPage old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) {
      _c.text = widget.query;
      _f = widget.query.isEmpty ? null : Api.instance.vods(query: widget.query, limit: 96);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: ContentWidth(
            child: Padding(
              padding: const EdgeInsets.only(top: 32, bottom: 24),
              child: TextField(
                controller: _c,
                autofocus: widget.query.isEmpty,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 18),
                decoration: const InputDecoration(
                  hintText: 'Titel, Kategorie oder Kanal suchen…',
                  prefixIcon: Icon(Icons.search_rounded),
                  contentPadding: EdgeInsets.symmetric(vertical: 16),
                ),
                onSubmitted: (q) => context.go('/search?q=${Uri.encodeQueryComponent(q.trim())}'),
              ),
            ),
          ),
        ),
        if (_f != null)
          FutureBuilder(
            future: _f,
            builder: (context, snap) {
              if (snap.hasError) return SliverToBoxAdapter(child: ErrorBox(error: snap.error!));
              if (!snap.hasData) return const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator(color: C.primary))));
              final items = snap.data!.items;
              if (items.isEmpty) {
                return SliverToBoxAdapter(child: EmptyState(icon: Icons.search_off_rounded, title: 'Nichts gefunden', subtitle: 'Keine Aufnahme passt zu „${widget.query}“.'));
              }
              return SliverLayoutBuilder(builder: (context, c) {
                final w = c.crossAxisExtent;
                final inner = w.clamp(0.0, kMaxContentWidth);
                final pad = ContentWidth.pad(inner) + (w - inner) / 2;
                return SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, 48),
                  sliver: SliverGrid(
                    gridDelegate: cardGrid(w - pad * 2),
                    delegate: SliverChildBuilderDelegate((_, i) => VodCard(vod: items[i]), childCount: items.length),
                  ),
                );
              });
            },
          ),
      ]);
}
