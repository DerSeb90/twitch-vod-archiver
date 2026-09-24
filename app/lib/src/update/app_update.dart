// In-app updates from GitHub Releases (same scheme as CastQueue).
// Pure Dart (no dart:io), so it also compiles for the web build; the
// platform part lives in update_service_io.dart.

const String kUpdateRepository = 'DerSeb90/twitch-vod-archiver';

/// Android: per-ABI APKs from `flutter build apk --split-per-abi`, universal as fallback.
final RegExp kReleaseApkName = RegExp(r'^app-(?:(arm64-v8a|armeabi-v7a|x86_64|x86)-)?release\.apk$');

/// Windows: Inno Setup installer (app/windows/installer/rewind.iss).
final RegExp kReleaseSetupName = RegExp(r'^Rewind-Setup-.*\.exe$');

const String kWindowsAbi = 'windows';

enum AppUpdateStatus { available, current, error }

class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.parts);
  final List<int> parts;

  static AppVersion? tryParse(String raw) {
    final match = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion(match.group(1)!.split('.').map(int.parse).toList(growable: false));
  }

  @override
  int compareTo(AppVersion other) {
    final length = parts.length > other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < length; i++) {
      final mine = i < parts.length ? parts[i] : 0;
      final theirs = i < other.parts.length ? other.parts[i] : 0;
      if (mine != theirs) return mine.compareTo(theirs);
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  String toString() => parts.join('.');
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.tag,
    required this.url,
    required this.fileName,
    required this.sha256,
    required this.size,
    required this.notes,
    required this.releaseUrl,
    required this.date,
  });

  final AppVersion version;
  final String tag;
  final Uri? url;
  final String fileName;
  final String sha256;
  final int size;
  final String notes;
  final Uri? releaseUrl;
  final DateTime? date;

  bool get installable => url != null && sha256.isNotEmpty && size > 0;

  /// Parses a `releases/latest` response. [abi] is an Android ABI or
  /// [kWindowsAbi]. With [requireAsset] false a release without a matching
  /// file is still returned (browser-only update).
  factory AppUpdateInfo.fromRelease(Map<String, dynamic> json, String abi, {bool requireAsset = true}) {
    final tag = json['tag_name']?.toString().trim() ?? '';
    final version = AppVersion.tryParse(tag);
    if (version == null) throw const FormatException('Release ohne erkennbare Versionsnummer.');
    final notes = json['body']?.toString().trim() ?? '';
    final releaseUrl = Uri.tryParse(json['html_url']?.toString() ?? '');
    final date = DateTime.tryParse(json['published_at']?.toString() ?? '');

    final windows = abi == kWindowsAbi;
    final what = windows ? 'Setup' : 'APK';
    final pattern = windows ? kReleaseSetupName : kReleaseApkName;
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((a) => pattern.hasMatch(a['name']?.toString() ?? ''))
        .toList(growable: false);
    if (assets.isEmpty) {
      if (requireAsset) throw FormatException(windows ? 'Das Release enthält kein rewind-Setup.' : 'Das Release enthält keine rewind-APK.');
      return AppUpdateInfo(version: version, tag: tag, url: null, fileName: '', sha256: '', size: 0, notes: notes, releaseUrl: releaseUrl, date: date);
    }
    final asset = windows
        ? assets.first
        : assets.firstWhere(
            (a) => a['name'].toString() == 'app-$abi-release.apk',
            orElse: () => assets.firstWhere(
              (a) => a['name'].toString() == 'app-release.apk',
              orElse: () => throw FormatException('Keine APK für $abi im Release.'),
            ),
          );
    // GitHub computes a SHA-256 digest for every release asset
    final digest = asset['digest']?.toString().trim().toLowerCase() ?? '';
    final hash = digest.startsWith('sha256:') ? digest.substring(7) : '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) throw FormatException('Release-$what ohne SHA-256-Prüfsumme.');
    final url = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
    final size = (asset['size'] as num?)?.toInt() ?? 0;
    if (url == null || !url.hasScheme || size < 1) throw FormatException('Release-$what ohne gültigen Download.');
    return AppUpdateInfo(
      version: version,
      tag: tag,
      url: url,
      fileName: asset['name'].toString(),
      sha256: hash,
      size: size,
      notes: notes,
      releaseUrl: releaseUrl,
      date: date,
    );
  }
}

class AppUpdateResult {
  const AppUpdateResult._(this.status, {this.info, this.currentVersion, this.error});
  factory AppUpdateResult.available(AppUpdateInfo info, String current) => AppUpdateResult._(AppUpdateStatus.available, info: info, currentVersion: current);
  factory AppUpdateResult.current(String current, {AppUpdateInfo? info}) => AppUpdateResult._(AppUpdateStatus.current, info: info, currentVersion: current);
  factory AppUpdateResult.error(String message) => AppUpdateResult._(AppUpdateStatus.error, error: message);

  final AppUpdateStatus status;
  final AppUpdateInfo? info;
  final String? currentVersion;
  final String? error;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef UpdateProgress = void Function(int received, int total);
