import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Extra data the custom controls render on the seek bar.
class PlayerExtras {
  PlayerExtras({required this.vod, this.activity = const [], this.activityBucketMs = 30000, this.onToggleChat})
      : liveDurationMs = ValueNotifier(vod.durationMs);
  final Vod vod;

  /// Length of a growing live recording, refreshed from the API (players
  /// report no usable duration for live HLS; on web it is even negative).
  final ValueNotifier<int> liveDurationMs;

  /// Best known total length for [player].
  int durationMs(Player player) =>
      math.max(math.max(player.state.duration.inMilliseconds, vod.durationMs), math.max(liveDurationMs.value, player.state.position.inMilliseconds));
  List<int> activity;
  int activityBucketMs;
  final VoidCallback? onToggleChat;

  /// The chat button only makes sense where the chat sits next to the video
  /// (on narrow screens it is a tab below it).
  bool chatButton = true;

  /// Where the last seek goes. Until the player reports it, seek bar and time
  /// show the target instead of jumping back to the old position.
  int? _seekTarget;
  Timer? _seekTimer;

  int positionMs(Player player) {
    final p = player.state.position.inMilliseconds;
    final t = _seekTarget;
    if (t == null) return p;
    if ((p - t).abs() < 1500) {
      _seekTarget = null;
      return p;
    }
    return t;
  }

  void seek(Player player, int ms) {
    ms = ms.clamp(0, math.max(0, durationMs(player)));
    _seekTarget = ms;
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(seconds: 3), () => _seekTarget = null);
    player.seek(Duration(milliseconds: ms));
  }
}

/// Fully custom video controls: storyboard previews on hover, chat heat map
/// and chapter markers on the seek bar, keyboard shortcuts.
class RewindControls extends StatefulWidget {
  const RewindControls({super.key, required this.state, required this.extras});
  final VideoState state;
  final PlayerExtras extras;

  @override
  State<RewindControls> createState() => _RewindControlsState();
}

class _RewindControlsState extends State<RewindControls> {
  Player get player => widget.state.widget.controller.player;
  bool _visible = true;
  Timer? _hideTimer;
  final _focus = FocusNode();
  final _subs = <StreamSubscription>[];
  bool _playing = false, _buffering = false;
  Object? _flash; // transient center feedback: text ("+10 s") or an icon
  Timer? _flashTimer;

  // Controls stay while the pointer rests on them, the seek bar is dragged
  // or a menu is open.
  bool _overBar = false, _dragging = false, _menuOpen = false;

  // Taps are handled on release without waiting for a possible double tap
  // (that wait made play/pause feel sluggish); a quick second tap is then
  // interpreted on its own.
  DateTime _lastTap = DateTime(0);
  int _taps = 0;
  bool _visibleBeforeTaps = true;

  bool get _touch => switch (Theme.of(context).platform) { TargetPlatform.android || TargetPlatform.iOS => true, _ => false };

