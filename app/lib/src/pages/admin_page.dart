import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Separate management area (/admin). Deliberately simple:
/// add a channel -> everything it streams gets recorded; delete VODs.
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final _login = TextEditingController();
  final _token = TextEditingController(text: Settings.instance.adminToken);
  ServerInfo? _info;
  List<Channel> _channels = [];
  List<Vod> _vods = [];
  List<LiveRecording> _live = [];
  int _vodTotal = 0;
  String? _filter; // channel login
  Object? _error;
  bool _adding = false, _authed = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _login.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await Api.instance.info();
      final authed = !info.adminRequired || await Api.instance.checkAdmin();
      final r = await Future.wait([
        Api.instance.channels(),
        Api.instance.vods(status: 'all', channel: _filter, limit: 200),
        Api.instance.live(),
      ]);
      final page = r[1] as VodPage;
      setState(() {
        _info = info;
        _authed = authed;
        _channels = r[0] as List<Channel>;
        _vods = page.items;
        _vodTotal = page.total;
        _live = r[2] as List<LiveRecording>;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: C.live), onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _run(Future<void> Function() fn, String ok) async {
    try {
      await fn();
      _toast(ok);
    } catch (e) {
      _toast('Fehler: $e');
    }
    await _load();
  }

  Future<void> _add() async {
    final login = _login.text.trim();
    if (login.isEmpty) return;
    setState(() => _adding = true);
    try {
      final c = await Api.instance.addChannel(login);
      _login.clear();
      _toast('${c.displayName} hinzugefügt – wird ab jetzt bei jedem Stream aufgenommen');
    } catch (e) {
      _toast('Fehler: $e');
    }
    if (mounted) setState(() => _adding = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // two columns already on phones held sideways: stacked, the recordings
    // ended up far below status and channels on the short screen
    final wide = size.width >= 760;
    final leftW = (size.width * 0.4).clamp(300.0, 420.0);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.surface,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(tooltip: 'Zum Archiv', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: const Row(children: [
          Icon(Icons.admin_panel_settings_rounded, color: C.primarySoft),
          SizedBox(width: 10),
          Text('Verwaltung', style: TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700)),
        ]),
        actions: [IconButton(tooltip: 'Aktualisieren', onPressed: _load, icon: const Icon(Icons.refresh_rounded)), const SizedBox(width: 8)],
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1), child: Divider()),
      ),
      body: _error != null
          ? Center(child: ErrorBox(error: _error!, onRetry: _load))
          : _info == null
              ? const Center(child: CircularProgressIndicator(color: C.primary))
              : !_authed
                  ? _login401()
                  : ListView(padding: EdgeInsets.symmetric(vertical: size.height < 500 ? 12 : 28), children: [
                      ContentWidth(
                        child: wide
                            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                SizedBox(width: leftW, child: Column(children: [_statusCard(), if (_live.isNotEmpty) _liveCard(), _channelsCard()])),
                                const SizedBox(width: 20),
                                Expanded(child: _vodsCard()),
                              ])
                            : Column(children: [_statusCard(), if (_live.isNotEmpty) _liveCard(), _channelsCard(), _vodsCard()]),
                      ),
                    ]),
    );
  }

  Widget _login401() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _Panel(title: 'Admin-Token', icon: Icons.key_rounded, children: [
            const Text('Der Server ist mit ADMIN_TOKEN geschützt. Token aus der .env eingeben:', style: TextStyle(color: C.muted)),
            const SizedBox(height: 12),
            TextField(controller: _token, obscureText: true, autofocus: true, onSubmitted: (_) => _saveToken(), decoration: const InputDecoration(hintText: 'Token')),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: _saveToken, child: const Text('Anmelden'))),
          ]),
        ),
      );

  void _saveToken() {
    Settings.instance.adminToken = _token.text;
    _load();
  }

  Widget _statusCard() {
    final i = _info!;
    Widget disk(String label, int free, int total) {
      if (total <= 0) return const SizedBox.shrink();
      final used = (total - free) / total;
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            Text('${fmtBytes(free)} frei', style: const TextStyle(color: C.muted, fontSize: 12.5)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: used, minHeight: 8, backgroundColor: C.surface3, color: used > 0.9 ? C.live : C.primary),
          ),
        ]),
      );
    }

    return _Panel(title: 'Status', icon: Icons.monitor_heart_rounded, children: [
      Row(children: [
        if (i.recording > 0) const RecDot(size: 9) else const Icon(Icons.circle, size: 9, color: C.faint),
        const SizedBox(width: 8),
        Text('${i.recording} von ${i.maxConcurrent} Aufnahmeplätzen belegt', style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
      if (i.processing.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text('Verarbeitung: ${i.processing.values.join(', ')}', style: const TextStyle(color: C.muted, fontSize: 13)),
      ],
      const SizedBox(height: 8),
      _adFreeRow(i),
      const SizedBox(height: 16),
      disk('Lokale Platte (Puffer)', i.localFree, i.localTotal),
      disk('Storage Box (Archiv)', i.archiveFree, i.archiveTotal),
      Text('${i.vods} VODs · ${fmtHours(i.totalMs)} · ${fmtBytes(i.totalBytes)} · Version ${i.version}', style: const TextStyle(color: C.faint, fontSize: 12.5)),
    ]);
  }

  Widget _adFreeRow(ServerInfo i) {
    final (icon, color, text) = !i.adFreeConfigured
        ? (Icons.block_rounded, C.faint, 'Werbung wird herausgeschnitten (kein Turbo-Token)')
        : i.adFreeValid
            ? (Icons.verified_rounded, C.success, 'Werbefrei über ${i.adFreeLogin.isEmpty ? 'Turbo-Account' : i.adFreeLogin}')
            : (Icons.warning_amber_rounded, C.orange, 'Turbo-Token abgelaufen – neues auth-token in die .env eintragen');
    return Row(children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
    ]);
  }

  Widget _liveCard() => _Panel(title: 'Laufende Aufnahmen', icon: Icons.fiber_manual_record_rounded, children: [
        const Text('Pausieren macht die Aufnahme sofort anschaubar. Fortsetzen hängt an dasselbe Video an, solange der Kanal live ist. Geht er offline, wird abgeschlossen und archiviert.',
            style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 12),
        for (final l in _live)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Avatar(src: l.channel.avatar, size: 34, live: l.recording),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.channel.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      l.paused ? 'pausiert · ${fmtDuration(DateTime.now().millisecondsSinceEpoch - l.startedAt)} seit Start' : (l.recording ? 'nimmt auf · ${fmtCount(l.chatCount)} Chat-Nachrichten' : 'verbindet neu…'),
                      style: TextStyle(color: l.paused ? C.orange : C.live, fontSize: 12),
                    ),
                  ]),
                ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (l.paused)
                  FilledButton.tonalIcon(
                    onPressed: () => _run(() => Api.instance.resumeRecording(l.channel.id), 'Aufnahme wird fortgesetzt'),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Fortsetzen'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: () => _run(() => Api.instance.pauseRecording(l.channel.id), 'Aufnahme pausiert – jetzt anschaubar'),
                    icon: const Icon(Icons.pause_rounded, size: 18),
                    label: const Text('Pausieren'),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await _confirm('Aufnahme abschließen?',
                        'Die Aufnahme von ${l.channel.displayName} wird beendet und archiviert. Der Rest dieses Streams wird nicht mehr aufgenommen.', 'Abschließen');
                    if (ok) await _run(() => Api.instance.finishRecording(l.channel.id), 'Wird abgeschlossen und archiviert');
                  },
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Abschließen'),
                ),
                TextButton.icon(onPressed: () => context.go('/v/${l.vodId}'), icon: const Icon(Icons.play_circle_outline_rounded, size: 18), label: const Text('Ansehen')),
              ]),
            ]),
          ),
      ]);

  Widget _channelsCard() => _Panel(title: 'Kanäle', icon: Icons.video_camera_front_rounded, children: [
        const Text('Kanal hinzufügen – danach wird jeder Livestream automatisch in bester Qualität inkl. Chat aufgenommen.',
            style: TextStyle(color: C.muted, fontSize: 13, height: 1.4)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _login,
              onSubmitted: (_) => _add(),
              decoration: const InputDecoration(hintText: 'Twitch-Name oder Link', prefixIcon: Icon(Icons.alternate_email_rounded, size: 18)),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _adding ? null : _add,
            child: _adding ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.add_rounded),
          ),
        ]),
        const SizedBox(height: 16),
        if (_channels.isEmpty) const Text('Noch keine Kanäle.', style: TextStyle(color: C.faint)),
        for (final c in _channels)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Avatar(src: c.avatar, size: 38, live: c.live),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    c.live ? 'nimmt gerade auf' : '${c.vodCount} VODs${c.enabled ? '' : ' · pausiert'}',
                    style: TextStyle(color: c.live ? C.live : C.faint, fontSize: 12),
                  ),
                ]),
              ),
              Switch(
                value: c.enabled,
                onChanged: (v) => _run(() => Api.instance.setChannelEnabled(c.id, v), v ? '${c.displayName} wird wieder aufgenommen' : '${c.displayName} pausiert'),
              ),
              IconButton(
                tooltip: 'Kanal entfernen',
                icon: const Icon(Icons.delete_outline_rounded, color: C.muted),
                onPressed: () async {
                  final ok = await _confirm(
                    '${c.displayName} entfernen?',
                    c.vodCount > 0
                        ? 'Der Kanal und alle ${c.vodCount} Aufnahmen (inkl. Chat) werden unwiderruflich von der Storage Box gelöscht.'
                        : 'Der Kanal wird nicht mehr aufgenommen.',
                    'Entfernen',
                  );
                  if (ok) await _run(() => Api.instance.deleteChannel(c.id, purge: true), '${c.displayName} entfernt');
                },
              ),
            ]),
          ),
      ]);

  Widget _vodsCard() => _Panel(
        title: 'Aufnahmen',
        icon: Icons.video_library_rounded,
        trailing: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: _filter,
            dropdownColor: C.surface2,
            borderRadius: BorderRadius.circular(12),
            hint: const Text('Alle Kanäle'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Alle Kanäle')),
              for (final c in _channels) DropdownMenuItem(value: c.login, child: Text(c.displayName)),
            ],
            onChanged: (v) {
              setState(() => _filter = v);
              _load();
            },
          ),
        ),
        children: [
          Text('$_vodTotal Aufnahmen${_vodTotal > _vods.length ? ' (neueste ${_vods.length} angezeigt)' : ''}', style: const TextStyle(color: C.faint, fontSize: 12.5)),
          const SizedBox(height: 12),
          if (_vods.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('Keine Aufnahmen.', style: TextStyle(color: C.faint))),
          for (final v in _vods) _vodRow(v),
        ],
      );

  Widget _vodRow(Vod v) {
    final status = switch (v.status) {
      'recording' => ('Aufnahme läuft', C.live),
      'processing' => (v.processing.isEmpty ? 'wartet' : v.processing, C.orange),
      'failed' => ('fehlgeschlagen', C.live),
      _ => ('', C.faint),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: 112, height: 63, child: NetImg(v.thumbnail, cacheWidth: 320)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.title.isEmpty ? 'Ohne Titel' : v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
              [v.channel?.displayName ?? '', fmtWhen(v.startedAt), fmtDuration(v.durationMs), if (v.sizeBytes > 0) fmtBytes(v.sizeBytes)]
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.faint, fontSize: 12),
            ),
            if (status.$1.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(v.status == 'failed' && v.error.isNotEmpty ? 'Fehler: ${v.error}' : status.$1,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: status.$2, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
        if (v.status == 'failed')
          IconButton(tooltip: 'Erneut verarbeiten', icon: const Icon(Icons.replay_rounded, color: C.muted), onPressed: () => _run(() => Api.instance.retryVod(v.id), 'Wird erneut verarbeitet')),
        if (v.playable)
          IconButton(tooltip: 'Ansehen', icon: const Icon(Icons.play_arrow_rounded, color: C.muted), onPressed: () => context.go('/v/${v.id}')),
        IconButton(
          tooltip: v.recording || v.status == 'processing' ? 'Läuft noch – später löschen' : 'Löschen',
          icon: const Icon(Icons.delete_outline_rounded),
          color: C.live,
          onPressed: v.recording || v.status == 'processing'
              ? null
              : () async {
                  final ok = await _confirm('Aufnahme löschen?', '„${v.title}“ wird inklusive Chat unwiderruflich gelöscht (${fmtBytes(v.sizeBytes)}).', 'Löschen');
                  if (ok) await _run(() => Api.instance.deleteVod(v.id), 'Aufnahme gelöscht');
                },
        ),
      ]),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.children, this.trailing});
  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.border)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: C.primarySoft),
            const SizedBox(width: 10),
            Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18)),
            const Spacer(),
            ?trailing,
          ]),
          const SizedBox(height: 16),
          ...children,
        ]),
      );
}
