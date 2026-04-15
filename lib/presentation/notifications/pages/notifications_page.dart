import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/notifications/bloc/notification_bloc.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:intl/intl.dart';

/// Branch IDs whose [targetBranchId] notifications this user should see in the app (and FCM topics).
List<String> notificationBranchIdsForUser(AppUser? user, List<Branch> branches) {
  if (user == null) return [];
  final myBranches = filterBranchesByAccess(branches, user);
  if (user.role.isCreator) {
    return myBranches.map((b) => b.id).toList();
  }
  if (user.assignedBranchIds.isNotEmpty) {
    return List<String>.from(user.assignedBranchIds);
  }
  if (myBranches.isNotEmpty) {
    return myBranches.map((b) => b.id).toList();
  }
  return [];
}

/// Notifications page — actionable alerts for transfer lifecycle events.
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<NotificationBloc>(),
      child: const _NotificationsView(),
    );
  }
}

class _NotificationsView extends StatefulWidget {
  const _NotificationsView();

  @override
  State<_NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<_NotificationsView> {
  String? _subscribedBranchKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNotificationsIfNeeded());
  }

  void _loadNotificationsIfNeeded() {
    final user = context.read<AuthBloc>().state.user;
    final branches = context.read<DashboardBloc>().state.branches;
    final branchIds = notificationBranchIdsForUser(user, branches);
    final key = '${branchIds.join(',')}|${user?.id ?? ''}';
    if (branchIds.isEmpty || key == _subscribedBranchKey) return;
    _subscribedBranchKey = key;
    context.read<NotificationBloc>().add(
          NotificationsLoadRequested(branchIds, forUserId: user?.id),
        );
  }

  void _onNotificationTap(BuildContext context, AppNotification notification) {
    if (!notification.isRead) {
      context.read<NotificationBloc>().add(
            NotificationMarkAsRead(notification.id),
          );
    }
    final type = notification.type;
    final transferId = notification.data['transferId'] as String?;
    if (transferId != null &&
        (type == NotificationType.incomingTransfer ||
            type == NotificationType.transferConfirmed ||
            type == NotificationType.transferRejected ||
            type == NotificationType.transferIssued ||
            type == NotificationType.transferAmended)) {
      context.go('/transfers/manage');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocListener<DashboardBloc, DashboardState>(
      listenWhen: (prev, curr) =>
          curr.branches.isNotEmpty &&
          prev.branches.map((b) => b.id).join(',') !=
              curr.branches.map((b) => b.id).join(','),
      listener: (context, state) => _loadNotificationsIfNeeded(),
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          BlocBuilder<NotificationBloc, NotificationState>(
            builder: (context, state) {
              if (state.unreadCount == 0) return const SizedBox.shrink();
              return TextButton(
                onPressed: () {
                  final user = context.read<AuthBloc>().state.user;
                  final branches =
                      context.read<DashboardBloc>().state.branches;
                  final ids = notificationBranchIdsForUser(user, branches);
                  if (ids.isNotEmpty) {
                    context
                        .read<NotificationBloc>()
                        .add(NotificationMarkAllAsRead(ids));
                  }
                },
                child: const Text('Mark all read'),
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<NotificationBloc, NotificationState>(
        builder: (context, state) {
          if (state.status == NotificationBlocStatus.loading &&
              state.notifications.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state.notifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none,
                      size: 64,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                  const SizedBox(height: AppSpacing.md),
                  Text('No notifications',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text('You\'re all caught up',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      )),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.md),
            itemCount: state.notifications.length,
            itemBuilder: (context, index) {
              final notification = state.notifications[index];
              final dateFormat = DateFormat('MMM d, HH:mm');

              return Card(
                elevation: notification.isRead ? 0 : 1,
                color: notification.isRead
                    ? null
                    : theme.colorScheme.primaryContainer.withValues(alpha: 0.15),
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: notification.isRead
                        ? theme.colorScheme.surfaceContainerHighest
                        : theme.colorScheme.primaryContainer,
                    child: Icon(
                      _getNotificationIcon(notification.type.name),
                      color: notification.isRead
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                          : theme.colorScheme.primary,
                      size: 20,
                    ),
                  ),
                  title: Text(
                    notification.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: notification.isRead
                          ? FontWeight.w400
                          : FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${notification.body}\n${dateFormat.format(notification.createdAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  isThreeLine: true,
                  onTap: () => _onNotificationTap(context, notification),
                ),
              );
            },
          );
        },
      ),
      ),
    );
  }

  IconData _getNotificationIcon(String typeName) {
    switch (typeName) {
      case 'incomingTransfer':
        return Icons.call_received;
      case 'transferConfirmed':
        return Icons.check_circle_outline;
      case 'transferRejected':
        return Icons.cancel_outlined;
      case 'transferCancelled':
        return Icons.block;
      case 'transferIssued':
        return Icons.check_circle;
      case 'transferAmended':
        return Icons.edit_note_rounded;
      default:
        return Icons.info_outline;
    }
  }
}
