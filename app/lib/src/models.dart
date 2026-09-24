// Plain data classes mirroring the Go API (server/internal/api).

int _i(dynamic v) => (v as num?)?.toInt() ?? 0;
double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;
String _s(dynamic v) => v as String? ?? '';

class Channel {
  final String id, login, displayName, description, avatar, banner;
  final bool enabled, live;
  final int vodCount, totalMs, lastLiveAt;

  Channel.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        login = _s(j['login']),
        displayName = _s(j['displayName']),
        description = _s(j['description']),
        avatar = _s(j['avatar']),
        banner = _s(j['banner']),
        enabled = j['enabled'] == true,
        live = j['live'] == true,
        vodCount = _i(j['vodCount']),
        totalMs = _i(j['totalMs']),
        lastLiveAt = _i(j['lastLiveAt']);
}

class Storyboard {
  final int intervalMs, cols, rows, tileW, tileH, count, sheets;
  Storyboard.fromJson(Map<String, dynamic>? j)
      : intervalMs = _i(j?['intervalMs']),
        cols = _i(j?['cols']),
        rows = _i(j?['rows']),
        tileW = _i(j?['tileW']),
        tileH = _i(j?['tileH']),
        count = _i(j?['count']),
        sheets = _i(j?['sheets']);
  bool get available => intervalMs > 0 && sheets > 0 && cols > 0 && rows > 0;
}

class Chapter {
  final int offsetMs;
  final String title, category, boxArt;
  Chapter.fromJson(Map<String, dynamic> j)
      : offsetMs = _i(j['offsetMs']),
        title = _s(j['title']),
        category = _s(j['category']),
        boxArt = _s(j['boxArt']);
}

class Vod {
  final String id, title, category, status, video, thumbnail, base, videoCodec, processing, error;
  final int startedAt, endedAt, durationMs, sizeBytes, width, height, chatCount, chatChunkMs, peakViewers;
  final double fps;
  /// Still on the server's local disk: played as HLS (live/DVR or paused).
  final bool live, paused;
  /// Watch progress stored on the server (shared by all devices).
  final int positionMs;
  final bool watched;
  /// When this snapshot was fetched (local progress changes after it win).
  final DateTime loadedAt;
  final Channel? channel;
  final Storyboard storyboard;
  final List<Chapter> chapters;

  Vod.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        title = _s(j['title']),
        category = _s(j['category']),
        status = _s(j['status']),
        video = _s(j['video']),
        thumbnail = _s(j['thumbnail']),
        base = _s(j['base']),
        videoCodec = _s(j['videoCodec']),
        processing = _s(j['processing']),
        error = _s(j['error']),
        startedAt = _i(j['startedAt']),
        endedAt = _i(j['endedAt']),
        durationMs = _i(j['durationMs']),
        sizeBytes = _i(j['sizeBytes']),
        width = _i(j['width']),
        height = _i(j['height']),
        chatCount = _i(j['chatCount']),
        chatChunkMs = _i(j['chatChunkMs']),
        peakViewers = _i(j['peakViewers']),
        fps = _d(j['fps']),
        live = j['live'] == true,
        paused = j['paused'] == true,
        positionMs = _i(j['positionMs']),
        watched = j['watched'] == true,
        loadedAt = DateTime.now(),
        channel = j['channel'] is Map<String, dynamic> ? Channel.fromJson(j['channel']) : null,
        storyboard = Storyboard.fromJson(j['storyboard'] as Map<String, dynamic>?),
        chapters = [for (final c in (j['chapters'] as List? ?? const [])) Chapter.fromJson(c as Map<String, dynamic>)];

  bool get ready => status == 'ready';
  bool get playable => ready || live;

  /// Still growing right now (recording and not paused).
  bool get growing => recording && live && !paused;
  bool get recording => status == 'recording';

  String get qualityLabel {
    if (height <= 0) return '';
    final f = fps >= 50 ? fps.round().toString() : '';
    return '${height}p$f';
  }
}

class LiveRecording {
  final String vodId, title, category, thumbnail;
  final int startedAt, viewers, chatCount, parts;
  final bool recording, paused;
  final Channel channel;

  LiveRecording.fromJson(Map<String, dynamic> j)
      : vodId = _s(j['vodId']),
        title = _s(j['title']),
        category = _s(j['category']),
        thumbnail = _s(j['thumbnail']),
        startedAt = _i(j['startedAt']),
        viewers = _i(j['viewers']),
        chatCount = _i(j['chatCount']),
        parts = _i(j['parts']),
        recording = j['recording'] == true,
        paused = j['paused'] == true,
        channel = Channel.fromJson(j['channel'] as Map<String, dynamic>);
}

class ServerInfo {
  final String appName, version;
  final bool adminRequired;
  final int recording, maxConcurrent;
  final int vods, channels, totalMs, totalBytes, chatCount;
  final int localFree, localTotal, archiveFree, archiveTotal;
  final Map<String, String> processing;
  final bool adFreeConfigured, adFreeValid;
  final String adFreeLogin;

  ServerInfo.fromJson(Map<String, dynamic> j)
      : appName = _s(j['appName']),
        version = _s(j['version']),
        adminRequired = j['adminRequired'] == true,
        recording = _i(j['recording']),
        maxConcurrent = _i(j['maxConcurrent']),
        vods = _i(j['stats']?['vods']),
        channels = _i(j['stats']?['channels']),
        totalMs = _i(j['stats']?['totalMs']),
        totalBytes = _i(j['stats']?['totalBytes']),
        chatCount = _i(j['stats']?['chatCount']),
        localFree = _i(j['disk']?['localFree']),
        localTotal = _i(j['disk']?['localTotal']),
        archiveFree = _i(j['disk']?['archiveFree']),
        archiveTotal = _i(j['disk']?['archiveTotal']),
        adFreeConfigured = j['adFree']?['configured'] == true,
        adFreeValid = j['adFree']?['valid'] == true,
        adFreeLogin = _s(j['adFree']?['login']),
        processing = {for (final e in ((j['processing'] as Map?) ?? const {}).entries) e.key as String: e.value as String};
}

class VodPage {
  final List<Vod> items;
  final int total;
  VodPage(this.items, this.total);
}

/// One replay chat line (see server/internal/finalize/chat.go).
class ChatMessage {
  final int t;
  final String name, color, text, system, reply;
  final List<String> badges;
  final List<(String, int, int)> emotes;
  final bool action;

  ChatMessage.fromJson(Map<String, dynamic> j)
      : t = _i(j['t']),
        name = _s(j['n']),
        color = _s(j['c']),
        text = _s(j['m']),
        system = _s(j['s']),
        reply = _s(j['r']),
        action = j['a'] == true,
        badges = [for (final b in (j['b'] as List? ?? const [])) b as String],
        emotes = [
          for (final e in (j['e'] as List? ?? const []))
            ((e as List)[0] as String, _i(e[1]), _i(e[2])),
        ];
}
