import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../format.dart';
import '../theme.dart';
import 'player_extras.dart';

/// "Stats for nerds" overlay: what the player is doing right now.
class NerdStats extends StatefulWidget {
  const NerdStats({super.key, required this.player, required this.extras});
  final Player player;
  final PlayerExtras extras;
  @override
  State<NerdStats> createState() => NerdStatsState();
}

class NerdStatsState extends State<NerdStats> {
  late final Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player.state;
    final v = widget.extras.vod;
    final vp = p.videoParams, ap = p.audioParams;
    final ahead = (p.buffer - p.position).inMilliseconds / 1000;
    String? val(Object? o) => o == null || '$o'.isEmpty ? null : '$o';
    final rows = <(String, String?)>[
      (
        'Position',
        '${fmtDuration(widget.extras.positionMs(widget.player))} / ${fmtDuration(widget.extras.durationMs(widget.player))}',
      ),
      (
        'Puffer',
        '${ahead.clamp(0, 99999).toStringAsFixed(1).replaceAll('.', ',')} s voraus${p.buffering ? ' · lädt' : ''}',
      ),
      ('Quelle', 'MP4 von der Storage Box'),
      (
        'Video',
        [
          if ((vp.w ?? p.width ?? v.width) > 0)
            '${vp.w ?? p.width ?? v.width}×${vp.h ?? p.height ?? v.height}',
          if (v.fps > 0) '${v.fps.toStringAsFixed(v.fps % 1 == 0 ? 0 : 2)} fps',
          if (v.videoCodec.isNotEmpty) v.videoCodec.toUpperCase(),
        ].join(' · '),
      ),
      (
        'Anzeige',
        vp.dw != null
            ? '${vp.dw}×${vp.dh}${vp.aspect != null ? ' · ${vp.aspect!.toStringAsFixed(3)}' : ''}'
            : null,
      ),
      (
        'Decoder',
        [
          if (val(vp.hwPixelformat) != null)
            'Hardware (${vp.hwPixelformat})'
          else if (val(vp.pixelformat) != null)
            'Software',
          ?val(vp.pixelformat),
          ?val(vp.colormatrix),
        ].join(' · '),
      ),
      (
        'Audio',
        [
          ?val(ap.format),
          if (ap.sampleRate != null) '${ap.sampleRate} Hz',
          ?val(ap.hrChannels ?? ap.channels),
          if (p.audioBitrate != null && p.audioBitrate! > 0)
            '${(p.audioBitrate! / 1000).round()} kbit/s',
        ].join(' · '),
      ),
      ('Ø Bitrate', v.avgMbit > 0 ? '${fmtMbit(v.avgMbit)} (Datei)' : null),
      ('Tempo', '${p.rate}x · Lautstärke ${p.volume.round()} %'),
      ('VOD', v.id),
    ];
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.query_stats_rounded,
                size: 16,
                color: C.primarySoft,
              ),
              const SizedBox(width: 6),
              const Text(
                'Statistiken für Nerds',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: () => widget.extras.nerdStats.value = false,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final (k, value) in rows)
            if (value != null && value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$k  ',
                        style: const TextStyle(color: Colors.white54),
                      ),
                      TextSpan(text: value),
                    ],
                  ),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
