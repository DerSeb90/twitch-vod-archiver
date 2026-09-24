import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Locally persisted user preferences (watch progress lives on the server).
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

  /// Show VODs that were watched completely in the lists.
  bool get showWatched => _prefs.getBool('showWatched') ?? false;
  set showWatched(bool v) {
    _prefs.setBool('showWatched', v);
    notifyListeners();
  }

  // ---- watch progress of older app versions (now stored on the server) ----
  Map<String, int> get legacyProgress => {
        for (final k in _prefs.getKeys())
          if (k.startsWith('p:')) k.substring(2): _prefs.getInt(k) ?? 0,
      };

  void dropLegacyProgress(String vodId) => _prefs.remove('p:$vodId');

  void dropLegacyRecent() => _prefs.remove('recent');
}