  @override
  void initState() {
    super.initState();
    _playing = player.state.playing;
    _subs.add(player.stream.playing.listen((p) {
      setState(() => _playing = p);
      if (p) _scheduleHide();
    }));
    _subs.add(player.stream.buffering.listen((b) => setState(() => _buffering = b)));
    _scheduleHide();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !player.state.playing) return;
      if (_overBar || _dragging || _menuOpen) return _scheduleHide();
      setState(() => _visible = false);
    });
  }

  void _flashText(Object t) {
    _flashTimer?.cancel();
    setState(() => _flash = t);
    _flashTimer = Timer(const Duration(milliseconds: 600), () => mounted ? setState(() => _flash = null) : null);
  }

  void _seekBy(int seconds) {
    final ex = widget.extras;
    ex.seek(player, ex.positionMs(player) + seconds * 1000);
    _flashText(seconds > 0 ? '+$seconds s' : '$seconds s');
    _show();
  }

  void _togglePlay() {
    player.playOrPause();
    _flashText(player.state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded);
  }

  void _onTapUp(TapUpDetails d) {
    _focus.requestFocus();
    final now = DateTime.now();
    final quick = now.difference(_lastTap) < const Duration(milliseconds: 300);
    _lastTap = now;
    _taps = quick ? _taps + 1 : 1;
    // by the pointer, not the platform: touch laptops, tablets with a mouse,
    // phone browsers
    final touch = switch (d.kind) {
      PointerDeviceKind.touch || PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
      PointerDeviceKind.mouse || PointerDeviceKind.trackpad => false,
      _ => _touch,
    };
    if (touch) {
      if (_taps == 1) {
        _visibleBeforeTaps = _visible;
        _visible ? setState(() => _visible = false) : _show();
        return;
      }
      // double tap (and every further quick tap): ±10 s on that side;
      // the first tap's show/hide is undone
      if (_taps == 2) setState(() => _visible = _visibleBeforeTaps);
      final w = context.size?.width ?? 1;
      _seekBy(d.localPosition.dx < w / 2 ? -10 : 10);
      if (!_visible) setState(() {}); // keep them hidden, just the feedback
    } else if (_taps == 2) {
      // double click: fullscreen; undo the first click's play/pause
      player.playOrPause();
      widget.state.toggleFullscreen();
      _taps = 0;
    } else {
      _togglePlay();
      _show();
    }
  }

  void _setVolume(double v) {
    v = v.clamp(0, 100);
    player.setVolume(v);
    Settings.instance.volume = v;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      _togglePlay();
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyJ) {
      _seekBy(k == LogicalKeyboardKey.keyJ ? -30 : -10);
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyL) {
      _seekBy(k == LogicalKeyboardKey.keyL ? 30 : 10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume(player.state.volume + 5);
      _flashText('${player.state.volume.round()} %');
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume(player.state.volume - 5);
      _flashText('${player.state.volume.round()} %');
    } else if (k == LogicalKeyboardKey.keyF) {
      widget.state.toggleFullscreen();
    } else if (k == LogicalKeyboardKey.keyM) {
      _setVolume(player.state.volume > 0 ? 0 : 100);
    } else if (k == LogicalKeyboardKey.keyC) {
      widget.extras.onToggleChat?.call();
    } else if (k == LogicalKeyboardKey.escape && widget.state.isFullscreen()) {
      widget.state.exitFullscreen();
    } else {
      return KeyEventResult.ignored;
    }
    _show();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final fullscreen = widget.state.isFullscreen();
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: _visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
        onHover: (_) => _show(),
        child: Stack(children: [
          // gesture layer
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTapUp: _onTapUp),
          ),
          // center: buffering / feedback / big play button (on desktop a
          // click anywhere plays, so the button is only a picture there)
          Center(
            child: IgnorePointer(
              ignoring: _playing || !_touch,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _buffering
                    ? const SizedBox(key: ValueKey('b'), width: 48, height: 48, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                    : _flash != null
                        ? Container(
                            key: ValueKey(_flash),
                            padding: _flash is IconData ? const EdgeInsets.all(14) : const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
                            child: _flash is IconData
                                ? Icon(_flash as IconData, size: 34, color: Colors.white)
                                : Text('$_flash', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                          )
                        : !_playing
                            ? GestureDetector(
                                key: const ValueKey('p'),
                                onTap: player.play,
                                child: Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: C.brandGradient,
                                    boxShadow: [BoxShadow(color: C.primary.withValues(alpha: 0.5), blurRadius: 30)],
                                  ),
                                  child: const Icon(Icons.play_arrow_rounded, size: 44, color: Colors.white),
                                ),
                              )
                            : const SizedBox.shrink(key: ValueKey('n')),
              ),
            ),
          ),
          // top title in fullscreen
          if (fullscreen)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                    decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Colors.transparent])),
                    child: Text(widget.extras.vod.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
          // bottom bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedSlide(
              offset: _visible ? Offset.zero : const Offset(0, 0.25),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !_visible,
                  child: MouseRegion(
                    // only the seek bar and buttons count, not the fade above them
                    hitTestBehavior: HitTestBehavior.deferToChild,
                    onEnter: (_) => _overBar = true,
                    onExit: (_) => _overBar = false,
                    child: Stack(children: [
                      // the dark fade must not swallow taps on the video
                      // (hiding the controls, double tap to skip)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xE6000000)]),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(compact ? 10 : 18, 48, compact ? 10 : 18, compact ? 6 : 12),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          SeekBar(
                            player: player,
                            extras: widget.extras,
                            onInteract: _show,
                            onDragging: (d) {
                              _dragging = d;
                              _show();
                            },
                          ),
                          const SizedBox(height: 4),
                          _buttons(fullscreen, compact),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buttons(bool fullscreen, bool compact) {
    const iconColor = Colors.white;
    return Row(children: [
      _Btn(
        tooltip: _playing ? 'Pause (Leertaste)' : 'Abspielen (Leertaste)',
        icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: 30,
        onTap: () {
          player.playOrPause();
          _show();
        },
      ),
      if (!compact) ...[
        _Btn(tooltip: '10 s zurück (←)', icon: Icons.replay_10_rounded, onTap: () => _seekBy(-10)),
        _Btn(tooltip: '10 s vor (→)', icon: Icons.forward_10_rounded, onTap: () => _seekBy(10)),
        _VolumeControl(player: player, onChanged: _setVolume),
      ],
      const SizedBox(width: 8),
      StreamBuilder<Duration>(
        stream: player.stream.position,
        builder: (_, _) => Text(
          '${fmtDuration(widget.extras.positionMs(player))} / ${fmtDuration(widget.extras.durationMs(player))}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ),
      const SizedBox(width: 12),
      if (widget.extras.vod.growing) _LiveButton(player: player, extras: widget.extras),
      if (!compact) Expanded(child: _CurrentChapter(player: player, chapters: widget.extras.vod.chapters)) else const Spacer(),
      PopupMenuButton<double>(
        tooltip: 'Geschwindigkeit',
        icon: const Icon(Icons.speed_rounded, color: iconColor),
        initialValue: player.state.rate,
        onOpened: () => _menuOpen = true,
        onCanceled: () {
          _menuOpen = false;
          _show();
        },
        onSelected: (r) {
          _menuOpen = false;
          player.setRate(r);
          _flashText('${r == 1.0 ? 1 : r}x');
          _show();
        },
        itemBuilder: (_) => [
          for (final r in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]) PopupMenuItem(value: r, child: Text(r == 1.0 ? 'Normal' : '${r}x')),
        ],
      ),
      if (widget.extras.onToggleChat != null && widget.extras.chatButton && !fullscreen)
        _Btn(tooltip: 'Chat ein/aus (C)', icon: Icons.chat_rounded, onTap: widget.extras.onToggleChat!),
      _Btn(
        tooltip: fullscreen ? 'Vollbild verlassen (F)' : 'Vollbild (F)',
        icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
        size: 28,
        onTap: widget.state.toggleFullscreen,
      ),
    ]);
  }
}

class _Btn extends StatelessWidget {
  const _Btn({required this.tooltip, required this.icon, required this.onTap, this.size = 24});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, size: size, color: Colors.white),
        visualDensity: VisualDensity.compact,
      );
}

class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.player, required this.onChanged});
  final Player player;
  final ValueChanged<double> onChanged;
  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  bool _hover = false;
  double _before = 100;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: StreamBuilder<double>(
          stream: widget.player.stream.volume,
          initialData: widget.player.state.volume,
          builder: (context, snap) {
            final v = snap.data ?? 100;
            return Row(mainAxisSize: MainAxisSize.min, children: [
              _Btn(
                tooltip: v == 0 ? 'Ton an (M)' : 'Stumm (M)',
                icon: v == 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                onTap: () {
                  if (v > 0) {
                    _before = v;
                    widget.onChanged(0);
                  } else {
                    widget.onChanged(_before);
                  }
                },
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _hover ? 96 : 0,
                child: _hover
                    ? SliderTheme(
                        data: SliderTheme.of(context).copyWith(activeTrackColor: Colors.white, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                        child: Slider(value: v.clamp(0.0, 100.0), max: 100, onChanged: widget.onChanged),
                      )
                    : null,
              ),
            ]);
          },
        ),
      );
}

