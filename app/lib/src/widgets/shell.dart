import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
    ('/search', Icons.search_rounded, 'Suche'),
    ('/settings', Icons.tune_rounded, 'Optionen'),
  ];

  int get _index {
    for (var i = _tabs.length - 1; i > 0; i--) {
      if (location.startsWith(_tabs[i].$1)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Scaffold(
      body: Column(children: [
        _TopBar(wide: wide, index: _index),
        Expanded(child: child),
      ]),
      bottomNavigationBar: wide
          ? null
          : NavigationBarTheme(
              data: NavigationBarThemeData(
                backgroundColor: C.surface,
                indicatorColor: C.primary.withValues(alpha: 0.2),
                labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                height: 64,
              ),
              child: NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: (i) => context.go(_tabs[i].$1),
                destinations: [for (final t in _tabs) NavigationDestination(icon: Icon(t.$2), label: t.$3)],
              ),
            ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.wide, required this.index});
  final bool wide;
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
                const _Logo(),
                if (wide) ...[
                  const SizedBox(width: 28),
                  for (final (i, t) in AppShell._tabs.take(2).indexed) _NavLink(label: t.$3, path: t.$1, active: index == i),
                  const Spacer(),
                  const _SearchField(),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Einstellungen',
                    onPressed: () => context.go('/settings'),
                    icon: Icon(Icons.tune_rounded, color: index == 3 ? C.primarySoft : C.muted),
                  ),
                ] else
                  const Spacer(),
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

class _SearchField extends StatefulWidget {
  const _SearchField();
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        child: TextField(
          controller: _c,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'VODs, Kanäle, Kategorien…',
            prefixIcon: Icon(Icons.search_rounded, size: 20, color: C.faint),
            contentPadding: EdgeInsets.symmetric(vertical: 10),
          ),
          onSubmitted: (q) {
            if (q.trim().isEmpty) return;
            context.go('/search?q=${Uri.encodeQueryComponent(q.trim())}');
          },
        ),
      );
}
