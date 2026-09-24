import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../theme.dart';
import 'app_update.dart';
import 'update_service.dart';

/// Update dialog flow. Started from the settings only; the app never checks
/// on its own.
class AppUpdateFlow {
  AppUpdateFlow({AppUpdateService? service}) : service = service ?? AppUpdateService();
  final AppUpdateService service;

  void close() => service.close();

  Future<void> check(BuildContext context) async {
    await service.cleanupCachedFiles();
    final result = await service.check();
    if (!context.mounted) return;
    switch (result.status) {
      case AppUpdateStatus.available:
        await _offer(context, result.info!);
      case AppUpdateStatus.current:
        _snack(context, 'Du bist aktuell (${result.currentVersion}).');
      case AppUpdateStatus.error:
        _snack(context, result.error ?? 'Update-Suche fehlgeschlagen.');
    }
  }

  Future<void> _offer(BuildContext context, AppUpdateInfo info) async {
    final installable = AppUpdateService.supported && info.installable;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('rewind ${info.version} verfügbar'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 360),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (info.notes.isNotEmpty) Text(info.notes, style: const TextStyle(color: C.muted, height: 1.45)),
              if (installable) ...[
                const SizedBox(height: 14),
                Text(
                  Theme.of(ctx).platform == TargetPlatform.windows
                      ? 'Das Setup wird geladen, gegen die Prüfsumme geprüft und still installiert. rewind schließt sich dabei und startet neu.'
                      : 'Die APK wird geladen und gegen die Prüfsumme geprüft. Beim ersten Mal fragt Android, ob rewind Apps installieren darf.',
                  style: const TextStyle(color: C.faint, fontSize: 12.5, height: 1.4),
                ),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Später')),
          if (info.releaseUrl != null) TextButton(onPressed: () => Navigator.pop(ctx, 'open'), child: const Text('Release öffnen')),
          if (installable) FilledButton(onPressed: () => Navigator.pop(ctx, 'install'), child: const Text('Installieren')),
        ],
      ),
    );
    if (!context.mounted) return;
    if (action == 'open') {
      await launchUrl(info.releaseUrl!, mode: LaunchMode.externalApplication);
    } else if (action == 'install') {
      await _downloadAndInstall(context, info);
    }
  }

  Future<void> _downloadAndInstall(BuildContext context, AppUpdateInfo info) async {
    final progress = ValueNotifier<(int, int)>((0, info.size));
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('rewind ${info.version} wird geladen'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: p.$2 > 0 ? p.$1 / p.$2 : null, color: C.primary, backgroundColor: C.surface3),
              const SizedBox(height: 10),
              Text('${fmtBytes(p.$1)} von ${fmtBytes(p.$2)}', style: const TextStyle(color: C.muted)),
            ]),
          ),
          actions: [TextButton(onPressed: service.cancelDownload, child: const Text('Abbrechen'))],
        ),
      ),
    );
    try {
      final file = await service.download(info, (r, t) => progress.value = (r, t));
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      await service.install(file);
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _snack(context, '$e');
      }
    } finally {
      progress.dispose();
    }
  }

  void _snack(BuildContext context, String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
