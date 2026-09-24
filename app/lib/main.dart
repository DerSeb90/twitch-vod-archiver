import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:media_kit/media_kit.dart';

import 'src/progress.dart';
import 'src/router.dart';
import 'src/settings.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  MediaKit.ensureInitialized();
  await Settings.load();
  WatchProgress.instance.migrateLocal();
  runApp(const RewindApp());
}

class RewindApp extends StatelessWidget {
  const RewindApp({super.key});

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
