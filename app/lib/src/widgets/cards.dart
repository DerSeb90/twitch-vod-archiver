import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../format.dart';
import '../models.dart';
import '../settings.dart';
import '../theme.dart';
import 'common.dart';

class VodCard extends StatelessWidget {
  const VodCard({super.key, required this.vod, this.showChannel = true});
  final Vod vod;
  final bool showChannel;

  @override
  Widget build(BuildContext context) {
    final progress = Settings.instance.progressMs(vod.id);
    final frac = vod.durationMs > 0 ? (progress / vod.durationMs).clamp(0.0, 1.0) : 0.0;
    return Hoverable(
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
                  child: NetImg(vod.thumbnail, cacheWidth: 960),
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
                [if (showChannel && vod.channel != null) vod.channel!.displayName, fmtRelative(vod.startedAt), if (vod.category.isNotEmpty) vod.category].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.muted, fontSize: 12.5),
              ),
            ]),
          ),
        ]),
      ]),
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

class ChannelTile extends StatelessWidget {
  const ChannelTile({super.key, required this.channel, this.size = 88});
  final Channel channel;
  final double size;

  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: () => context.push('/c/${channel.login}'),
        builder: (context, hover) => SizedBox(
          width: size + 24,
          child: Column(children: [
            AnimatedScale(
              scale: hover ? 1.06 : 1,
              duration: const Duration(milliseconds: 200),
              child: Avatar(src: channel.avatar, size: size, live: channel.live),
            ),
            const SizedBox(height: 10),
            Text(channel.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            Text(channel.live ? 'Live – REC' : '${channel.vodCount} VODs',
                style: TextStyle(color: channel.live ? C.live : C.faint, fontSize: 12, fontWeight: channel.live ? FontWeight.w700 : FontWeight.w400)),
          ]),
        ),
      );
}
