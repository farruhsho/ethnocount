import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/data/datasources/remote/notification_remote_ds.dart';
import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/repositories/notification_repository.dart';

class NotificationRepoImpl implements NotificationRepository {
  final NotificationRemoteDataSource _remoteDs;

  NotificationRepoImpl(this._remoteDs);

  @override
  Stream<List<AppNotification>> watchNotifications({
    required List<String> branchIds,
    bool unreadOnly = false,
    int limit = 50,
    String? forUserId,
  }) {
    return _remoteDs.watchNotifications(
      branchIds: branchIds,
      unreadOnly: unreadOnly,
      limit: limit,
      forUserId: forUserId,
    );
  }

  @override
  Future<Either<Failure, void>> markAsRead(String notificationId) async {
    try {
      await _remoteDs.markAsRead(notificationId);
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> markAllAsRead(List<String> branchIds) async {
    try {
      await _remoteDs.markAllAsRead(branchIds);
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Stream<int> watchUnreadCount(String branchId) =>
      _remoteDs.watchUnreadCount(branchId);
}