/// Shows whether playback is at the live edge; tapping jumps there.
class _LiveButton extends StatelessWidget {
  const _LiveButton({required this.player, required this.extras});
  final Player player;
  final PlayerExtras extras;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: player.stream.position,
        builder: (_, _) {
          final behind = extras.durationMs(player) - player.state.position.inMilliseconds;
          final atEdge = behind < 20000;
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: atEdge ? 'Du schaust live' : 'Zum Live-Punkt springen',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: atEdge ? null : () => extras.seek(player, extras.durationMs(player) - 8000),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: atEdge ? C.live : Colors.white24, borderRadius: BorderRadius.circular(6)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (atEdge) ...[const RecDot(size: 6), const SizedBox(width: 5)],
                    Text(atEdge ? 'LIVE' : 'LIVE ›', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}

class _CurrentChapter extends StatelessWidget {
  const _CurrentChapter({required this.player, required this.chapters});
  final Player player;
  final List<Chapter> chapters;

  @override
  Widget build(BuildContext context) {
    if (chapters.length < 2) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (_, _) {
        final ms = player.state.position.inMilliseconds;
        final c = chapters.lastWhere((c) => c.offsetMs <= ms, orElse: () => chapters.first);
        return Text(
          '•  ${c.category.isNotEmpty ? c.category : c.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        );
      },
    );
  }
}

/// Seek bar with chat heat map, chapter gaps and storyboard hover preview.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.player, required this.extras, required this.onInteract, this.onDragging});
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
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
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
            onHorizontalDragStart: (d) => _dragTo(d.localPosition.dx, w, start: true),
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
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: StreamBuilder<Duration>(
                    stream: widget.player.stream.position,
                    builder: (_, _) {
                      final dur = _durationMs;
                      final pos = dur > 0 ? widget.extras.positionMs(widget.player) / dur : 0.0;
                      final buf = dur > 0 ? widget.player.state.buffer.inMilliseconds / dur : 0.0;
                      return CustomPaint(
                        painter: _SeekPainter(
                          progress: _dragFrac ?? pos,
                          buffered: buf,
                          hoverFrac: _hoverX == null ? null : _hoverX! / w,
                          expanded: hovering,
                          activity: widget.extras.activity,
                          activityBucketMs: widget.extras.activityBucketMs,
                          durationMs: dur,
                          chapters: [for (final c in vod.chapters) if (c.offsetMs > 0) c.offsetMs],
                        ),
                      );
                    },
                  ),
                ),
                if (hovering) _preview(w),
              ]),
            ),
          ),
        );
      });

  Widget _preview(double w) {
    final x = _dragFrac != null ? _dragFrac! * w : _hoverX!;
    final ms = (x / w * _durationMs).round();
    final sb = vod.storyboard;
    const tw = 192.0, th = 108.0;
    final chapter = vod.chapters.length > 1 ? vod.chapters.lastWhere((c) => c.offsetMs <= ms, orElse: () => vod.chapters.first) : null;
    final left = (x - tw / 2).clamp(0.0, math.max(0.0, w - tw)).toDouble();
    return Positioned(
      left: left,
      bottom: 34,
      child: IgnorePointer(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (sb.available)
            Container(
              width: tw,
              height: th,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16)],
              ),
              clipBehavior: Clip.antiAlias,
              child: _StoryboardTile(vod: vod, ms: ms, width: tw - 4, height: th - 4),
            ),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxWidth: tw),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (chapter != null)
                Text(chapter.category.isNotEmpty ? chapter.category : chapter.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
              Text(fmtDuration(ms), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StoryboardTile extends StatelessWidget {
  const _StoryboardTile({required this.vod, required this.ms, required this.width, required this.height});
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
    final url = Api.instance.url('${vod.base}storyboard/${sheet.toString().padLeft(3, '0')}.jpg');
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width * sb.cols,
        maxWidth: width * sb.cols,
        minHeight: height * sb.rows,
        maxHeight: height * sb.rows,
        child: Transform.translate(
          offset: Offset(-col * width, -row * height),
          child: Image.network(url, width: width * sb.cols, height: height * sb.rows, fit: BoxFit.fill, gaplessPlayback: true, webHtmlElementStrategy: WebHtmlElementStrategy.fallback),
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
          ..shader = const LinearGradient(colors: [C.primary, C.pink]).createShader(Rect.fromLTWH(0, 0, w, size.height))
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
    RRect bar(double from, double to) => RRect.fromLTRBR(from * w, y - trackH / 2, to * w, y + trackH / 2, r);
    canvas.drawRRect(bar(0, 1), Paint()..color = Colors.white24);
    canvas.drawRRect(bar(0, buffered.clamp(0, 1)), Paint()..color = Colors.white38);
    if (hoverFrac != null) canvas.drawRRect(bar(0, hoverFrac!.clamp(0, 1)), Paint()..color = Colors.white30);
    canvas.drawRRect(
      bar(0, progress.clamp(0, 1)),
      Paint()..shader = const LinearGradient(colors: [C.primary, C.pink]).createShader(Rect.fromLTWH(0, 0, math.max(1, progress * w), 1)),
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
    canvas.drawCircle(Offset(kx, y), expanded ? 11 : 8, Paint()..color = C.pink.withValues(alpha: 0.35));
    canvas.drawCircle(Offset(kx, y), expanded ? 7 : 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekPainter o) =>
      o.progress != progress || o.buffered != buffered || o.hoverFrac != hoverFrac || o.expanded != expanded || o.activity != activity || o.durationMs != durationMs;
}
