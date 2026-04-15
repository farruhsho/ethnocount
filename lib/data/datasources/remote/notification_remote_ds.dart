import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Supabase data source for internal notifications.
class NotificationRemoteDataSource {
  final SupabaseClient _client;

  NotificationRemoteDataSource(this._client);

  /// Stream of notifications for one or more branches (merged, newest first).
  Stream<List<AppNotification>> watchNotifications({
    required List<String> branchIds,
    bool unreadOnly = false,
    int limit = 50,
    String? forUserId,
  }) {
    final ids = branchIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return Stream.value([]);

    final controller = StreamController<List<AppNotification>>.broadcast();

    _fetchNotifications(
      branchIds: ids,
      unreadOnly: unreadOnly,
      limit: limit,
      forUserId: forUserId,
    ).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('notifications_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          callback: (payload) {
            _fetchNotifications(
              branchIds: ids,
              unreadOnly: unreadOnly,
              limit: limit,
              forUserId: forUserId,
            ).then((list) {
              if (!controller.isClosed) controller.add(list);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<AppNotification>> _fetchNotifications({
    required List<String> branchIds,
    bool unreadOnly = false,
    int limit = 50,
    String? forUserId,
  }) async {
    // Supabase supports in_ for OR queries
    var query = _client
        .from('notifications')
        .select()
        .inFilter('target_branch_id', branchIds);

    if (unreadOnly) {
      query = query.eq('is_read', false);
    }

    final data = await query
        .order('created_at', ascending: false)
        .limit(limit);

    var list = (data as List).map((e) => _mapNotification(Map<String, dynamic>.from(e as Map))).toList();

    // Filter for user
    if (forUserId != null && forUserId.isNotEmpty) {
      list = list
          .where((n) => n.targetUserId == null || n.targetUserId == forUserId)
          .toList();
    }

    return list;
  }

  /// Mark a notification as read.
  Future<void> markAsRead(String notificationId) async {
    await _client
        .from('notifications')
        .update({'is_read': true})
        .eq('id', notificationId);
  }

  /// Mark all notifications for the given branches as read.
  Future<void> markAllAsRead(List<String> branchIds) async {
    final ids = branchIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return;

    await _client
        .from('notifications')
        .update({'is_read': true})
        .inFilter('target_branch_id', ids)
        .eq('is_read', false);
  }

  /// Stream of unread notification count.
  Stream<int> watchUnreadCount(String branchId) {
    final controller = StreamController<int>.broadcast();

    _fetchUnreadCount(branchId).then((count) {
      if (!controller.isClosed) controller.add(count);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('unread_$branchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'target_branch_id',
            value: branchId,
          ),
          callback: (payload) {
            _fetchUnreadCount(branchId).then((count) {
              if (!controller.isClosed) controller.add(count);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<int> _fetchUnreadCount(String branchId) async {
    final data = await _client
        .from('notifications')
        .select('id')
        .eq('target_branch_id', branchId)
        .eq('is_read', false);
    return (data as List).length;
  }

  static NotificationType _parseNotificationType(String? type) {
    const map = {
      'incoming_transfer': NotificationType.incomingTransfer,
      'transfer_confirmed': NotificationType.transferConfirmed,
      'transfer_rejected': NotificationType.transferRejected,
      'transfer_issued': NotificationType.transferIssued,
      'transfer_cancelled': NotificationType.transferCancelled,
      'transfer_amended': NotificationType.transferAmended,
    };
    if (type == null) return NotificationType.systemAlert;
    return map[type] ??
        NotificationType.values.firstWhere(
          (e) => e.name == type,
          orElse: () => NotificationType.systemAlert,
        );
  }

  AppNotification _mapNotification(Map<String, dynamic> data) {
    return AppNotification(
      id: data['id'] ?? '',
      targetBranchId: data['target_branch_id'] ?? '',
      targetUserId: data['target_user_id'],
      type: _parseNotificationType(data['type'] as String?),
      title: data['title'] ?? '',
      body: data['body'] ?? '',
      data: Map<String, dynamic>.from(data['data'] ?? {}),
      isRead: data['is_read'] ?? false,
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
