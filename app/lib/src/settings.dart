import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Locally persisted user preferences and watch progress.
class Settings extends ChangeNotifier {
  Settings._(this._prefs);
  final SharedPreferences _prefs;

  static late Settings instance;

  static Future<Settings> load() async {
    instance = Settings._(await SharedPreferences.getInstance());
    return instance;
  }

  /// Build-time default, e.g. `--dart-define=SERVER_URL=http://localhost:8080` for local debugging.
  static const _defaultServer = String.fromEnvironment('SERVER_URL');

  /// Priority: saved setting > build-time default > origin of the web page.
  String get serverUrl {
    final v = _prefs.getString('serverUrl') ?? '';
    if (v.isNotEmpty) return v;
    if (_defaultServer.isNotEmpty) return _defaultServer;
    return kIsWeb ? Uri.base.origin : '';
  }

  set serverUrl(String v) {
    var s = v.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isNotEmpty && !s.startsWith('http')) s = 'http://$s';
    _prefs.setString('serverUrl', s);
    notifyListeners();
  }

  String get adminToken => _prefs.getString('adminToken') ?? '';
  set adminToken(String v) {
    _prefs.setString('adminToken', v.trim());
    notifyListeners();
  }

  /// Positive = chat appears later.
  int get chatDelayMs => _prefs.getInt('chatDelayMs') ?? 0;
  set chatDelayMs(int v) {
    _prefs.setInt('chatDelayMs', v);
    notifyListeners();
  }

  bool get chatTimestamps => _prefs.getBool('chatTimestamps') ?? false;
  set chatTimestamps(bool v) {
    _prefs.setBool('chatTimestamps', v);
    notifyListeners();
  }

  bool get chatVisible => _prefs.getBool('chatVisible') ?? true;
  set chatVisible(bool v) {
    _prefs.setBool('chatVisible', v);
    notifyListeners();
  }

  double get volume => _prefs.getDouble('volume') ?? 100;
  set volume(double v) => _prefs.setDouble('volume', v);

  // ---- watch progress ----
  int progressMs(String vodId) => _prefs.getInt('p:$vodId') ?? 0;

  void setProgress(String vodId, int ms) {
    _prefs.setInt('p:$vodId', ms);
    final order = _prefs.getStringList('recent') ?? [];
    if (order.isEmpty || order.first != vodId) {
      order
        ..remove(vodId)
        ..insert(0, vodId);
      _prefs.setStringList('recent', order.take(50).toList());
    }
  }

  void clearProgress(String vodId) {
    _prefs.remove('p:$vodId');
    final order = _prefs.getStringList('recent') ?? [];
    order.remove(vodId);
    _prefs.setStringList('recent', order);
    notifyListeners();
  }

  List<String> get recentlyWatched => _prefs.getStringList('recent') ?? const [];
}
