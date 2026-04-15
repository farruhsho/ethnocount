import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ethnocount/core/routing/app_router.dart';

/// Stub FCM service — push notifications are not available with Supabase out of the box.
/// In-app notifications are handled via Supabase Realtime (NotificationRemoteDataSource).
/// Push can be added later via OneSignal, Firebase Messaging, or Supabase Edge Functions + APNs/FCM.
class FcmService {
  /// No-op: push notifications disabled for now.
  Future<void> initialize() async {
    debugPrint('FcmService: push notifications disabled (Supabase mode)');
  }

  /// No-op stub.
  Future<void> subscribeToBranches(List<String> branchIds) async {}

  /// No-op stub.
  Future<void> subscribeToUser(String userId) async {}
}
