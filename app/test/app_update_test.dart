import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/update/app_update.dart';

Map<String, dynamic> release(List<String> names, {String? digest = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}) => {
      'tag_name': 'v1.2.0',
      'body': 'Neu',
      'html_url': 'https://github.com/DerSeb90/twitch-vod-archiver/releases/tag/v1.2.0',
      'assets': [
        for (final n in names)
          {'name': n, 'browser_download_url': 'https://example.com/$n', 'size': 100, 'digest': digest},
      ],
    };

void main() {
  test('version compare', () {
    expect(AppVersion.tryParse('v1.10.0')! > AppVersion.tryParse('1.9.9')!, isTrue);
    expect(AppVersion.tryParse('1.0')!.compareTo(AppVersion.tryParse('1.0.0')!), 0);
    expect(AppVersion.tryParse('1.0.0')! > AppVersion.tryParse('1.0.0')!, isFalse);
  });

  test('picks the APK for the device ABI, falls back to universal', () {
    final names = ['app-arm64-v8a-release.apk', 'app-armeabi-v7a-release.apk', 'Rewind-Setup-1.2.0.exe'];
    expect(AppUpdateInfo.fromRelease(release(names), 'arm64-v8a').fileName, 'app-arm64-v8a-release.apk');
    expect(AppUpdateInfo.fromRelease(release(['app-release.apk']), 'x86_64').fileName, 'app-release.apk');
  });

  test('picks the Windows setup', () {
    final info = AppUpdateInfo.fromRelease(release(['app-arm64-v8a-release.apk', 'Rewind-Setup-1.2.0.exe']), kWindowsAbi);
    expect(info.fileName, 'Rewind-Setup-1.2.0.exe');
    expect(info.installable, isTrue);
  });

  test('rejects assets without checksum', () {
    expect(() => AppUpdateInfo.fromRelease(release(['app-arm64-v8a-release.apk'], digest: null), 'arm64-v8a'), throwsFormatException);
  });
}
