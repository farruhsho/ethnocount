import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/repositories/notification_repository.dart';

/// Watch notifications for a branch.
class WatchNotificationsUseCase {
  final NotificationRepository _repository;

  WatchNotificationsUseCase(this._repository);

  Stream<List<AppNotification>> call({
    required List<String> branchIds,
    bool unreadOnly = false,
    int limit = 50,
    String? forUserId,
  }) {
    return _repository.watchNotifications(
      branchIds: branchIds,
      unreadOnly: unreadOnly,
      limit: limit,
      forUserId: forUserId,
    );
  }
}
