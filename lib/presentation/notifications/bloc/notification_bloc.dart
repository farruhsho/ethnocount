import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/repositories/notification_repository.dart';
import 'package:ethnocount/core/services/notification_fx_service.dart';

// ─── Events ───

abstract class NotificationEvent extends Equatable {
  const NotificationEvent();
  @override
  List<Object?> get props => [];
}

class NotificationsLoadRequested extends NotificationEvent {
  final List<String> branchIds;
  final String? forUserId;
  const NotificationsLoadRequested(this.branchIds, {this.forUserId});
  @override
  List<Object?> get props => [branchIds, forUserId];
}

class NotificationMarkAsRead extends NotificationEvent {
  final String notificationId;
  const NotificationMarkAsRead(this.notificationId);
  @override
  List<Object?> get props => [notificationId];
}

class NotificationMarkAllAsRead extends NotificationEvent {
  final List<String> branchIds;
  const NotificationMarkAllAsRead(this.branchIds);
  @override
  List<Object?> get props => [branchIds];
}

// ─── State ───

enum NotificationBlocStatus { initial, loading, loaded, error }

class NotificationState extends Equatable {
  final NotificationBlocStatus status;
  final List<AppNotification> notifications;
  final int unreadCount;
  final String? errorMessage;

  const NotificationState({
    this.status = NotificationBlocStatus.initial,
    this.notifications = const [],
    this.unreadCount = 0,
    this.errorMessage,
  });

  NotificationState copyWith({
    NotificationBlocStatus? status,
    List<AppNotification>? notifications,
    int? unreadCount,
    String? errorMessage,
  }) {
    return NotificationState(
      status: status ?? this.status,
      notifications: notifications ?? this.notifications,
      unreadCount: unreadCount ?? this.unreadCount,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, notifications, unreadCount];
}

// ─── BLoC ───

class NotificationBloc extends Bloc<NotificationEvent, NotificationState> {
  final NotificationRepository _repository;
  final NotificationFxService? _fx;

  NotificationBloc({
    required NotificationRepository repository,
    NotificationFxService? fx,
  })  : _repository = repository,
        _fx = fx,
        super(const NotificationState()) {
    on<NotificationsLoadRequested>(_onLoad);
    on<NotificationMarkAsRead>(_onMarkRead);
    on<NotificationMarkAllAsRead>(_onMarkAllRead);
  }

  Future<void> _onLoad(
    NotificationsLoadRequested event,
    Emitter<NotificationState> emit,
  ) async {
    emit(state.copyWith(status: NotificationBlocStatus.loading));

    // Сбрасываем "виденные" при новой подписке (например, смена пользователя
    // или ассайнмент филиалов изменился) — иначе fx сработал бы лишний раз.
    _fx?.reset();

    await emit.forEach(
      _repository.watchNotifications(
        branchIds: event.branchIds,
        forUserId: event.forUserId,
      ),
      onData: (notifications) {
        final unread = notifications.where((n) => !n.isRead).length;
        // Звук + вибрация на новые непрочитанные уведомления.
        // Первая порция после prime() пройдёт молча.
        _fx?.checkAndPlay(
          notifications.where((n) => !n.isRead).map((n) => n.id),
        );
        return state.copyWith(
          status: NotificationBlocStatus.loaded,
          notifications: notifications,
          unreadCount: unread,
        );
      },
      onError: (error, _) => state.copyWith(
        status: NotificationBlocStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }

  Future<void> _onMarkRead(
    NotificationMarkAsRead event,
    Emitter<NotificationState> emit,
  ) async {
    await _repository.markAsRead(event.notificationId);
  }

  Future<void> _onMarkAllRead(
    NotificationMarkAllAsRead event,
    Emitter<NotificationState> emit,
  ) async {
    await _repository.markAllAsRead(event.branchIds);
  }
}
