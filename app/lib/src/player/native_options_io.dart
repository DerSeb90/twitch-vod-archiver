import 'package:media_kit/media_kit.dart';

/// mpv/ffmpeg would start a growing HLS playlist 3 segments before its end and
/// count the position from there. Starting at 0 keeps positions on the
/// recording timeline (chat, chapters); the player page then jumps to the edge.
Future<void> startLivePlaylistsAtZero(Player player) async {
  final platform = player.platform;
  if (platform is NativePlayer) {
    await platform.setProperty('demuxer-lavf-o', 'live_start_index=0');
  }
}
