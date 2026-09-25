import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pages/admin_page.dart';
import 'pages/channel_pages.dart';
import 'pages/home_page.dart';
import 'pages/player_page.dart';
import 'pages/settings_page.dart';
import 'settings.dart';
import 'widgets/shell.dart';

CustomTransitionPage<void> _fade(GoRouterState state, Widget child) => CustomTransitionPage(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: c),
    );

final router = GoRouter(
  // native apps without a configured server start in the settings
  redirect: (context, state) => Settings.instance.serverUrl.isEmpty && state.matchedLocation != '/settings' ? '/settings' : null,
  routes: [
    // management is intentionally outside the viewer shell and its navigation
    GoRoute(path: '/admin', pageBuilder: (_, s) => _fade(s, const AdminPage())),
    ShellRoute(
      builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
      routes: [
        GoRoute(path: '/', pageBuilder: (_, s) => _fade(s, const HomePage())),
        GoRoute(path: '/channels', pageBuilder: (_, s) => _fade(s, const ChannelsPage())),
        GoRoute(path: '/c/:login', pageBuilder: (_, s) => _fade(s, ChannelPage(key: ValueKey(s.pathParameters['login']), login: s.pathParameters['login']!))),
        GoRoute(path: '/v/:id', pageBuilder: (_, s) => _fade(s, PlayerPage(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!))),
        GoRoute(path: '/settings', pageBuilder: (_, s) => _fade(s, const SettingsPage())),
      ],
    ),
  ],
);
