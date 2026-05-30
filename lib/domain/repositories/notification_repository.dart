import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/notification.dart';

/// Repository for internal notification operations.
abstract class NotificationRepository {
  /// Stream of notifications for one or more branches (merged, newest first).
  Stream<List<AppNotification>> watchNotifications({
    required List<String> branchIds,
    bool unreadOnly = false,
    int limit = 50,
    String? forUserId,
  });

  /// Mark a notification as read.
  Future<Either<Failure, void>> markAsRead(String notificationId);

  /// Mark all notifications for the given branches as read.
  Future<Either<Failure, void>> markAllAsRead(List<String> branchIds);

  /// Delete a single notification (swipe-action on the notifications page).
  Future<Either<Failure, void>> deleteNotification(String notificationId);

  /// Get unread notification count for a branch.
  Stream<int> watchUnreadCount(String branchId);
}
