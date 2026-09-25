import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../format.dart';
import '../models.dart';
import '../progress.dart';
import '../theme.dart';
import 'common.dart';

/// Menu entries to mark a VOD as watched / unwatched (value = watched).
List<PopupMenuEntry<bool>> watchedMenuItems(Vod vod) {
  final p = WatchProgress.instance;
  final watched = p.watchedOf(vod);
  return [
    if (!watched)
      const PopupMenuItem(
        value: true,
        child: Row(children: [Icon(Icons.check_circle_outline_rounded, size: 18), SizedBox(width: 10), Text('Als gesehen markieren')]),
      ),
    if (watched || p.positionOf(vod) > 0)
      const PopupMenuItem(
        value: false,
        child: Row(children: [Icon(Icons.replay_rounded, size: 18), SizedBox(width: 10), Text('Als ungesehen markieren')]),
      ),
  ];
}

/// Opens [watchedMenuItems] at [position] and applies the choice.
Future<void> showWatchedMenu(BuildContext context, Vod vod, Offset position) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final watched = await showMenu<bool>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: watchedMenuItems(vod),
  );
  if (watched != null && context.mounted) await setWatchedWithUndo(context, vod, watched);
}

/// Marks [vod] (un)watched and offers to undo it.
Future<void> setWatchedWithUndo(BuildContext context, Vod vod, bool watched) async {
  final messenger = ScaffoldMessenger.of(context);
  final before = (pos: WatchProgress.instance.positionOf(vod), watched: WatchProgress.instance.watchedOf(vod));
  try {
    await WatchProgress.instance.setWatched(vod.id, watched);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Nicht gespeichert: $e')));
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(watched ? 'Als gesehen markiert' : 'Als ungesehen markiert'),
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () => before.watched || before.pos == 0
            ? WatchProgress.instance.setWatched(vod.id, before.watched)
            : WatchProgress.instance.save(vod.id, before.pos, notify: true),
      ),
    ));
}

/// "GESEHEN ↺" badge on watched cards: one tap marks it unwatched again.
class _WatchedBadge extends StatelessWidget {
  const _WatchedBadge({required this.vod});
  final Vod vod;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Als ungesehen markieren',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setWatchedWithUndo(context, vod, false),
          child: Padding(
            padding: const EdgeInsets.all(6), // bigger touch target
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white24)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_rounded, size: 14, color: C.success),
                SizedBox(width: 4),
                Text('GESEHEN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                SizedBox(width: 6),
                Icon(Icons.undo_rounded, size: 15, color: Colors.white70),
              ]),
            ),
          ),
        ),
      );
}

/// Round "mark as watched" button shown on hover (desktop/web).
class _MarkWatchedButton extends StatelessWidget {
  const _MarkWatchedButton({required this.vod});
  final Vod vod;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Als gesehen markieren',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setWatchedWithUndo(context, vod, true),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), shape: BoxShape.circle, border: Border.all(color: Colors.white24)),
              child: const Icon(Icons.check_rounded, size: 17, color: Colors.white),
            ),
          ),
        ),
      );
}

class VodCard extends StatelessWidget {
  const VodCard({super.key, required this.vod, this.showChannel = true, this.timeOnly = false});
  final Vod vod;
  final bool showChannel;

