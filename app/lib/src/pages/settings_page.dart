import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../settings.dart';
import '../theme.dart';
import '../update/update_flow.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';

/// Viewer preferences only. Channel/VOD management lives in /admin.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _s = Settings.instance;
  late final _server = TextEditingController(text: _s.serverUrl);
  String? _status;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    if (_s.serverUrl.isNotEmpty) _check();
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final i = await Api.instance.info();
      setState(() {
        _ok = true;
        _status = 'Verbunden mit ${i.appName} · ${i.vods} Aufnahmen';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _status = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListView(children: [
        ContentWidth(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListenableBuilder(
                listenable: _s,
                builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(height: 40),
                  Text('Einstellungen', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 24),
                  _Card(title: 'Server', icon: Icons.lan_rounded, children: [
                    const Text('Adresse des Archiv-Servers (per VPN erreichbar)', style: TextStyle(color: C.muted, fontSize: 13)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: TextField(controller: _server, decoration: const InputDecoration(hintText: 'http://10.8.0.1:8080'), onSubmitted: (_) => _save())),
                      const SizedBox(width: 10),
                      FilledButton(onPressed: _save, child: const Text('Verbinden')),
                    ]),
                    if (kIsWeb) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Leer = Server, von dem diese Seite geladen wurde.', style: TextStyle(color: C.faint, fontSize: 12))),
                    if (_status != null) ...[
                      const SizedBox(height: 14),
                      Row(children: [
                        Icon(_ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, color: _ok ? C.success : C.live, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_status!, style: TextStyle(color: _ok ? C.muted : C.live))),
                      ]),
                    ],
                  ]),
                  _Card(title: 'Chat-Replay', icon: Icons.forum_rounded, children: [
                    Text(
                      'Versatz: ${(_s.chatDelayMs / 1000).toStringAsFixed(1)} s ${_s.chatDelayMs > 0 ? '(Chat später)' : _s.chatDelayMs < 0 ? '(Chat früher)' : ''}',
                      style: const TextStyle(color: C.muted),
                    ),
                    Slider(value: _s.chatDelayMs.toDouble().clamp(-30000, 30000), min: -30000, max: 30000, divisions: 120, onChanged: (v) => _s.chatDelayMs = v.round()),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Zeitstempel im Chat'), value: _s.chatTimestamps, onChanged: (v) => _s.chatTimestamps = v),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Chat neben dem Video'), value: _s.chatVisible, onChanged: (v) => _s.chatVisible = v),
                  ]),
                  if (AppUpdateService.available)
                    _Card(title: 'App', icon: Icons.system_update_alt_rounded, children: [
                      FutureBuilder<String>(
                        future: AppUpdateService().installedVersion(),
                        builder: (_, snap) => Text('Installiert: Version ${snap.data ?? '…'}', style: const TextStyle(color: C.muted)),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _checkForUpdates,
                        icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                        label: const Text('Nach Updates suchen'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppUpdateService.supported ? 'Lädt die neue Version direkt von GitHub und installiert sie.' : 'Öffnet das neueste Release auf GitHub.',
                        style: const TextStyle(color: C.faint, fontSize: 12),
                      ),
                    ]),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => context.go('/admin'),
                      icon: const Icon(Icons.admin_panel_settings_outlined, size: 18, color: C.faint),
                      label: const Text('Verwaltung', style: TextStyle(color: C.faint)),
                    ),
                  ),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
          ),
        ),
      ]);

  Future<void> _checkForUpdates() async {
    final flow = AppUpdateFlow();
    try {
      await flow.check(context);
    } finally {
      flow.close();
    }
  }

  void _save() {
    _s.serverUrl = _server.text;
    _server.text = _s.serverUrl;
    _check();
    if (_s.serverUrl.isNotEmpty) context.go('/');
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: C.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: C.primarySoft),
            ),
            const SizedBox(width: 12),
            Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18)),
          ]),
          const SizedBox(height: 18),
          ...children,
        ]),
      );
}
