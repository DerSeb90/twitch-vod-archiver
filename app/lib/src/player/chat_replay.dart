import 'package:flutter/material.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Loads chat chunks on demand and keeps the list of messages that are
/// "visible" at the current playback position.
class ChatReplayController extends ChangeNotifier {
  ChatReplayController(this.vod);
  final Vod vod;

  Map<String, String> emotes = const {};
  Map<String, String> badges = const {};
  final visible = <ChatMessage>[];

  final _chunks = <int, List<ChatMessage>>{};
  final _loading = <int>{};
  int _lastPos = -1;
  bool _disposed = false;
  static const _maxVisible = 250;

  int get chunkMs => vod.chatChunkMs > 0 ? vod.chatChunkMs : 300000;
  int get _chunkCount => vod.durationMs ~/ chunkMs + 1;

  Future<void> init() async {
    try {
      final r = await Future.wait([
        Api.instance.mediaJson('${vod.base}emotes.json'),
        Api.instance.mediaJson('${vod.base}badges.json'),
      ]);
      emotes = Map<String, String>.from(r[0] as Map);
      badges = Map<String, String>.from(r[1] as Map);
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  void _ensure(int idx) {
    if (idx < 0 || idx >= _chunkCount || _chunks.containsKey(idx) || _loading.contains(idx)) return;
    _loading.add(idx);
    Api.instance.mediaJson('${vod.base}chat/${idx.toString().padLeft(4, '0')}.json.gz').then((j) {
      _chunks[idx] = [for (final m in j as List) ChatMessage.fromJson(m as Map<String, dynamic>)];
      _loading.remove(idx);
      _lastPos = -1; // rebuild with the new data on the next tick
    }).catchError((_) {
      _loading.remove(idx);
    });
  }

  /// Called periodically with the player position.
  void update(int positionMs) {
    if (_disposed) return;
    final pos = positionMs - Settings.instance.chatDelayMs;
    final idx = (pos ~/ chunkMs).clamp(0, _chunkCount - 1);
    _ensure(idx);
    if (pos % chunkMs > chunkMs - 60000) _ensure(idx + 1);

    var changed = false;
    if (_lastPos < 0 || pos < _lastPos || pos - _lastPos > 5000) {
      // seek: rebuild from the current and previous chunk
      _ensure(idx - 1);
      visible.clear();
      for (final c in [idx - 1, idx]) {
        for (final m in _chunks[c] ?? const <ChatMessage>[]) {
          if (m.t <= pos) visible.add(m);
        }
      }
      if (visible.length > _maxVisible) visible.removeRange(0, visible.length - _maxVisible);
      changed = true;
    } else if (pos > _lastPos) {
      for (var c = (_lastPos ~/ chunkMs); c <= idx; c++) {
        for (final m in _chunks[c] ?? const <ChatMessage>[]) {
          if (m.t > _lastPos && m.t <= pos) {
            visible.add(m);
            changed = true;
          }
        }
      }
      if (visible.length > _maxVisible) visible.removeRange(0, visible.length - _maxVisible);
    }
    _lastPos = pos;
    if (changed) notifyListeners();
  }

  void reset() => _lastPos = -1;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ChatPanel extends StatelessWidget {
  const ChatPanel({super.key, required this.controller, this.header = true, this.onClose});
  final ChatReplayController controller;
  final bool header;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(color: C.surface, border: Border(left: BorderSide(color: C.border))),
        child: Column(children: [
          if (header)
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.border))),
              child: Row(children: [
                const Icon(Icons.forum_rounded, size: 18, color: C.primarySoft),
                const SizedBox(width: 10),
                const Text('Chat-Replay', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text(fmtCount(controller.vod.chatCount), style: const TextStyle(color: C.faint, fontSize: 12)),
                const Spacer(),
                _DelayButton(controller: controller),
                if (onClose != null) IconButton(tooltip: 'Chat ausblenden', onPressed: onClose, icon: const Icon(Icons.keyboard_tab_rounded, size: 20, color: C.muted)),
              ]),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, Settings.instance]),
              builder: (context, _) {
                final msgs = controller.visible;
                if (msgs.isEmpty) {
                  return Center(
                    child: Text(controller.vod.chatCount == 0 ? 'Kein Chat aufgezeichnet' : 'Chat startet gleich…', style: const TextStyle(color: C.faint)),
                  );
                }
                final ts = Settings.instance.chatTimestamps;
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[msgs.length - 1 - i];
                    return ChatLine(key: ValueKey(m), msg: m, emotes: controller.emotes, badges: controller.badges, timestamp: ts);
                  },
                );
              },
            ),
          ),
        ]),
      );
}

