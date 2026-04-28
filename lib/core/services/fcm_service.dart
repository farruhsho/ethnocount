import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ethnocount/data/datasources/remote/notification_remote_ds.dart';
import 'package:ethnocount/domain/entities/notification.dart';

/// Notification fan-out:
///   • Subscribes to Supabase Realtime for the current user's branches.
///   • When a new notification arrives, fires an OS-level notification via
///     `flutter_local_notifications` so it shows up in the phone's
///     notification shade instead of only inside the app.
///
/// Limitation: this fires only while the app process is alive (foreground
/// or short-lived background). Delivery when the app is killed by the OS
/// requires real push (FCM/APNs) — to be added as an Edge Function +
/// device-token registry follow-up.
class FcmService {
  FcmService(this._notificationDs);

  final NotificationRemoteDataSource _notificationDs;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'transfers_channel';
  static const String _channelName = 'Переводы и операции';
  static const String _channelDesc =
      'Уведомления о переводах, подтверждениях и операциях по счетам';

  String? _userId;
  List<String> _branchIds = const [];
  StreamSubscription<List<AppNotification>>? _sub;

  /// IDs of notifications that have already been seen (either pushed or
  /// observed in the initial backlog). Prevents re-pushing on websocket
  /// reconnects or on each subsequent stream emission.
  final Set<String> _seenIds = <String>{};

  /// True once the very first batch from the realtime stream has been
  /// processed. We treat that batch as "history" and only push for
  /// notifications that arrive AFTER it.
  bool _backlogConsumed = false;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
    );

    try {
      await _plugin.initialize(initSettings);

      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Android 13+ runtime permission.
      await android?.requestNotificationsPermission();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );

      _initialized = true;
    } catch (e) {
      debugPrint('FcmService init failed: $e');
    }
  }

  Future<void> subscribeToUser(String userId) async {
    if (_userId == userId) return;
    _userId = userId;
    _restart();
  }

  Future<void> subscribeToBranches(List<String> branchIds) async {
    final next = branchIds.where((id) => id.isNotEmpty).toSet().toList()
      ..sort();
    if (_listsEqual(next, _branchIds)) return;
    _branchIds = next;
    _restart();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _seenIds.clear();
    _backlogConsumed = false;
  }

  void _restart() {
    if (kIsWeb) return;
    if (_userId == null || _branchIds.isEmpty) return;

    _sub?.cancel();
    _backlogConsumed = false;
    _seenIds.clear();

    _sub = _notificationDs
        .watchNotifications(
      branchIds: _branchIds,
      forUserId: _userId,
      limit: 30,
    )
        .listen(
      (list) {
        if (!_backlogConsumed) {
          // First emission = pre-existing notifications. Mark them as seen
          // so we don't push for old items at app startup, and bail.
          for (final n in list) {
            _seenIds.add(n.id);
          }
          _backlogConsumed = true;
          return;
        }

        for (final n in list) {
          if (_seenIds.contains(n.id)) continue;
          _seenIds.add(n.id);
          if (n.isRead) continue;
          unawaited(_show(n));
        }
      },
      onError: (Object e, StackTrace _) {
        debugPrint('FcmService stream error: $e');
      },
    );
  }

  Future<void> _show(AppNotification n) async {
    if (!_initialized) {
      await initialize();
      if (!_initialized) return;
    }
    try {
      await _plugin.show(
        // 31-bit non-negative ID derived from notification UUID.
        n.id.hashCode & 0x7fffffff,
        n.title.isEmpty ? 'EthnoCount' : n.title,
        n.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: n.id,
      );
    } catch (e) {
      debugPrint('FcmService show failed: $e');
    }
  }

  bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
