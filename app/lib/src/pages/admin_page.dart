import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import '../progress.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Runs an admin action, reports how it went and reloads the page.
typedef _Run = Future<void> Function(Future<void> Function() action, String ok);

/// Asks before something destructive.
typedef _Confirm = Future<bool> Function(
  String title,
  String body,
  String action,
);

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

  /// Only the newest load is shown (quick filter changes overtake each other).
  int _loads = 0;

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
    final load = ++_loads;
    try {
      final info = await Api.instance.info();
      final authed = !info.adminRequired || await Api.instance.checkAdmin();
      final r = await Future.wait([
        Api.instance.channels(),
        Api.instance.vods(status: 'all', channel: _filter, limit: 200),
        Api.instance.recordings(),
      ]);
      final page = r[1] as VodPage;
      if (!mounted || load != _loads) return;
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
      if (mounted && load == _loads) setState(() => _error = e);
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.live),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
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
      _toast(
        '${c.displayName} hinzugefügt – wird ab jetzt bei jedem Stream aufgenommen',
      );
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
        leading: IconButton(
          tooltip: 'Zum Archiv',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings_rounded, color: C.primarySoft),
            SizedBox(width: 10),
            Text(
              'Verwaltung',
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(),
        ),
      ),
      body: _error != null
          ? Center(
              child: ErrorBox(error: _error!, onRetry: _load),
            )
          : _info == null
          ? const Center(child: CircularProgressIndicator(color: C.primary))
          : !_authed
          ? _login401()
          : ListView(
              padding: EdgeInsets.symmetric(
                vertical: size.height < 500 ? 12 : 28,
              ),
              children: [ContentWidth(child: _cards(wide, leftW))],
            ),
    );
  }

  Widget _cards(bool wide, double leftW) {
    final left = [
      _StatusCard(info: _info!, channels: _channels),
      if (_live.isNotEmpty)
        _RecordingsCard(live: _live, run: _run, confirm: _confirm),
      _ChannelsCard(
        channels: _channels,
        login: _login,
        adding: _adding,
        onAdd: _add,
        run: _run,
        confirm: _confirm,
      ),
    ];
    final vods = _VodsCard(
      vods: _vods,
      total: _vodTotal,
      channels: _channels,
      filter: _filter,
      onFilter: (v) {
        setState(() => _filter = v);
        _load();
      },
      run: _run,
      confirm: _confirm,
    );
    if (!wide) return Column(children: [...left, vods]);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: leftW,
          child: Column(children: left),
        ),
        const SizedBox(width: 20),
        Expanded(child: vods),
      ],
    );
  }

  Widget _login401() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Panel(
        title: 'Admin-Token',
        icon: Icons.key_rounded,
        children: [
          const Text(
            'Der Server ist mit ADMIN_TOKEN geschützt. Token aus der .env eingeben:',
            style: TextStyle(color: C.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            autofocus: true,
            onSubmitted: (_) => _saveToken(),
            decoration: const InputDecoration(hintText: 'Token'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saveToken,
              child: const Text('Anmelden'),
            ),
          ),
        ],
      ),
    ),
  );

  void _saveToken() {
    Settings.instance.adminToken = _token.text;
    _load();
  }
}

