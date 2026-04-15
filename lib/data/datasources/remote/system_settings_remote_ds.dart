import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Remote data source for system-wide settings (Creator-managed).
class SystemSettingsRemoteDataSource {
  final SupabaseClient _client;

  SystemSettingsRemoteDataSource(this._client);

  Future<int> getSessionDurationDays() async {
    try {
      final data = await _client
          .from('system_settings')
          .select('session_duration_days')
          .eq('id', 'general')
          .maybeSingle();
      if (data == null) return 7;
      final v = data['session_duration_days'];
      if (v is int) return v.clamp(1, 365);
      if (v is num) return v.toInt().clamp(1, 365);
      return 7;
    } catch (_) {
      return 7;
    }
  }

  Future<void> setSessionDurationDays(int days) async {
    await _client.from('system_settings').upsert({
      'id': 'general',
      'session_duration_days': days.clamp(1, 365),
    });
  }

  Stream<int> watchSessionDurationDays() {
    final controller = StreamController<int>.broadcast();

    getSessionDurationDays().then((v) {
      if (!controller.isClosed) controller.add(v);
    }).catchError((_) {
      if (!controller.isClosed) controller.add(7);
    });

    controller.onCancel = () {};

    return controller.stream;
  }
}
