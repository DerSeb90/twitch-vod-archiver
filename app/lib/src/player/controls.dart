import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../format.dart';
import '../models.dart';
import '../settings.dart';
import '../theme.dart';
import 'nerd_stats.dart';
import 'player_extras.dart';
import 'seek_bar.dart';

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

  /// Volume to go back to when unmuting (button and M key alike).
  double _unmuted = 100;

  void _toggleMute() {
    final v = player.state.volume;
    if (v > 0) {
      _unmuted = v;
      _setVolume(0);
    } else {
      _setVolume(_unmuted);
    }
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
      _toggleMute();
    } else if (k == LogicalKeyboardKey.keyI) {
      widget.extras.nerdStats.value = !widget.extras.nerdStats.value;
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
          // stats for nerds
          ValueListenableBuilder<bool>(
            valueListenable: widget.extras.nerdStats,
            builder: (_, on, _) => on
                ? Positioned(left: 12, top: fullscreen ? 64 : 12, child: NerdStats(player: player, extras: widget.extras))
                : const SizedBox.shrink(),
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
        _VolumeControl(player: player, onChanged: _setVolume, onToggleMute: _toggleMute),
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
      if (!compact) Expanded(child: _CurrentChapter(player: player, vod: widget.extras.vod)) else const Spacer(),
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
  const _VolumeControl({required this.player, required this.onChanged, required this.onToggleMute});
  final Player player;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;
  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  bool _hover = false;

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
                onTap: widget.onToggleMute,
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

class _CurrentChapter extends StatelessWidget {
  const _CurrentChapter({required this.player, required this.vod});
  final Player player;
  final Vod vod;

  @override
  Widget build(BuildContext context) {
    if (vod.chapterAt(0) == null) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (_, _) {
        final c = vod.chapterAt(player.state.position.inMilliseconds)!;
        return Text(
          '•  ${c.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        );
      },
    );
  }
}