  /// Under a day heading only the start time is shown, otherwise the date too.
  final bool timeOnly;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: WatchProgress.instance.version,
        builder: (context, _, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final watched = WatchProgress.instance.watchedOf(vod);
    final progress = watched ? 0 : WatchProgress.instance.positionOf(vod);
    final frac = vod.durationMs > 0 ? (progress / vod.durationMs).clamp(0.0, 1.0) : 0.0;
    final card = Hoverable(
      onTap: vod.playable ? () => context.push('/v/${vod.id}') : null,
      builder: (context, hover) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, hover ? -4 : 0, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadius),
              boxShadow: [
                if (hover) BoxShadow(color: C.primary.withValues(alpha: 0.35), blurRadius: 28, spreadRadius: -6, offset: const Offset(0, 12)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kRadius),
              child: Stack(fit: StackFit.expand, children: [
                AnimatedScale(
                  scale: hover ? 1.05 : 1,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  child: Opacity(opacity: watched && !hover ? 0.45 : 1, child: NetImg(vod.thumbnail, cacheWidth: 960)),
                ),
                // subtle bottom gradient for badge legibility
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.center, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0x99000000)]),
                  ),
                ),
                AnimatedOpacity(
                  opacity: hover ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.45), border: Border.all(color: Colors.white24)),
                      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
                    ),
                  ),
                ),
                if (vod.ready) Positioned(right: 8, bottom: 8 + (frac > 0 ? 4 : 0), child: Pill(fmtDuration(vod.durationMs))),
                if (vod.qualityLabel.isNotEmpty) Positioned(left: 8, top: 8, child: Pill(vod.qualityLabel)),
                if (watched && vod.ready)
                  Positioned(right: 2, top: 2, child: _WatchedBadge(vod: vod))
                else if (hover && vod.ready)
                  Positioned(right: 2, top: 2, child: _MarkWatchedButton(vod: vod)),
                if (!vod.ready && !vod.live) Positioned.fill(child: _StatusOverlay(vod: vod)),
                if (vod.live) Positioned(left: 8, bottom: 8, child: Pill(vod.recording ? 'LIVE' : 'NOCH LOKAL', color: vod.recording ? C.live : C.orange)),
                if (frac > 0.01)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(value: frac, minHeight: 4, backgroundColor: Colors.white24, color: C.pink),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (showChannel && vod.channel != null) ...[
            GestureDetector(
              onTap: () => context.push('/c/${vod.channel!.login}'),
              child: Avatar(src: vod.channel!.avatar, size: 36, live: vod.channel!.live),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(vod.title.isEmpty ? 'Ohne Titel' : vod.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, height: 1.3, color: hover ? Colors.white : C.text)),
              const SizedBox(height: 4),
              Text(
                [
                  if (showChannel && vod.channel != null) vod.channel!.displayName,
                  timeOnly ? fmtTime(vod.startedAt) : fmtWhen(vod.startedAt),
                  if (vod.category.isNotEmpty) vod.category,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.muted, fontSize: 12.5),
              ),
            ]),
          ),
        ]),
      ]),
    );
    if (!vod.ready) return card;
    return GestureDetector(
      onSecondaryTapUp: (d) => showWatchedMenu(context, vod, d.globalPosition),
      onLongPressStart: (d) => showWatchedMenu(context, vod, d.globalPosition),
      child: card,
    );
  }
}

class _StatusOverlay extends StatelessWidget {
  const _StatusOverlay({required this.vod});
  final Vod vod;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (vod.status) {
      'recording' => (const RecDot(), 'Wird aufgenommen'),
      'processing' => (const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          vod.processing.isEmpty ? 'In Warteschlange' : 'Verarbeitung: ${vod.processing}'),
      _ => (const Icon(Icons.error_outline_rounded, color: C.live, size: 18), 'Fehlgeschlagen'),
    };
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: Row(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(width: 8), Text(text, style: const TextStyle(fontWeight: FontWeight.w600))]),
    );
  }
}

/// Card for a stream that is being recorded right now.
class LiveCard extends StatefulWidget {
  const LiveCard({super.key, required this.rec});
  final LiveRecording rec;
  @override
  State<LiveCard> createState() => _LiveCardState();
}

