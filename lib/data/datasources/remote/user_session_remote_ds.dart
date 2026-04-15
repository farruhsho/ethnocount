import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/core/utils/platform_helper.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _keyDeviceSessionId = 'device_session_id';

/// Session record for display in settings.
class UserSessionRecord {
  final String id;
  final String platform;
  final String deviceType;
  final String? ip;
  final DateTime lastSeen;

  const UserSessionRecord({
    required this.id,
    required this.platform,
    required this.deviceType,
    this.ip,
    required this.lastSeen,
  });
}

class UserSessionRemoteDataSource {
  final SupabaseClient _client;

  UserSessionRemoteDataSource(this._client);

  Future<String> _getDeviceType() async {
    if (kIsWeb) return 'Web';
    return getDeviceTypeFromPlatform();
  }

  Future<String> _getPlatform() async {
    if (kIsWeb) return 'Web';
    return getPlatformName();
  }

  Future<String?> _getPublicIp() async {
    try {
      final r = await http.get(Uri.parse('https://api.ipify.org')).timeout(
        const Duration(seconds: 3),
      );
      if (r.statusCode == 200 && r.body.trim().isNotEmpty) {
        return r.body.trim();
      }
    } catch (_) {}
    return null;
  }

  Future<String> getOurSessionId() => _getOrCreateDeviceSessionId();

  Future<String> _getOrCreateDeviceSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyDeviceSessionId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_keyDeviceSessionId, id);
    }
    return id;
  }

  Future<void> logSession(String userId) async {
    final deviceType = await _getDeviceType();
    final platform = await _getPlatform();
    final ip = await _getPublicIp();
    final sessionId = await _getOrCreateDeviceSessionId();
    final now = DateTime.now().toIso8601String();

    await _client.from('user_sessions').upsert({
      'id': sessionId,
      'user_id': userId,
      'platform': platform,
      'device_type': deviceType,
      'ip': ip,
      'last_seen': now,
      'created_at': now,
    });
  }

  Future<void> deleteSession(String userId, String sessionId) async {
    await _client
        .from('user_sessions')
        .delete()
        .eq('user_id', userId)
        .eq('id', sessionId);
  }

  /// Returns false if our session was revoked (deleted from Supabase).
  Future<bool> isOurSessionStillListed(String userId) async {
    final sessionId = await _getOrCreateDeviceSessionId();
    final data = await _client
        .from('user_sessions')
        .select('id')
        .eq('user_id', userId)
        .eq('id', sessionId)
        .maybeSingle();
    return data != null;
  }

  Stream<List<UserSessionRecord>> watchSessions(String userId) {
    final controller = StreamController<List<UserSessionRecord>>.broadcast();

    _fetchSessions(userId).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    controller.onCancel = () {};

    return controller.stream;
  }

  Future<List<UserSessionRecord>> _fetchSessions(String userId) async {
    final data = await _client
        .from('user_sessions')
        .select()
        .eq('user_id', userId)
        .order('last_seen', ascending: false)
        .limit(20);
    return (data as List).map((d) {
      return UserSessionRecord(
        id: d['id'] ?? '',
        platform: d['platform'] ?? 'Unknown',
        deviceType: d['device_type'] ?? 'Unknown',
        ip: d['ip'] as String?,
        lastSeen: DateTime.tryParse(d['last_seen'] ?? '') ?? DateTime.now(),
      );
    }).toList();
  }
}