class _DelayButton extends StatelessWidget {
  const _DelayButton({required this.controller});
  final ChatReplayController controller;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
        tooltip: 'Chat-Versatz',
        icon: const Icon(Icons.more_time_rounded, size: 20, color: C.muted),
        onSelected: (v) {
          if (v == 99999) {
            Settings.instance.chatTimestamps = !Settings.instance.chatTimestamps;
            return;
          }
          Settings.instance.chatDelayMs = v == 0 ? 0 : Settings.instance.chatDelayMs + v;
          controller.reset();
        },
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, child: Text('Versatz: ${(Settings.instance.chatDelayMs / 1000).toStringAsFixed(0)} s')),
          const PopupMenuItem(value: -5000, child: Text('Chat 5 s früher')),
          const PopupMenuItem(value: 5000, child: Text('Chat 5 s später')),
          const PopupMenuItem(value: 0, child: Text('Versatz zurücksetzen')),
          const PopupMenuDivider(),
          PopupMenuItem(value: 99999, child: Text(Settings.instance.chatTimestamps ? 'Zeitstempel ausblenden' : 'Zeitstempel anzeigen')),
        ],
      );
}

/// One rendered chat message with badges, colored name and emotes.
class ChatLine extends StatelessWidget {
  const ChatLine({super.key, required this.msg, required this.emotes, required this.badges, this.timestamp = false});
  final ChatMessage msg;
  final Map<String, String> emotes, badges;
  final bool timestamp;

  static const _fallbackColors = [
    Color(0xFFFF7A7A), Color(0xFF7AB8FF), Color(0xFF7CFF9B), Color(0xFFFFB86B), Color(0xFFD69CFF),
    Color(0xFF6FF0E0), Color(0xFFFF8FD8), Color(0xFFF5E663), Color(0xFF9DA8FF), Color(0xFFB4F07A),
  ];

  Color get _nameColor {
    Color c;
    if (msg.color.length == 7 && msg.color.startsWith('#')) {
      c = Color(int.parse(msg.color.substring(1), radix: 16) | 0xFF000000);
    } else {
      c = _fallbackColors[msg.name.hashCode.abs() % _fallbackColors.length];
    }
    // brighten colors that are unreadable on the dark background
    final hsl = HSLColor.fromColor(c);
    return hsl.lightness < 0.55 ? hsl.withLightness(0.62).toColor() : c;
  }

  @override
  Widget build(BuildContext context) {
    final nameColor = _nameColor;
    final spans = <InlineSpan>[];
    if (timestamp) {
      spans.add(TextSpan(text: '${fmtDuration(msg.t)}  ', style: const TextStyle(color: C.faint, fontSize: 11.5, fontFeatures: [FontFeature.tabularFigures()])));
    }
    for (final b in msg.badges) {
      final url = badges[b];
      if (url == null) continue;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(padding: const EdgeInsets.only(right: 4), child: Tooltip(message: b.split('/').first, child: NetImg(url, width: 18, height: 18, fit: BoxFit.contain))),
      ));
    }
    if (msg.name.isNotEmpty) {
      spans.add(TextSpan(text: msg.name, style: TextStyle(color: nameColor, fontWeight: FontWeight.w700)));
      spans.add(TextSpan(text: msg.action ? ' ' : ': '));
    }
    spans.addAll(_messageSpans(msg.action ? TextStyle(color: nameColor, fontStyle: FontStyle.italic) : null));

    final body = Text.rich(TextSpan(children: spans), style: const TextStyle(fontSize: 13.5, height: 1.55, color: C.text));
    if (msg.system.isNotEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: C.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: const Border(left: BorderSide(color: C.primary, width: 3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(msg.system, style: const TextStyle(color: C.primarySoft, fontWeight: FontWeight.w600, fontSize: 12.5)),
          if (msg.text.isNotEmpty) ...[const SizedBox(height: 4), body],
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (msg.reply.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: Text('↪ Antwort an @${msg.reply}', style: const TextStyle(color: C.faint, fontSize: 11.5)),
          ),
        body,
      ]),
    );
  }

  List<InlineSpan> _messageSpans(TextStyle? style) {
    final runes = msg.text.runes.toList();
    final out = <InlineSpan>[];
    var cursor = 0;
    void text(int from, int to) {
      if (to <= from) return;
      final s = String.fromCharCodes(runes.sublist(from, to));
      _thirdParty(s, out, style);
    }

    for (final (id, start, end) in msg.emotes) {
      if (start < cursor || end >= runes.length) continue;
      text(cursor, start);
      final name = String.fromCharCodes(runes.sublist(start, end + 1));
      out.add(_emote('https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/2.0', name));
      cursor = end + 1;
    }
    text(cursor, runes.length);
    return out;
  }

  void _thirdParty(String s, List<InlineSpan> out, TextStyle? style) {
    if (emotes.isEmpty) {
      out.add(TextSpan(text: s, style: style));
      return;
    }
    final buf = StringBuffer();
    for (final word in s.split(' ')) {
      final url = emotes[word];
      if (url != null) {
        if (buf.isNotEmpty) {
          out.add(TextSpan(text: buf.toString(), style: style));
          buf.clear();
        }
        out.add(_emote(url, word));
        buf.write(' ');
      } else {
        buf
          ..write(word)
          ..write(' ');
      }
    }
    var rest = buf.toString();
    if (rest.endsWith(' ')) rest = rest.substring(0, rest.length - 1);
    if (rest.isNotEmpty) out.add(TextSpan(text: rest, style: style));
  }

  InlineSpan _emote(String url, String name) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Tooltip(
          message: name,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: NetImg(url, height: 28, fit: BoxFit.contain)),
        ),
      );
}
