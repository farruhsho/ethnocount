import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/notifications/bloc/notification_bloc.dart';
import 'package:ethnocount/presentation/notifications/widgets/notification_card.dart';
import 'package:ethnocount/presentation/notifications/widgets/notification_header.dart';

/// Branch IDs whose [targetBranchId] notifications this user should see in
/// the app (and FCM topics).
List<String> notificationBranchIdsForUser(
    AppUser? user, List<Branch> branches) {
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

/// Filter buckets matching the chip strip on the notifications page.
enum _NotifFilter { all, unread, transfers, system }

class _NotificationsView extends StatefulWidget {
  const _NotificationsView();

  @override
  State<_NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<_NotificationsView> {
  String? _subscribedBranchKey;
  _NotifFilter _filter = _NotifFilter.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _loadNotificationsIfNeeded());
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

  void _refresh() {
    _subscribedBranchKey = null;
    _loadNotificationsIfNeeded();
  }

  void _markAllRead() {
    final user = context.read<AuthBloc>().state.user;
    final branches = context.read<DashboardBloc>().state.branches;
    final ids = notificationBranchIdsForUser(user, branches);
    if (ids.isNotEmpty) {
      context.read<NotificationBloc>().add(NotificationMarkAllAsRead(ids));
    }
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
            type == NotificationType.transferDispatched ||
            type == NotificationType.transferIssued ||
            type == NotificationType.transferAmended)) {
      context.go('/transfers/manage');
    }
  }

  bool _matchesFilter(AppNotification n) {
    switch (_filter) {
      case _NotifFilter.all:
        return true;
      case _NotifFilter.unread:
        return !n.isRead;
      case _NotifFilter.transfers:
        return n.type != NotificationType.systemAlert;
      case _NotifFilter.system:
        return n.type == NotificationType.systemAlert;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<DashboardBloc, DashboardState>(
      listenWhen: (prev, curr) =>
          curr.branches.isNotEmpty &&
          prev.branches.map((b) => b.id).join(',') !=
              curr.branches.map((b) => b.id).join(','),
      listener: (context, state) => _loadNotificationsIfNeeded(),
      child: Scaffold(
        body: SafeArea(
          child: BlocBuilder<NotificationBloc, NotificationState>(
            builder: (context, state) {
              if (state.status == NotificationBlocStatus.loading &&
                  state.notifications.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              final all = state.notifications;
              final filtered =
                  all.where(_matchesFilter).toList(growable: false);
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: NotificationsHeader(
                      unreadCount: state.unreadCount,
                      totalCount: all.length,
                      onMarkAllRead: _markAllRead,
                      onRefresh: _refresh,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _FilterChips(
                      filter: _filter,
                      allCount: all.length,
                      unreadCount: state.unreadCount,
                      transfersCount: all
                          .where((n) =>
                              n.type != NotificationType.systemAlert)
                          .length,
                      systemCount: all
                          .where(
                              (n) => n.type == NotificationType.systemAlert)
                          .length,
                      onChanged: (f) => setState(() => _filter = f),
                    ),
                  ),
                  if (filtered.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyView(filter: _filter),
                    )
                  else
                    ..._buildGroupedSlivers(filtered),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupedSlivers(List<AppNotification> items) {
    // Группируем по дате: Сегодня / Вчера / На неделе / Раньше.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekAgo = today.subtract(const Duration(days: 7));

    final groups = <String, List<AppNotification>>{
      'Сегодня': [],
      'Вчера': [],
      'На неделе': [],
      'Раньше': [],
    };
    for (final n in items) {
      final d = n.createdAt.toLocal();
      final day = DateTime(d.year, d.month, d.day);
      if (day == today) {
        groups['Сегодня']!.add(n);
      } else if (day == yesterday) {
        groups['Вчера']!.add(n);
      } else if (day.isAfter(weekAgo)) {
        groups['На неделе']!.add(n);
      } else {
        groups['Раньше']!.add(n);
      }
    }

    final slivers = <Widget>[];
    for (final entry in groups.entries) {
      if (entry.value.isEmpty) continue;
      slivers.add(SliverToBoxAdapter(child: _GroupHeader(label: entry.key)));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) {
              final n = entry.value[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SwipeableNotification(
                  notification: n,
                  onTap: () => _onNotificationTap(ctx, n),
                  onMarkRead: () => ctx
                      .read<NotificationBloc>()
                      .add(NotificationMarkAsRead(n.id)),
                  onDelete: () => ctx
                      .read<NotificationBloc>()
                      .add(NotificationDeleteRequested(n.id)),
                ),
              );
            },
            childCount: entry.value.length,
          ),
        ),
      ));
    }
    return slivers;
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.filter,
    required this.allCount,
    required this.unreadCount,
    required this.transfersCount,
    required this.systemCount,
    required this.onChanged,
  });
  final _NotifFilter filter;
  final int allCount;
  final int unreadCount;
  final int transfersCount;
  final int systemCount;
  final ValueChanged<_NotifFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = <(String, _NotifFilter, int, Color)>[
      ('Все', _NotifFilter.all, allCount, AppColors.darkTextSecondary),
      ('Непрочитанные', _NotifFilter.unread, unreadCount, AppColors.primary),
      ('Переводы', _NotifFilter.transfers, transfersCount,
          AppColors.secondary),
      ('Системные', _NotifFilter.system, systemCount,
          AppColors.darkTextTertiary),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Row(
        children: [
          for (final c in chips) ...[
            _Chip(
              label: c.$1,
              count: c.$3,
              accent: c.$4,
              active: filter == c.$2,
              onTap: () => onChanged(c.$2),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.count,
    required this.accent,
    required this.active,
    required this.onTap,
  });
  final String label;
  final int count;
  final Color accent;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? accent : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color:
                active ? accent.withValues(alpha: 0.14) : Colors.transparent,
            border: Border.all(
              color: active
                  ? accent
                  : scheme.outline.withValues(alpha: 0.25),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps a [NotificationCard] with `Dismissible` for swipe-actions:
///   • swipe слева→направо → mark-as-read (если уже прочитано — игнор)
///   • swipe справа→налево → удалить (с confirm-snackbar, undo-кнопка)
class _SwipeableNotification extends StatelessWidget {
  const _SwipeableNotification({
    required this.notification,
    required this.onTap,
    required this.onMarkRead,
    required this.onDelete,
  });
  final AppNotification notification;
  final VoidCallback onTap;
  final VoidCallback onMarkRead;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final canMark = !notification.isRead;
    return Dismissible(
      key: ValueKey('notif-${notification.id}'),
      direction: canMark
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      background: canMark ? _markReadBg() : Container(),
      secondaryBackground: _deleteBg(),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onMarkRead();
          return false; // карточка остаётся, просто становится прочитанной
        }
        // delete: показываем snackbar с undo
        // (если undo нажат — НЕ выполняем onDelete)
        return true;
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          onDelete();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Уведомление удалено'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 3),
            ),
          );
        }
      },
      child: NotificationCard(
        notification: notification,
        onTap: onTap,
      ),
    );
  }

  Widget _markReadBg() {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(AppIcons.check_circle_outline,
              color: AppColors.primary, size: 22),
          SizedBox(width: 10),
          Text(
            'Прочитано',
            style: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _deleteBg() {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Text(
            'Удалить',
            style: TextStyle(
              color: AppColors.error,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(width: 10),
          Icon(AppIcons.delete_outline, color: AppColors.error, size: 22),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 0.6,
              color: scheme.outline.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.filter});
  final _NotifFilter filter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String title;
    String subtitle;
    switch (filter) {
      case _NotifFilter.all:
        title = 'Уведомлений нет';
        subtitle = 'Здесь появятся события переводов и системные сообщения.';
        break;
      case _NotifFilter.unread:
        title = 'Всё прочитано';
        subtitle = 'Нет новых уведомлений — вы в курсе.';
        break;
      case _NotifFilter.transfers:
        title = 'Нет событий по переводам';
        subtitle =
            'Поступления, подтверждения и выдачи появятся в этой ленте.';
        break;
      case _NotifFilter.system:
        title = 'Нет системных уведомлений';
        subtitle = 'Алерты от системы появятся здесь.';
        break;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              child: Icon(
                AppIcons.notifications_none,
                size: 30,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
