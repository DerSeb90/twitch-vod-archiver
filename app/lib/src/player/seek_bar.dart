import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import 'player_extras.dart';

/// Seek bar with chat heat map, chapter gaps and storyboard hover preview.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.player,
    required this.extras,
    required this.onInteract,
    this.onDragging,
  });
  final Player player;
  final PlayerExtras extras;
  final VoidCallback onInteract;
  final ValueChanged<bool>? onDragging;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _hoverX;
  double? _dragFrac;

  Vod get vod => widget.extras.vod;

  int get _durationMs => widget.extras.durationMs(widget.player);

  void _seekTo(double frac) {
    widget.extras.seek(widget.player, (frac.clamp(0, 1) * _durationMs).round());
    widget.onInteract();
  }

  void _dragTo(double x, double w, {bool start = false}) {
    // the mouse doesn't send hover events while a button is held: move the
    // preview along with the drag
    setState(() {
      _dragFrac = (x / w).clamp(0, 1);
      if (_hoverX != null) _hoverX = x.clamp(0, w);
    });
    if (start) widget.onDragging?.call(true);
    widget.onInteract();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth;
      final hovering = _hoverX != null || _dragFrac != null;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (e) {
          // a finger has no hover: the preview would stay after a touch drag
          if (e.kind != PointerDeviceKind.mouse) return;
          setState(() => _hoverX = e.localPosition.dx.clamp(0, w));
          widget.onInteract();
        },
        onExit: (_) => setState(() => _hoverX = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _seekTo(d.localPosition.dx / w),
          onHorizontalDragStart: (d) =>
              _dragTo(d.localPosition.dx, w, start: true),
          onHorizontalDragUpdate: (d) => _dragTo(d.localPosition.dx, w),
          onHorizontalDragEnd: (_) {
            if (_dragFrac != null) _seekTo(_dragFrac!);
            setState(() => _dragFrac = null);
            widget.onDragging?.call(false);
          },
          onHorizontalDragCancel: () {
            setState(() => _dragFrac = null);
            widget.onDragging?.call(false);
          },
          child: SizedBox(
            height: 34,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: StreamBuilder<Duration>(
                    stream: widget.player.stream.position,
                    builder: (_, _) {
                      final dur = _durationMs;
                      final pos = dur > 0
                          ? widget.extras.positionMs(widget.player) / dur
                          : 0.0;
                      final buf = dur > 0
                          ? widget.player.state.buffer.inMilliseconds / dur
                          : 0.0;
                      return CustomPaint(
                        painter: _SeekPainter(
                          progress: _dragFrac ?? pos,
                          buffered: buf,
                          hoverFrac: _hoverX == null ? null : _hoverX! / w,
                          expanded: hovering,
                          activity: widget.extras.activity,
                          activityBucketMs: widget.extras.activityBucketMs,
                          durationMs: dur,
                          chapters: [
                            for (final c in vod.chapters)
                              if (c.offsetMs > 0) c.offsetMs,
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (hovering) _preview(w),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _preview(double w) {
    final x = _dragFrac != null ? _dragFrac! * w : _hoverX!;
    final ms = (x / w * _durationMs).round();
    final sb = vod.storyboard;
    const tw = 192.0, th = 108.0;
    final chapter = vod.chapterAt(ms);
    final left = (x - tw / 2).clamp(0.0, math.max(0.0, w - tw)).toDouble();
    return Positioned(
      left: left,
      bottom: 34,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sb.available)
              Container(
                width: tw,
                height: th,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 16),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _StoryboardTile(
                  vod: vod,
                  ms: ms,
                  width: tw - 4,
                  height: th - 4,
                ),
              ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxWidth: tw),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chapter != null)
                    Text(
                      chapter.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Colors.white70,
                      ),
                    ),
                  Text(
                    fmtDuration(ms),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryboardTile extends StatelessWidget {
  const _StoryboardTile({
    required this.vod,
    required this.ms,
    required this.width,
    required this.height,
  });
  final Vod vod;
  final int ms;
  final double width, height;

  @override
  Widget build(BuildContext context) {
    final sb = vod.storyboard;
    final perSheet = sb.cols * sb.rows;
    final idx = (ms ~/ sb.intervalMs).clamp(0, math.max(0, sb.count - 1));
    final sheet = math.min(idx ~/ perSheet, sb.sheets - 1);
    final within = idx % perSheet;
    final col = within % sb.cols, row = within ~/ sb.cols;
    final url = Api.instance.url(
      '${vod.base}storyboard/${sheet.toString().padLeft(3, '0')}.jpg',
    );
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width * sb.cols,
        maxWidth: width * sb.cols,
        minHeight: height * sb.rows,
        maxHeight: height * sb.rows,
        child: Transform.translate(
          offset: Offset(-col * width, -row * height),
          child: Image.network(
            url,
            width: width * sb.cols,
            height: height * sb.rows,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
          ),
        ),
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({
    required this.progress,
    required this.buffered,
    required this.hoverFrac,
    required this.expanded,
    required this.activity,
    required this.activityBucketMs,
    required this.durationMs,
    required this.chapters,
  });
  final double progress, buffered;
  final double? hoverFrac;
  final bool expanded;
  final List<int> activity;
  final int activityBucketMs, durationMs;
  final List<int> chapters;

  @override
  void paint(Canvas canvas, Size size) {
    final trackH = expanded ? 6.0 : 4.0;
    final y = size.height - 10;
    final w = size.width;

    // chat heat map above the track
    if (activity.isNotEmpty && durationMs > 0) {
      final maxV = activity.reduce(math.max).toDouble();
      if (maxV > 0) {
        final heat = Paint()
          ..shader = const LinearGradient(colors: [C.primary, C.pink])
              .createShader(Rect.fromLTWH(0, 0, w, size.height))
          ..color = Colors.white.withValues(alpha: expanded ? 0.55 : 0.3);
        final path = Path()..moveTo(0, y - trackH / 2);
        final bucketW = activityBucketMs / durationMs * w;
        for (var i = 0; i < activity.length; i++) {
          final h = math.pow(activity[i] / maxV, 0.7) * (expanded ? 16 : 10);
          path.lineTo(i * bucketW + bucketW / 2, y - trackH / 2 - h);
        }
        path
          ..lineTo(w, y - trackH / 2)
          ..close();
        canvas.drawPath(path, heat);
      }
    }

    final r = Radius.circular(trackH);
    RRect bar(double from, double to) =>
        RRect.fromLTRBR(from * w, y - trackH / 2, to * w, y + trackH / 2, r);
    canvas.drawRRect(bar(0, 1), Paint()..color = Colors.white24);
    canvas.drawRRect(
      bar(0, buffered.clamp(0, 1)),
      Paint()..color = Colors.white38,
    );
    if (hoverFrac != null) {
      canvas.drawRRect(
        bar(0, hoverFrac!.clamp(0, 1)),
        Paint()..color = Colors.white30,
      );
    }
    canvas.drawRRect(
      bar(0, progress.clamp(0, 1)),
      Paint()
        ..shader = const LinearGradient(colors: [C.primary, C.pink])
            .createShader(Rect.fromLTWH(0, 0, math.max(1, progress * w), 1)),
    );
    // chapter gaps
    if (durationMs > 0) {
      final gap = Paint()..color = Colors.black;
      for (final c in chapters) {
        final x = c / durationMs * w;
        canvas.drawRect(Rect.fromLTWH(x - 1, y - trackH / 2, 2, trackH), gap);
      }
    }
    // knob
    final kx = progress.clamp(0.0, 1.0) * w;
    canvas.drawCircle(
      Offset(kx, y),
      expanded ? 11 : 8,
      Paint()..color = C.pink.withValues(alpha: 0.35),
    );
    canvas.drawCircle(
      Offset(kx, y),
      expanded ? 7 : 5,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SeekPainter o) =>
      o.progress != progress ||
      o.buffered != buffered ||
      o.hoverFrac != hoverFrac ||
      o.expanded != expanded ||
      o.activity != activity ||
      o.durationMs != durationMs;
}