/// Recording slots, ad-free state, storage per channel and disks.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.info, required this.channels});
  final ServerInfo info;
  final List<Channel> channels;

  /// Archive (Storage Box) and local (running / unprocessed) usage per channel.
  List<Widget> _storageRows() {
    final chs = [...channels]
      ..sort(
        (a, b) =>
            (b.sizeBytes + b.localBytes).compareTo(a.sizeBytes + a.localBytes),
      );
    final max = chs.isEmpty ? 1 : chs.first.sizeBytes + chs.first.localBytes;
    return [
      for (final c in chs)
        if (c.sizeBytes + c.localBytes > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Avatar(src: c.avatar, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Text(
                            [
                              '${fmtBytes(c.sizeBytes)} Archiv',
                              if (c.localBytes > 0)
                                '${fmtBytes(c.localBytes)} lokal',
                            ].join(' · '),
                            style: const TextStyle(
                              color: C.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Row(
                          children: [
                            Expanded(
                              flex: (c.sizeBytes * 1000 ~/ max).clamp(0, 1000),
                              child: Container(height: 6, color: C.primary),
                            ),
                            Expanded(
                              flex: (c.localBytes * 1000 ~/ max).clamp(0, 1000),
                              child: Container(height: 6, color: C.orange),
                            ),
                            Expanded(
                              flex:
                                  (1000 -
                                          (c.sizeBytes + c.localBytes) *
                                              1000 ~/
                                              max)
                                      .clamp(0, 1000),
                              child: Container(height: 6, color: C.surface3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final i = info;
    Widget disk(String label, int free, int total) {
      if (total <= 0) return const SizedBox.shrink();
      final used = (total - free) / total;
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                Text(
                  '${fmtBytes(free)} frei',
                  style: const TextStyle(color: C.muted, fontSize: 12.5),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: used,
                minHeight: 8,
                backgroundColor: C.surface3,
                color: used > 0.9 ? C.live : C.primary,
              ),
            ),
          ],
        ),
      );
    }

    return Panel(
      title: 'Status',
      icon: Icons.monitor_heart_rounded,
      children: [
        Row(
          children: [
            if (i.recording > 0)
              const RecDot(size: 9)
            else
              const Icon(Icons.circle, size: 9, color: C.faint),
            const SizedBox(width: 8),
            Text(
              '${i.recording} von ${i.maxConcurrent} Aufnahmeplätzen belegt',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        if (i.processing.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Verarbeitung: ${i.processing.values.join(', ')}',
            style: const TextStyle(color: C.muted, fontSize: 13),
          ),
        ],
        const SizedBox(height: 8),
        _adFreeRow(i),
        if (channels.any((c) => c.sizeBytes + c.localBytes > 0)) ...[
          const SizedBox(height: 16),
          const Text(
            'Speicher nach Kanal',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ..._storageRows(),
        ],
        const SizedBox(height: 16),
        disk('Lokale Platte (Puffer)', i.localFree, i.localTotal),
        disk('Storage Box (Archiv)', i.archiveFree, i.archiveTotal),
        Text(
          '${i.vods} VODs · ${fmtHours(i.totalMs)} · ${fmtBytes(i.totalBytes)} · Version ${i.version}',
          style: const TextStyle(color: C.faint, fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _adFreeRow(ServerInfo i) {
    final (icon, color, text) = !i.adFreeConfigured
        ? (
            Icons.block_rounded,
            C.faint,
            'Werbung wird herausgeschnitten (kein Turbo-Token)',
          )
        : i.adFreeValid
        ? (
            Icons.verified_rounded,
            C.success,
            'Werbefrei über ${i.adFreeLogin.isEmpty ? 'Turbo-Account' : i.adFreeLogin}',
          )
        : (
            Icons.warning_amber_rounded,
            C.orange,
            'Turbo-Token abgelaufen – neues auth-token in die .env eintragen',
          );
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }
}

/// Running recordings: pause, resume, finish.
class _RecordingsCard extends StatelessWidget {
  const _RecordingsCard({
    required this.live,
    required this.run,
    required this.confirm,
  });
  final List<LiveRecording> live;
  final _Run run;
  final _Confirm confirm;

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Laufende Aufnahmen',
    icon: Icons.fiber_manual_record_rounded,
    children: [
      const Text(
        'Pausieren stoppt den Mitschnitt. Fortsetzen hängt an dasselbe Video an, solange der Kanal live ist. Geht er offline, wird abgeschlossen und archiviert. Anschauen lässt sich die Aufnahme, sobald sie abgeschlossen und verarbeitet ist.',
        style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.4),
      ),
      const SizedBox(height: 12),
      for (final l in live)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: C.surface2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Avatar(src: l.channel.avatar, size: 34, live: l.recording),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.channel.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          l.paused
                              ? 'pausiert · ${fmtDuration(DateTime.now().millisecondsSinceEpoch - l.startedAt)} seit Start'
                              : (l.recording
                                    ? 'nimmt auf · ${fmtCount(l.chatCount)} Chat-Nachrichten'
                                    : 'verbindet neu…'),
                          style: TextStyle(
                            color: l.paused ? C.orange : C.live,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (l.paused)
                    FilledButton.tonalIcon(
                      onPressed: () => run(
                        () => Api.instance.resumeRecording(l.channel.id),
                        'Aufnahme wird fortgesetzt',
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Fortsetzen'),
                    )
                  else
                    FilledButton.tonalIcon(
                      onPressed: () => run(
                        () => Api.instance.pauseRecording(l.channel.id),
                        'Aufnahme pausiert',
                      ),
                      icon: const Icon(Icons.pause_rounded, size: 18),
                      label: const Text('Pausieren'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await confirm(
                        'Aufnahme abschließen?',
                        'Die Aufnahme von ${l.channel.displayName} wird beendet und archiviert. Der Rest dieses Streams wird nicht mehr aufgenommen.',
                        'Abschließen',
                      );
                      if (ok) {
                        await run(
                          () => Api.instance.finishRecording(l.channel.id),
                          'Wird abgeschlossen und archiviert',
                        );
                      }
                    },
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('Abschließen'),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
}

/// Add, pause and remove channels.
class _ChannelsCard extends StatelessWidget {
  const _ChannelsCard({
    required this.channels,
    required this.login,
    required this.adding,
    required this.onAdd,
    required this.run,
    required this.confirm,
  });
  final List<Channel> channels;
  final TextEditingController login;
  final bool adding;
  final VoidCallback onAdd;
  final _Run run;
  final _Confirm confirm;

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Kanäle',
    icon: Icons.video_camera_front_rounded,
    children: [
      const Text(
        'Kanal hinzufügen – danach wird jeder Livestream automatisch in bester Qualität inkl. Chat aufgenommen.',
        style: TextStyle(color: C.muted, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: login,
              onSubmitted: (_) => onAdd(),
              decoration: const InputDecoration(
                hintText: 'Twitch-Name oder Link',
                prefixIcon: Icon(Icons.alternate_email_rounded, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: adding ? null : onAdd,
            child: adding
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add_rounded),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (channels.isEmpty)
        const Text('Noch keine Kanäle.', style: TextStyle(color: C.faint)),
      for (final c in channels)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          decoration: BoxDecoration(
            color: C.surface2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Avatar(src: c.avatar, size: 38, live: c.live),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      c.live
                          ? 'nimmt gerade auf'
                          : '${c.vodCount} VODs${c.enabled ? '' : ' · pausiert'}',
                      style: TextStyle(
                        color: c.live ? C.live : C.faint,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: c.enabled,
                onChanged: (v) => run(
                  () => Api.instance.setChannelEnabled(c.id, v),
                  v
                      ? '${c.displayName} wird wieder aufgenommen'
                      : '${c.displayName} pausiert',
                ),
              ),
              IconButton(
                tooltip: 'Kanal entfernen',
                icon: const Icon(Icons.delete_outline_rounded, color: C.muted),
                onPressed: () async {
                  final ok = await confirm(
                    '${c.displayName} entfernen?',
                    c.vodCount > 0
                        ? 'Der Kanal und alle ${c.vodCount} Aufnahmen (inkl. Chat) werden unwiderruflich von der Storage Box gelöscht.'
                        : 'Der Kanal wird nicht mehr aufgenommen.',
                    'Entfernen',
                  );
                  if (ok) {
                    await run(
                      () => Api.instance.deleteChannel(c.id, purge: true),
                      '${c.displayName} entfernt',
                    );
                  }
                },
              ),
            ],
          ),
        ),
    ],
  );
}

/// All recordings (newest first), filterable by channel.
class _VodsCard extends StatelessWidget {
  const _VodsCard({
    required this.vods,
    required this.total,
    required this.channels,
    required this.filter,
    required this.onFilter,
    required this.run,
    required this.confirm,
  });
  final List<Vod> vods;
  final int total;
  final List<Channel> channels;
  final String? filter; // channel login
  final ValueChanged<String?> onFilter;
  final _Run run;
  final _Confirm confirm;

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Aufnahmen',
    icon: Icons.video_library_rounded,
    trailing: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: filter,
          isExpanded: true, // long channel names are cut instead of overflowing
          alignment: AlignmentDirectional.centerEnd,
          dropdownColor: C.surface2,
          borderRadius: BorderRadius.circular(12),
          hint: const Text('Alle Kanäle'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Alle Kanäle')),
            for (final c in channels)
              DropdownMenuItem(
                value: c.login,
                child: Text(
                  c.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onFilter,
        ),
      ),
    ),
    children: [
      Text(
        '$total Aufnahmen${total > vods.length ? ' (neueste ${vods.length} angezeigt)' : ''}',
        style: const TextStyle(color: C.faint, fontSize: 12.5),
      ),
      const SizedBox(height: 12),
      if (vods.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('Keine Aufnahmen.', style: TextStyle(color: C.faint)),
        ),
      for (final v in vods) _VodRow(vod: v, run: run, confirm: confirm),
    ],
  );
}

/// Two rows so it stays readable on phones: picture + title, then the facts
/// (length, size, chat, watched, state) as chips next to the actions.
class _VodRow extends StatelessWidget {
  const _VodRow({required this.vod, required this.run, required this.confirm});
  final Vod vod;
  final _Run run;
  final _Confirm confirm;

  @override
  Widget build(BuildContext context) {
    final v = vod;
    final (stateText, stateColor) = switch (v.status) {
      'recording' => ('Aufnahme läuft', C.live),
      'processing' => (
        v.processing.isEmpty
            ? 'Wartet auf Verarbeitung'
            : 'Verarbeitung: ${v.processing}',
        C.orange,
      ),
      'failed' => (
        v.error.isNotEmpty ? 'Fehler: ${v.error}' : 'Fehlgeschlagen',
        C.live,
      ),
      _ => ('', C.faint),
    };
    final p = WatchProgress.instance;
    final pos = p.positionOf(v);
    final (watchText, watchColor, watchIcon) = p.watchedOf(v)
        ? ('Gesehen', C.success, Icons.check_circle_rounded)
        : pos > 0 && v.durationMs > 0
        ? (
            'Angefangen · ${(pos * 100 / v.durationMs).clamp(1, 99).round()} %',
            C.primarySoft,
            Icons.timelapse_rounded,
          )
        : ('Ungesehen', C.faint, Icons.radio_button_unchecked_rounded);
    // processing can be cancelled by deleting (e.g. stuck after an update)
    final busy = v.recording;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 63,
                  child: NetImg(v.thumbnail, cacheWidth: 320),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.title.isEmpty ? 'Ohne Titel' : v.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        v.channel?.displayName ?? '',
                        fmtWhen(v.startedAt),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (stateText.isNotEmpty)
                      _Fact(
                        Icons.info_outline_rounded,
                        stateText,
                        color: stateColor,
                      ),
                    _Fact(Icons.schedule_rounded, fmtDuration(v.durationMs)),
                    if (v.sizeBytes > 0)
                      _Fact(Icons.save_rounded, fmtBytes(v.sizeBytes)),
                    if (v.chatCount > 0)
                      _Fact(
                        Icons.forum_rounded,
                        '${fmtCount(v.chatCount)} Chat',
                      ),
                    if (v.playable)
                      _Fact(watchIcon, watchText, color: watchColor),
                  ],
                ),
              ),
              if (v.status == 'failed')
                IconButton(
                  tooltip: 'Erneut verarbeiten',
                  icon: const Icon(Icons.replay_rounded, color: C.muted),
                  onPressed: () => run(
                    () => Api.instance.retryVod(v.id),
                    'Wird erneut verarbeitet',
                  ),
                ),
              if (v.playable)
                IconButton(
                  tooltip: 'Ansehen',
                  icon: const Icon(Icons.play_arrow_rounded, color: C.muted),
                  onPressed: () => context.go('/v/${v.id}'),
                ),
              IconButton(
                tooltip: busy ? 'Läuft noch – später löschen' : 'Löschen',
                icon: const Icon(Icons.delete_outline_rounded),
                color: C.live,
                onPressed: busy
                    ? null
                    : () async {
                        final ok = await confirm(
                          'Aufnahme löschen?',
                          '„${v.title}“ wird inklusive Chat unwiderruflich gelöscht${v.status == 'processing' ? ', die laufende Verarbeitung wird abgebrochen' : ' (${fmtBytes(v.sizeBytes)})'}.',
                          'Löschen',
                        );
                        if (ok) {
                          await run(
                            () => Api.instance.deleteVod(v.id),
                            'Aufnahme gelöscht',
                          );
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small fact chip in a recording row ("3:12:40", "4,2 GB", "Gesehen").
class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text, {this.color = C.muted});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: C.surface3,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: color == C.muted ? C.text : color,
            ),
          ),
        ),
      ],
    ),
  );
}
