import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'settings.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

/// Thin client for the Go server. All paths returned by the server
/// (/media/..., /avatars/...) are resolved against [base].
class Api {
  Api._();
  static final Api instance = Api._();

  final _client = http.Client();
  final _jsonCache = <String, Future<dynamic>>{};

  String get base => Settings.instance.serverUrl;

  String url(String path) {
    if (path.isEmpty || path.startsWith('http://') || path.startsWith('https://')) return path;
    return '$base$path';
  }

  Map<String, String> get _headers {
    final t = Settings.instance.adminToken;
    return {
      'Accept': 'application/json',
      if (t.isNotEmpty) 'Authorization': 'Bearer $t',
    };
  }

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final uri = Uri.parse(url(path)).replace(queryParameters: query?.isEmpty ?? true ? null : query);
    final req = http.Request(method, uri)..headers.addAll(_headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 30)));
    if (res.statusCode >= 400) {
      var msg = res.reasonPhrase ?? 'HTTP ${res.statusCode}';
      try {
        msg = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['error'] as String? ?? msg;
      } catch (_) {}
      throw ApiException(res.statusCode, msg);
    }
    if (res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<ServerInfo> info() async => ServerInfo.fromJson(await _send('GET', '/api/info'));

  Future<bool> checkAdmin() async {
    try {
      await _send('POST', '/api/auth');
      return true;
    } on ApiException catch (e) {
      if (e.status == 401) return false;
      rethrow;
    }
  }

  Future<List<Channel>> channels() async =>
      [for (final c in await _send('GET', '/api/channels') as List) Channel.fromJson(c)];

  Future<Channel> channel(String login) async => Channel.fromJson(await _send('GET', '/api/channels/$login'));

  Future<Channel> addChannel(String login) async =>
      Channel.fromJson(await _send('POST', '/api/channels', body: {'login': login}));

  Future<void> setChannelEnabled(String id, bool enabled) => _send('PATCH', '/api/channels/$id', body: {'enabled': enabled});

  Future<void> deleteChannel(String id, {bool purge = false}) =>
      _send('DELETE', '/api/channels/$id', query: purge ? {'purge': '1'} : null);

  Future<List<LiveRecording>> live() async =>
      [for (final l in await _send('GET', '/api/live') as List) LiveRecording.fromJson(l)];

  Future<VodPage> vods({String? channel, String? query, String? status, List<String>? ids, int limit = 48, int offset = 0}) async {
    final j = await _send('GET', '/api/vods', query: {
      'channel': ?channel,
      if (query != null && query.isNotEmpty) 'q': query,
      'status': ?status,
      if (ids != null) 'ids': ids.join(','),
      'limit': '$limit',
      'offset': '$offset',
    }) as Map<String, dynamic>;
    return VodPage([for (final v in j['items'] as List) Vod.fromJson(v)], (j['total'] as num).toInt());
  }

  Future<Vod> vod(String id) async => Vod.fromJson(await _send('GET', '/api/vods/$id'));

  Future<void> deleteVod(String id) => _send('DELETE', '/api/vods/$id');

  Future<void> retryVod(String id) => _send('POST', '/api/vods/$id/retry');

  Future<void> pauseRecording(String channelId) => _send('POST', '/api/recordings/$channelId/pause');
  Future<void> resumeRecording(String channelId) => _send('POST', '/api/recordings/$channelId/resume');
  Future<void> finishRecording(String channelId) => _send('POST', '/api/recordings/$channelId/finish');

  /// Uncached GET for data that still changes (live chat chunks).
  Future<dynamic> freshJson(String path) async {
    final res = await _client.get(Uri.parse(url(path))).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'HTTP ${res.statusCode}');
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// Static JSON under a VOD's media dir; immutable, therefore cached.
  Future<dynamic> mediaJson(String path) {
    final u = url(path);
    return _jsonCache.putIfAbsent(u, () async {
      final res = await _client.get(Uri.parse(u)).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        _jsonCache.remove(u);
        throw ApiException(res.statusCode, 'HTTP ${res.statusCode}');
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    });
  }
}
