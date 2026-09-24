import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:media_kit/media_kit.dart';

import 'src/progress.dart';
import 'src/router.dart';
import 'src/sync.dart';
import 'src/settings.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  MediaKit.ensureInitialized();
  await Settings.load();
  WatchProgress.instance.migrateLocal();
  LiveSync.instance.start();
  AppVersion.load();
  runApp(const RewindApp());
}

class RewindApp extends StatefulWidget {
  const RewindApp({super.key});
  @override
  State<RewindApp> createState() => _RewindAppState();
}

class _RewindAppState extends State<RewindApp> {
  // back in the foreground: catch up with changes from other devices at once
  late final _lifecycle = AppLifecycleListener(onResume: LiveSync.instance.poke);

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'rewind',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        darkTheme: buildTheme(),
        themeMode: ThemeMode.dark,
        routerConfig: router,
      );
}
