import 'package:shared_preferences/shared_preferences.dart';

const _keyLoginTimestamp = 'session_login_timestamp';

/// Manages session duration: stores login time and checks if session expired.
class SessionService {
  Future<void> recordLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLoginTimestamp, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> clearLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLoginTimestamp);
  }

  /// Returns true if session has expired based on [sessionDurationDays].
  Future<bool> isSessionExpired(int sessionDurationDays) async {
    if (sessionDurationDays <= 0) return false;
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_keyLoginTimestamp);
    if (ts == null) return false;
    final loginTime = DateTime.fromMillisecondsSinceEpoch(ts);
    final expiry = loginTime.add(Duration(days: sessionDurationDays));
    return DateTime.now().isAfter(expiry);
  }
}
