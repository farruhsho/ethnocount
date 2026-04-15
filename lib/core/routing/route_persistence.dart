import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last in-app location (shell routes) across process restarts.
abstract final class RoutePersistence {
  static const _key = 'ethno_last_shell_uri';

  static String? _memoryUri;

  /// Call once at startup with the same [SharedPreferences] instance as [main].
  static void prime(SharedPreferences prefs) {
    _memoryUri = prefs.getString(_key);
  }

  /// Where to send the user after splash when already authenticated.
  static String homeAfterAuth() {
    final u = _memoryUri;
    if (u == null || u.isEmpty) return '/';
    try {
      if (!isPersistablePath(Uri.parse(u).path)) return '/';
    } catch (_) {
      return '/';
    }
    return u;
  }

  static bool isPersistablePath(String path) {
    return path != '/splash' &&
        path != '/login' &&
        path != '/register' &&
        path != '/forgot-password';
  }

  static Future<void> onNavigated(Uri uri) async {
    if (!isPersistablePath(uri.path)) return;
    final s = uri.toString();
    if (s == _memoryUri) return;
    _memoryUri = s;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, s);
  }

  static Future<void> clear() async {
    _memoryUri = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }
}