class _LiveCardState extends State<LiveCard> {
  late final Timer _t;
  // Twitch refreshes preview images every few minutes; bust the cache per mount.
  final _bust = DateTime.now().millisecondsSinceEpoch ~/ 60000;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rec;
    final elapsed = DateTime.now().millisecondsSinceEpoch - r.startedAt;
    final thumb = r.thumbnail.isEmpty ? '' : '${r.thumbnail}?t=$_bust';
    return Hoverable(
      onTap: () => context.push('/v/${r.vodId}'),
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius + 4),
          border: Border.all(color: hover ? C.live.withValues(alpha: 0.6) : C.border),
          color: C.surface,
          boxShadow: [if (hover) BoxShadow(color: C.live.withValues(alpha: 0.25), blurRadius: 30, spreadRadius: -8, offset: const Offset(0, 10))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              NetImg(thumb, cacheWidth: 1280),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x66000000), Colors.transparent, Color(0xAA000000)]),
                ),
              ),
              Positioned(
                left: 10,
                top: 10,
                child: Pill(
                  r.paused ? 'PAUSIERT' : (r.recording ? 'LIVE · REC' : 'VERBINDE…'),
                  color: r.paused ? C.surface3 : (r.recording ? C.live : C.orange),
                  icon: r.recording ? const RecDot(size: 7) : null,
                ),
              ),
              Positioned(right: 10, top: 10, child: Pill(fmtDuration(elapsed))),
              AnimatedOpacity(
                opacity: hover ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.white24)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.play_arrow_rounded, color: Colors.white),
                      SizedBox(width: 6),
                      Text('Live ansehen · zurückspulen möglich', style: TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
              Positioned(
                left: 10,
                bottom: 10,
                child: Row(children: [
                  Pill('${fmtCount(r.viewers)} Zuschauer', icon: const Icon(Icons.person_rounded, size: 13, color: C.live)),
                  const SizedBox(width: 6),
                  Pill('${fmtCount(r.chatCount)} Nachrichten', icon: const Icon(Icons.chat_bubble_rounded, size: 11, color: C.primarySoft)),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Avatar(src: r.channel.avatar, size: 40, live: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.channel.displayName, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                  if (r.category.isNotEmpty)
                    Text(r.category, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.primarySoft, fontSize: 12.5)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Small thumbnail + text row for side panels ("continue watching").
class CompactVodRow extends StatelessWidget {
  const CompactVodRow({super.key, required this.vod});
  final Vod vod;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: WatchProgress.instance.version,
        builder: (context, _, _) {
          final pos = WatchProgress.instance.positionOf(vod);
          final frac = vod.durationMs > 0 ? (pos / vod.durationMs).clamp(0.0, 1.0) : 0.0;
          final left = vod.durationMs - pos;
          final row = _CompactRow(
            onTap: () => context.push('/v/${vod.id}'),
            thumb: Stack(fit: StackFit.expand, children: [
              NetImg(vod.thumbnail, cacheWidth: 320),
              if (vod.live) Positioned(left: 4, top: 4, child: Pill(vod.recording ? 'LIVE' : 'LOKAL', color: vod.recording ? C.live : C.orange)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(value: frac, minHeight: 3, backgroundColor: Colors.white24, color: C.pink),
              ),
            ]),
            title: vod.title.isEmpty ? 'Ohne Titel' : vod.title,
            subtitle: [
              if (vod.channel != null) vod.channel!.displayName,
              fmtWhen(vod.startedAt),
              if (!vod.growing && left > 0) 'noch ${fmtDuration(left)}',
            ].join(' · '),
          );
          if (!vod.ready) return row;
          return GestureDetector(
            onSecondaryTapUp: (d) => showWatchedMenu(context, vod, d.globalPosition),
            onLongPressStart: (d) => showWatchedMenu(context, vod, d.globalPosition),
            child: row,
          );
        },
      );
}

class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.onTap, required this.thumb, required this.title, required this.subtitle});
  final VoidCallback onTap;
  final Widget thumb;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: onTap,
        builder: (context, hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: hover ? C.surface2 : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            SizedBox(
              width: 132,
              child: AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: thumb)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.3)),
                const SizedBox(height: 3),
                Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12, height: 1.35)),
              ]),
            ),
          ]),
        ),
      );
}

