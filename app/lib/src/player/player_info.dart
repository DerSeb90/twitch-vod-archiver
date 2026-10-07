import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';

import '../format.dart';
import '../models.dart';
import '../progress.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

/// Title, channel, actions, recording facts and chapters below the video.
class PlayerInfo extends StatelessWidget {
  const PlayerInfo({
    super.key,
    required this.vod,
    required this.onSeek,
    required this.player,
    required this.onSetWatched,
    required this.nerd,
  });
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
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 28,
        22,
        compact ? 16 : 28,
        40,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            vod.title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontSize: compact ? 19 : 24, height: 1.25),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (ch != null) ...[
                GestureDetector(
                  onTap: () => context.push('/c/${ch.login}'),
                  child: Avatar(src: ch.avatar, size: 44, live: ch.live),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ch.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                        ),
                      ),
                      Text(
                        '${ch.vodCount} Aufnahmen',
                        style: const TextStyle(color: C.faint, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (!compact)
                  OutlinedButton(
                    onPressed: () => context.push('/c/${ch.login}'),
                    child: const Text('Kanal'),
                  ),
              ] else
                const Spacer(),
              const SizedBox(width: 8),
              ValueListenableBuilder<int>(
                valueListenable: WatchProgress.instance.version,
                builder: (context, _, _) {
                  final watched = WatchProgress.instance.watchedOf(vod);
                  return Tooltip(
                    message: watched
                        ? 'Als ungesehen markieren'
                        : 'Als gesehen markieren',
                    child: watched
                        ? FilledButton.tonalIcon(
                            onPressed: () => onSetWatched(false),
                            style: FilledButton.styleFrom(
                              backgroundColor: C.success.withValues(
                                alpha: 0.18,
                              ),
                              foregroundColor: C.success,
                            ),
                            icon: const Icon(
                              Icons.check_circle_rounded,
                              size: 18,
                            ),
                            label: const Text('Gesehen'),
                          )
                        : OutlinedButton.icon(
                            onPressed: () => onSetWatched(true),
                            icon: const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 18,
                            ),
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
                  icon: Icon(
                    Icons.query_stats_rounded,
                    color: on ? C.primarySoft : C.muted,
                  ),
                ),
              ),
              _ViewerMenu(vod: vod, onSetWatched: onSetWatched),
            ],
          ),
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
                      final end = i + 1 < vod.chapters.length
                          ? vod.chapters[i + 1].offsetMs
                          : vod.durationMs;
                      final active = pos >= c.offsetMs && pos < end;
                      return _ChapterCard(
                        chapter: c,
                        lengthMs: end - c.offsetMs,
                        active: active,
                        onTap: () => onSeek(c.offsetMs),
                      );
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
              decoration: BoxDecoration(
                color: C.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: C.border),
              ),
              child: const Text(
                'Tastatur: Leertaste Play/Pause · ←/→ 10 s · J/L 30 s · ↑/↓ Lautstärke · F Vollbild · M Stumm · C Chat · I Statistiken · Doppelklick Vollbild',
                style: TextStyle(color: C.faint, fontSize: 12.5),
              ),
            ),
          ] else ...[
            const SizedBox(height: 20),
            const Text(
              'Doppelt tippen links/rechts: 10 s zurück/vor · Handy quer: Vollbild',
              style: TextStyle(color: C.faint, fontSize: 12.5),
            ),
          ],
        ],
      ),
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
    final mbit = vod.avgMbit;
    final tiles = <(IconData, String, String)>[
      (Icons.play_circle_outline_rounded, 'Gestartet', fmtWhen(vod.startedAt)),
      if (vod.endedAt > 0)
        (Icons.stop_circle_outlined, 'Beendet', fmtWhen(vod.endedAt)),
      (Icons.schedule_rounded, 'Länge', fmtDuration(vod.durationMs)),
      if (vod.category.isNotEmpty)
        (Icons.sports_esports_rounded, 'Kategorie', vod.category),
      if (vod.height > 0)
        (
          Icons.high_quality_rounded,
          'Video',
          '${vod.width}×${vod.height} · ${vod.fps.round()} fps',
        ),
      if (vod.videoCodec.isNotEmpty)
        (Icons.memory_rounded, 'Codec', vod.videoCodec.toUpperCase()),
      if (mbit > 0) (Icons.speed_rounded, 'Ø Bitrate', fmtMbit(mbit)),
      if (vod.sizeBytes > 0)
        (Icons.save_rounded, 'Größe', fmtBytes(vod.sizeBytes)),
      (
        Icons.forum_rounded,
        'Chat',
        mins > 1
            ? '${fmtCount(vod.chatCount)} · Ø ${(vod.chatCount / mins).toStringAsFixed(vod.chatCount / mins < 10 ? 1 : 0).replaceAll('.', ',')}/min'
            : fmtCount(vod.chatCount),
      ),
      if (vod.peakViewers > 0)
        (Icons.visibility_rounded, 'Peak-Zuschauer', fmtCount(vod.peakViewers)),
      if (vod.chapters.length > 1)
        (Icons.bookmarks_rounded, 'Kapitel', '${vod.chapters.length}'),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = (c.maxWidth / 210).floor().clamp(2, 5);
        final w = (c.maxWidth - (cols - 1) * 8) / cols;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (icon, label, value) in tiles)
              Container(
                width: w,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: C.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: C.border),
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: C.primarySoft),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: const TextStyle(
                              color: C.faint,
                              fontSize: 11.5,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({
    required this.chapter,
    required this.lengthMs,
    required this.active,
    required this.onTap,
  });
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
        color: active
            ? C.primary.withValues(alpha: 0.14)
            : (hover ? C.surface2 : C.surface),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? C.primary : C.border),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 54,
              height: 72,
              child: NetImg(chapter.boxArt, cacheWidth: 160),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chapter.category.isEmpty ? 'Unbekannt' : chapter.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: C.muted, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '${fmtDuration(chapter.offsetMs)} · ${fmtHours(lengthMs)}',
                  style: const TextStyle(color: C.faint, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
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
