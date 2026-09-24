import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';

class AppUpdateService {
  AppUpdateService({this.repository = kUpdateRepository, http.Client? client, String? abi, Future<String> Function()? installedVersion, bool? requireAsset})
      : _client = client ?? http.Client(),
        _abi = abi ?? currentAbi(),
        _installedVersion = installedVersion ?? _packageVersion,
        _requireAsset = requireAsset ?? supported;

  final String repository;
  final http.Client _client;
  final String _abi;
  final Future<String> Function() _installedVersion;
  final bool _requireAsset;
  bool _cancelDownload = false;

  /// Direct download + install works on Android and Windows.
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  /// Other native platforms still get the check (they open the release page).
  static bool get available => true;

  Uri get latestReleaseUri => Uri.parse('https://api.github.com/repos/$repository/releases/latest');

  static String currentAbi() {
    if (Platform.isWindows) return kWindowsAbi;
    final abi = Abi.current();
    if (abi == Abi.androidArm64) return 'arm64-v8a';
    if (abi == Abi.androidArm) return 'armeabi-v7a';
    if (abi == Abi.androidX64) return 'x86_64';
    if (abi == Abi.androidIA32) return 'x86';
    return 'arm64-v8a';
  }

  static Future<String> _packageVersion() async => (await PackageInfo.fromPlatform()).version;

  Future<String> installedVersion() => _installedVersion();

  Future<AppUpdateResult> check() async {
    try {
      final current = await _installedVersion();
      final local = AppVersion.tryParse(current) ?? const AppVersion([0]);
      final response = await _client.get(latestReleaseUri, headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      }).timeout(const Duration(seconds: 10));
      if (response.statusCode == HttpStatus.notFound) throw const AppUpdateException('Noch kein Release veröffentlicht.');
      if (response.statusCode != HttpStatus.ok) throw AppUpdateException('GitHub antwortet mit HTTP ${response.statusCode}.');
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('Release-Antwort hat ein ungültiges Format.');
      final info = AppUpdateInfo.fromRelease(decoded, _abi, requireAsset: _requireAsset);
      if (info.version > local) return AppUpdateResult.available(info, current);
      return AppUpdateResult.current(current, info: info);
    } catch (e) {
      return AppUpdateResult.error(_friendlyError(e));
    }
  }

  String _friendlyError(Object e) {
    if (e is AppUpdateException) return e.message;
    if (e is FormatException) return e.message;
    if (e is TimeoutException) return 'Zeitüberschreitung bei GitHub.';
    return 'GitHub ist nicht erreichbar.';
  }

  void cancelDownload() => _cancelDownload = true;

  /// Downloads the asset to the temp dir and verifies its SHA-256.
  Future<File> download(AppUpdateInfo info, UpdateProgress onProgress) async {
    final url = info.url;
    if (url == null) throw const AppUpdateException('Kein Download im Release.');
    _cancelDownload = false;
    final dir = await getTemporaryDirectory();
    final file = _abi == kWindowsAbi ? File('${dir.path}/rewind-update-${info.tag}.exe') : File('${dir.path}/rewind-update-${info.tag}-$_abi.apk');
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();
    var received = 0;
    try {
      final response = await _client.send(http.Request('GET', url)).timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) throw AppUpdateException('Download fehlgeschlagen (HTTP ${response.statusCode}).');
      final total = (response.contentLength ?? 0) > 0 ? response.contentLength! : info.size;
      await for (final chunk in response.stream) {
        if (_cancelDownload) throw const AppUpdateException('Download abgebrochen.');
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != info.sha256) {
        throw const AppUpdateException('Die Prüfsumme der Datei stimmt nicht. Sie wurde verworfen.');
      }
      return file;
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await file.exists()) await file.delete();
      if (e is AppUpdateException) rethrow;
      throw AppUpdateException(_friendlyError(e));
    }
  }

  /// Android: hands the APK to the system installer.
  /// Windows: runs the setup silently and exits; the setup relaunches the app.
  Future<void> install(File file) async {
    if (!supported) throw const AppUpdateException('Die direkte Installation gibt es nur unter Android und Windows.');
    if (Platform.isWindows) {
      try {
        await Process.start(file.path, const ['/VERYSILENT', '/NORESTART', '/CLOSEAPPLICATIONS', '/SP-'], mode: ProcessStartMode.detached);
      } on ProcessException catch (e) {
        throw AppUpdateException('Setup konnte nicht gestartet werden: ${e.message}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      exit(0);
    }
    final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      throw AppUpdateException(result.message.isEmpty ? 'Android-Installer konnte nicht geöffnet werden.' : result.message);
    }
  }

  /// Removes leftover update files (best effort; locked files are skipped).
  Future<void> cleanupCachedFiles() async {
    try {
      final dir = await getTemporaryDirectory();
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
        if (e is File && name.startsWith('rewind-update-') && (name.endsWith('.apk') || name.endsWith('.exe'))) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void close() => _client.close();
}
