import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../format.dart';
import '../models.dart';
import '../sync.dart';
import '../theme.dart';
import 'common.dart';

/// App frame: glass top bar on wide screens, bottom navigation on phones.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;

  static const _tabs = [
    ('/', Icons.home_rounded, 'Start'),
    ('/channels', Icons.grid_view_rounded, 'Kanäle'),
    ('/settings', Icons.tune_rounded, 'Optionen'),
  ];

  static int _indexOf(String location) {
    for (var i = _tabs.length - 1; i > 0; i--) {
      if (location.startsWith(_tabs[i].$1)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    // the top route: after context.push() the shell's own state still
    // names the page below
    final loc = GoRouter.of(context).state.uri.path;
    final index = _indexOf(loc);
    // phones: the player gets the whole height (back via the top bar arrow)
    final player = loc.startsWith('/v/');
    return Scaffold(
      body: Column(children: [
        _TopBar(wide: wide, index: index, back: player),
        Expanded(child: child),
      ]),
      bottomNavigationBar: wide || player
          ? null
          : NavigationBarTheme(
              data: NavigationBarThemeData(
                backgroundColor: C.surface,
                indicatorColor: C.primary.withValues(alpha: 0.2),
                labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                height: 64,
              ),
              child: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (i) => context.go(_tabs[i].$1),
                destinations: [for (final t in _tabs) NavigationDestination(icon: Icon(t.$2), label: t.$3)],
              ),
            ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.wide, required this.index, this.back = false});
  final bool wide, back;
  final int index;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: EdgeInsets.only(top: top),
          decoration: BoxDecoration(color: C.bg.withValues(alpha: 0.82), border: const Border(bottom: BorderSide(color: C.border))),
          child: ContentWidth(
            child: SizedBox(
              height: wide ? 68 : 56,
              child: Row(children: [
                if (back) ...[
                  IconButton(
                    tooltip: 'Zurück',
                    onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 4),
                ],
                const _Logo(),
                if (wide) ...[
                  const SizedBox(width: 28),
                  for (final (i, t) in AppShell._tabs.take(2).indexed) _NavLink(label: t.$3, path: t.$1, active: index == i),
                  const Spacer(),
                  const _LiveBadge(),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Einstellungen',
                    onPressed: () => context.go('/settings'),
                    icon: Icon(Icons.tune_rounded, color: index == 2 ? C.primarySoft : C.muted),
                  ),
                ] else ...[
                  const Spacer(),
                  const _LiveBadge(),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: () => context.go('/'),
        builder: (context, hover) => Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedRotation(
            turns: hover ? -0.08 : 0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(gradient: C.brandGradient, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.fast_rewind_rounded, color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 10),
          const GradientText('rewind', style: TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5)),
          ValueListenableBuilder<String>(
            valueListenable: AppVersion.label,
            builder: (_, v, _) => v.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4),
                    child: Text(v, style: const TextStyle(color: C.faint, fontSize: 12, fontWeight: FontWeight.w500)),
                  ),
          ),
        ]),
      );
}

class _NavLink extends StatelessWidget {
  const _NavLink({required this.label, required this.path, required this.active});
  final String label, path;
  final bool active;

  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: () => context.go(path),
        builder: (context, hover) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: active ? C.surface2 : (hover ? C.surface : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: active ? C.text : C.muted)),
        ),
      );
}

/// "● 2 live" in the top bar while recordings run; opens a list of them.
class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<LiveRecording>>(
        valueListenable: LiveSync.instance.live,
        builder: (context, live, _) {
          if (live.isEmpty) return const SizedBox.shrink();
          final recording = live.where((l) => !l.paused).length;
          return PopupMenuButton<String>(
            tooltip: '${live.length} laufende Aufnahme${live.length == 1 ? '' : 'n'}',
            position: PopupMenuPosition.under,
            color: C.surface2,
            onSelected: (id) => context.push('/v/$id'),
            itemBuilder: (_) => [
              for (final l in live)
                PopupMenuItem(
                  value: l.vodId,
                  child: Row(children: [
                    Avatar(src: l.channel.avatar, size: 32, live: !l.paused),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.channel.displayName, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          [
                            l.paused ? 'pausiert' : 'seit ${fmtDuration(DateTime.now().millisecondsSinceEpoch - l.startedAt)}',
                            if (l.viewers > 0) '${fmtCount(l.viewers)} Zuschauer',
                            if (l.category.isNotEmpty) l.category,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.muted, fontSize: 12),
                        ),
                      ]),
                    ),
                  ]),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: C.live.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: C.live.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (recording > 0) const RecDot(size: 7) else const Icon(Icons.pause_rounded, size: 12, color: C.live),
                const SizedBox(width: 6),
                Text('${live.length} live', style: const TextStyle(color: C.live, fontWeight: FontWeight.w700, fontSize: 12.5)),
              ]),
            ),
          );
        },
      );
}
