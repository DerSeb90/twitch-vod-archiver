import 'app_update.dart';

/// Web build: no in-app updates (the web app comes with the server image).
class AppUpdateService {
  AppUpdateService();

  static bool get supported => false;
  static bool get available => false;

  Future<String> installedVersion() async => '';
  Future<AppUpdateResult> check() async => AppUpdateResult.error('Updates gibt es nur in den Apps.');
  Future<Object> download(AppUpdateInfo info, UpdateProgress onProgress) async => throw const AppUpdateException('Nicht unterstützt.');
  Future<void> install(Object file) async {}
  void cancelDownload() {}
  Future<void> cleanupCachedFiles() async {}
  void close() {}
}
