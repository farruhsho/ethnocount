import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/ethno_logo.dart' show BrandWordmark;
import 'package:ethnocount/presentation/common/widgets/offline_banner.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';

import 'package:ethnocount/core/icons/app_icons.dart';
class NavigationIntent extends Intent {
  final int index;
  const NavigationIntent(this.index);
}

class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget content = context.isDesktop
        ? _DesktopShell(child: child)
        : _MobileShell(child: child);

    content = Column(
      children: [
        const OfflineBanner(),
        Expanded(child: content),
      ],
    );

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // Ctrl+1..9 for first 9 nav items
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit1):
            const NavigationIntent(0),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit2):
            const NavigationIntent(1),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit3):
            const NavigationIntent(2),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit4):
            const NavigationIntent(3),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit5):
            const NavigationIntent(4),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit6):
            const NavigationIntent(5),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit7):
            const NavigationIntent(6),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit8):
            const NavigationIntent(7),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit9):
            const NavigationIntent(8),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.digit0):
            const NavigationIntent(9),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NavigationIntent: CallbackAction<NavigationIntent>(
            onInvoke: (NavigationIntent intent) {
              _onTap(context, intent.index);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: content,
        ),
      ),
    );
  }
}

class _DesktopShell extends StatefulWidget {
  const _DesktopShell({required this.child});
  final Widget child;

  @override
  State<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<_DesktopShell> {
  bool _railExpanded = true;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      buildWhen: (prev, curr) => prev.user?.role != curr.user?.role ||
          prev.user?.permissions != curr.user?.permissions,
      builder: (context, authState) {
        final user = authState.user;
        final (routes, dests) = _buildNavItems(context, user);
        final extended =
            _railExpanded || context.screenWidth > AppSpacing.breakpointWidescreen;
        final currentIdx = _navIndexForPath(
            GoRouterState.of(context).uri.path, routes);
        return Scaffold(
          body: Row(
            children: [
              _CustomNavRail(
                extended: extended,
                currentIndex: currentIdx,
                routes: routes,
                destinations: dests,
                user: user,
                onToggle: () =>
                    setState(() => _railExpanded = !_railExpanded),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: widget.child),
            ],
          ),
        );
      },
    );
  }

  (List<String> routes, List<_NavDest> dests) _buildNavItems(
      BuildContext context, dynamic user) {
    final isCreator = user?.role.isCreator ?? false;
    final canManageUsers = user?.role.canManageUsers ?? false;
    final perms = user?.permissions ?? AccountantPermissions.all;

    final all = <(String, _NavDest)>[
      ('/', _NavDest(AppIcons.dashboard, 'Обзор')),
      ('/transfers', _NavDest(AppIcons.swap_horiz, 'Переводы')),
      ('/ledger', _NavDest(AppIcons.receipt_long, 'Журнал')),
      ('/clients', _NavDest(AppIcons.people_outline, 'Клиенты')),
      ('/counterparties', _NavDest(AppIcons.account_tree, 'Партнёры')),
      ('/purchases', _NavDest(AppIcons.shopping_cart, 'Покупки')),
      ('/analytics', _NavDest(AppIcons.analytics, 'Аналитика')),
      ('/exchange-rates', _NavDest(AppIcons.currency_exchange, 'Курсы')),
      ('/reports', _NavDest(AppIcons.file_download, 'Отчёты')),
      ('/branches', _NavDest(AppIcons.business, 'Филиалы')),
      ('/users', _NavDest(AppIcons.admin_panel_settings, 'Управление')),
      ('/approvals', _NavDest(AppIcons.fact_check, 'Согласования')),
      ('/notifications', _NavDest(AppIcons.notifications, 'Уведомления')),
      ('/settings', _NavDest(AppIcons.settings, 'Настройки')),
    ];

    final filtered = <(String, _NavDest)>[];
    for (final e in all) {
      final route = e.$1;
      if (route == '/') {
        filtered.add(e);
        continue;
      }
      if (route == '/transfers' && !perms.canTransfers && !isCreator) continue;
      if (route == '/ledger' && !perms.canLedger && !isCreator) continue;
      if (route == '/clients' && !perms.canClients && !isCreator) continue;
      // «Партнёры» (counterparties) видит и бухгалтер тоже.
      if (route == '/purchases' && !perms.canPurchases && !isCreator) continue;
      if (route == '/analytics' && !perms.canAnalytics && !isCreator) continue;
      if (route == '/exchange-rates' && !perms.canExchangeRates && !isCreator) continue;
      if (route == '/reports' && !perms.canReports && !isCreator) continue;
      if (route == '/branches' && !perms.canBranchesView && !isCreator) continue;
      if (route == '/users' && !canManageUsers) continue;
      filtered.add(e);
    }
    return (
      filtered.map((e) => e.$1).toList(),
      filtered.map((e) => e.$2).toList(),
    );
  }
}

/// Простая модель пункта навигации — иконка + лейбл. Заменяет
/// `NavigationRailDestination` чтобы можно было рендерить в кастомном
/// scrollable Column (стандартный NavigationRail не умеет скроллиться
/// → переполняется при 14+ пунктах).
class _NavDest {
  const _NavDest(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Кастомный рельс навигации с:
///  • leading: BrandWordmark + кнопка сворачивания
///  • scrollable Expanded destinations (важно — стандартный NavigationRail
///    не скроллится и при 14+ пунктах падает с BOTTOM OVERFLOWED)
///  • sticky bottom _RailUserPill
/// `extended` управляет шириной (свернут / расширен).
class _CustomNavRail extends StatelessWidget {
  const _CustomNavRail({
    required this.extended,
    required this.currentIndex,
    required this.routes,
    required this.destinations,
    required this.user,
    required this.onToggle,
  });

  final bool extended;
  final int currentIndex;
  final List<String> routes;
  final List<_NavDest> destinations;
  final AppUser? user;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final railWidth = extended ? 240.0 : 72.0;
    return SizedBox(
      width: railWidth,
      child: Material(
        color: scheme.surface,
        child: Column(
          children: [
            // ── Leading: brand + toggle ──
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: BrandWordmark(
                height: 36,
                monogramOnly: !extended,
              ),
            ),
            IconButton(
              icon: Icon(
                extended ? AppIcons.chevron_left : AppIcons.chevron_right,
                size: 20,
              ),
              onPressed: onToggle,
              tooltip: extended ? 'Свернуть меню' : 'Развернуть меню',
            ),
            const SizedBox(height: AppSpacing.sm),
            // ── Scrollable destinations ──
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      _RailItem(
                        dest: destinations[i],
                        selected: i == currentIndex,
                        extended: extended,
                        onTap: () => context.go(routes[i]),
                      ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ),
              ),
            ),
            // ── Bottom user pill ──
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.sm,
                bottom: AppSpacing.md,
              ),
              child: _RailUserPill(user: user, extended: extended),
            ),
          ],
        ),
      ),
    );
  }
}

/// Один пункт меню в кастомном рельсе. В extended-режиме — Row с иконкой
/// и текстом; в свёрнутом — только иконка по центру (с tooltip).
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.dest,
    required this.selected,
    required this.extended,
    required this.onTap,
  });
  final _NavDest dest;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    final bg =
        selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent;
    if (!extended) {
      // Свёрнутый режим — только иконка-капсула, центрирована.
      return Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 3),
        child: Tooltip(
          message: dest.label,
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 40,
                child: Center(child: Icon(dest.icon, size: 22, color: fg)),
              ),
            ),
          ),
        ),
      );
    }
    // Расширенный режим — иконка + лейбл.
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 2),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(dest.icon, size: 20, color: fg),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    dest.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          selected ? FontWeight.w800 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

int _navIndexForPath(String path, List<String> routes) {
  for (var i = 0; i < routes.length; i++) {
    if (path == routes[i] || (routes[i] != '/' && path.startsWith(routes[i]))) {
      return i;
    }
  }
  return 0;
}

class _MobileShell extends StatefulWidget {
  const _MobileShell({required this.child});
  final Widget child;

  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      buildWhen: (prev, curr) => prev.user?.role != curr.user?.role ||
          prev.user?.permissions != curr.user?.permissions,
      builder: (context, authState) {
        final user = authState.user;
        final isCreator = user?.role.isCreator ?? false;
        final canManageUsers = user?.role.canManageUsers ?? false;
        final perms = user?.permissions ?? AccountantPermissions.all;

        final userEmail = user?.email ?? '';
        final userName = user?.displayName ?? '';
        final roleLabel = user?.role.displayNameRu ?? '';

        return Scaffold(
          extendBody: true,
          body: SafeArea(
            top: true,
            bottom: false,
            child: widget.child,
          ),
          bottomNavigationBar: BlocBuilder<DashboardBloc, DashboardState>(
            buildWhen: (a, b) => a.pendingCount != b.pendingCount,
            builder: (context, dash) => _MobileBottomBar(
              currentIndex: _mobileIndex(context),
              pendingCount: dash.pendingCount,
              onSelect: (index) => _onMobileTap(
                context,
                index,
                perms,
                isCreator,
                canManageUsers: canManageUsers,
                userEmail: userEmail,
                userName: userName,
                roleLabel: roleLabel,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Кастомный bottom-nav с пятью слотами: Главная / Переводы / [FAB] / Журнал / Ещё.
/// FAB по центру выпирает вверх и ведёт сразу на «Новый перевод».
class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.currentIndex,
    required this.pendingCount,
    required this.onSelect,
  });

  /// 0=главная, 1=переводы, 2=FAB (виртуальный), 3=журнал, 4=ещё.
  final int currentIndex;
  final int pendingCount;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: isDark ? 0.95 : 0.98),
        border: Border(
          top: BorderSide(
            color: scheme.outline.withValues(alpha: 0.18),
            width: 0.5,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withValues(alpha: isDark ? 0.30 : 0.06),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(
                child: _NavSlot(
                  icon: AppIcons.dashboard,
                  selectedIcon: AppIcons.dashboard,
                  label: 'Главная',
                  selected: currentIndex == 0,
                  onTap: () => onSelect(0),
                ),
              ),
              Expanded(
                child: _NavSlot(
                  icon: AppIcons.swap_horiz,
                  selectedIcon: AppIcons.swap_horiz,
                  label: 'Переводы',
                  selected: currentIndex == 1,
                  onTap: () => onSelect(1),
                  badgeCount: pendingCount > 0 ? pendingCount : null,
                ),
              ),
              SizedBox(
                width: 70,
                child: Center(child: _CenterFab(onTap: () => onSelect(2))),
              ),
              Expanded(
                child: _NavSlot(
                  icon: AppIcons.receipt_long,
                  selectedIcon: AppIcons.receipt_long,
                  label: 'Журнал',
                  selected: currentIndex == 3,
                  onTap: () => onSelect(3),
                ),
              ),
              Expanded(
                child: _NavSlot(
                  icon: AppIcons.menu,
                  selectedIcon: AppIcons.menu,
                  label: 'Ещё',
                  selected: currentIndex == 4,
                  onTap: () => onSelect(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  const _NavSlot({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(selected ? selectedIcon : icon, size: 22, color: color),
                if (badgeCount != null)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: scheme.error,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: scheme.surface,
                          width: 1.5,
                        ),
                      ),
                      constraints: const BoxConstraints(minWidth: 16),
                      child: Text(
                        badgeCount! > 99 ? '99+' : '$badgeCount',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onError,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterFab extends StatelessWidget {
  const _CenterFab({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: const Offset(0, -14),
      child: Material(
        elevation: 6,
        shadowColor: scheme.primary.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primary,
                scheme.primary.withValues(alpha: 0.75),
              ],
            ),
            border: Border.all(
              color: scheme.surface,
              width: 4,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 56,
              height: 56,
              child: Icon(
                AppIcons.add,
                color: scheme.onPrimary,
                size: 30,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Destinations shown in the mobile "Ещё" (More) bottom sheet — discovery is
/// much better than a side drawer.
class _MoreDestination {
  const _MoreDestination({
    required this.icon,
    required this.label,
    required this.route,
  });
  final IconData icon;
  final String label;
  final String route;
}

Future<void> _showMoreSheet(
  BuildContext context, {
  required AccountantPermissions perms,
  required bool isCreator,
  bool canManageUsers = false,
  String userEmail = '',
  String userName = '',
  String roleLabel = '',
}) async {
  final items = <_MoreDestination>[
    if (perms.canPurchases || isCreator)
      const _MoreDestination(
        icon: AppIcons.shopping_cart,
        label: 'Покупки',
        route: '/purchases',
      ),
    if (perms.canAnalytics || isCreator)
      const _MoreDestination(
        icon: AppIcons.analytics,
        label: 'Аналитика',
        route: '/analytics',
      ),
    if (perms.canExchangeRates || isCreator)
      const _MoreDestination(
        icon: AppIcons.currency_exchange,
        label: 'Курсы',
        route: '/exchange-rates',
      ),
    if (perms.canReports || isCreator)
      const _MoreDestination(
        icon: AppIcons.file_download,
        label: 'Отчёты',
        route: '/reports',
      ),
    if (perms.canBranchesView || isCreator)
      const _MoreDestination(
        icon: AppIcons.business,
        label: 'Филиалы',
        route: '/branches',
      ),
    if (canManageUsers)
      const _MoreDestination(
        icon: AppIcons.admin_panel_settings,
        label: 'Управление',
        route: '/users',
      ),
    const _MoreDestination(
      icon: AppIcons.notifications,
      label: 'Уведомления',
      route: '/notifications',
    ),
    const _MoreDestination(
      icon: AppIcons.settings,
      label: 'Настройки',
      route: '/settings',
    ),
  ];

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final hasAccount = userEmail.isNotEmpty || userName.isNotEmpty;
      final initial = (userName.isNotEmpty
              ? userName
              : (userEmail.isNotEmpty ? userEmail : '?'))
          .characters
          .first
          .toUpperCase();

      return SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Account card — so user sees under whom они работают
              if (hasAccount)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primary,
                        child: Text(
                          initial,
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              userName.isNotEmpty ? userName : userEmail,
                              style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              roleLabel.isEmpty
                                  ? userEmail
                                  : (userName.isNotEmpty
                                      ? '$roleLabel • $userEmail'
                                      : roleLabel),
                              style: Theme.of(ctx).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (hasAccount) const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  const BrandWordmark(height: 22, monogramOnly: true),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Разделы',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: AppSpacing.sm,
                  mainAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 1.0,
                ),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final item = items[i];
                  return _MoreTile(
                    icon: item.icon,
                    label: item.label,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      context.go(item.route);
                    },
                  );
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: scheme.primary),
              const SizedBox(height: AppSpacing.xs),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _routes = [
  '/',
  '/transfers',
  '/ledger',
  '/clients',
  '/purchases',
  '/analytics',
  '/exchange-rates',
  '/reports',
  '/branches',
  '/users',
  '/notifications',
  '/settings',
];

void _onTap(BuildContext context, int index) {
  if (index >= 0 && index < _routes.length) {
    context.go(_routes[index]);
  }
}

int _mobileIndex(BuildContext context) {
  final location = GoRouterState.of(context).uri.path;
  if (location == '/') return 0;
  if (location.startsWith('/transfers/new')) return 2;
  if (location.startsWith('/transfers')) return 1;
  if (location.startsWith('/ledger')) return 3;
  // Any non-main route is shown as part of "Ещё".
  return 4;
}

void _onMobileTap(
  BuildContext context,
  int index,
  AccountantPermissions perms,
  bool isCreator, {
  bool canManageUsers = false,
  String userEmail = '',
  String userName = '',
  String roleLabel = '',
}) {
  switch (index) {
    case 0:
      context.go('/');
      break;
    case 1:
      context.go('/transfers');
      break;
    case 2:
      // Center FAB — сразу открывает форму нового перевода.
      context.go('/transfers/new');
      break;
    case 3:
      context.go('/ledger');
      break;
    case 4:
      unawaited(_showMoreSheet(
        context,
        perms: perms,
        isCreator: isCreator,
        canManageUsers: canManageUsers,
        userEmail: userEmail,
        userName: userName,
        roleLabel: roleLabel,
      ));
      break;
  }
}

/// Карточка пользователя в подвале desktop NavigationRail.
///
/// Показывает: аватар-инициалы, имя, роль и (для бухгалтера) название
/// прикреплённого филиала. Online-точка на аватаре. По тапу — меню
/// «Настройки / Выйти». Свёрнутая (когда rail collapsed) — только аватар
/// с tooltip-ом, на котором собрано всё.
class _RailUserPill extends StatelessWidget {
  const _RailUserPill({required this.user, required this.extended});

  final AppUser? user;
  final bool extended;

  Future<void> _openMenu(BuildContext ctx, String email) async {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
    final target = box.localToGlobal(Offset.zero, ancestor: overlay);
    final selected = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(
        target.dx + box.size.width,
        target.dy - 60,
        target.dx + box.size.width + 260,
        target.dy + 60,
      ),
      items: [
        PopupMenuItem(
          value: 'settings',
          child: ListTile(
            dense: true,
            leading: const Icon(AppIcons.settings, size: 18),
            title: const Text('Настройки'),
            subtitle: email.isEmpty ? null : Text(email),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'logout',
          child: ListTile(
            dense: true,
            leading: Icon(AppIcons.logout, size: 18, color: Colors.redAccent),
            title: Text('Выйти', style: TextStyle(color: Colors.redAccent)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
    if (!ctx.mounted) return;
    switch (selected) {
      case 'settings':
        ctx.go('/settings');
        break;
      case 'logout':
        ctx.read<AuthBloc>().add(const AuthSignOutRequested());
        break;
    }
  }

  Widget _avatar(BuildContext context, String initial, {double size = 40}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary,
            scheme.primary.withValues(alpha: 0.7),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = user?.displayName.trim() ?? '';
    final email = user?.email.trim() ?? '';
    final role = user?.role.displayNameRu ?? '';

    final initial = (name.isNotEmpty
            ? name
            : (email.isNotEmpty ? email : '?'))
        .characters
        .first
        .toUpperCase();

    if (!extended) {
      return Builder(
        builder: (ctx) => Tooltip(
          message: name.isNotEmpty
              ? '$name${role.isEmpty ? '' : ' · $role'}'
                  '${email.isEmpty ? '' : '\n$email'}'
              : email,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _openMenu(ctx, email),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _avatar(context, initial),
            ),
          ),
        ),
      );
    }

    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (a, b) => a.branches != b.branches,
      builder: (ctx, _) {
        final branchLabel = _branchLabel(ctx, user);
        final roleLabel = role;
        final primary = name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Без имени');
        final showEmailLine = name.isNotEmpty && email.isNotEmpty;

        return InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          onTap: () => _openMenu(ctx, email),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                  scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                ],
              ),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.18),
                width: 0.6,
              ),
            ),
            // NavigationRail.trailing получает Column без bounded width,
            // поэтому Row здесь обязан быть mainAxisSize.min — а внутри
            // только Flexible (Expanded внутри Row(min) даёт MISSING
            // constraints и валит hit-test всего Scaffold, включая FAB).
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _avatar(context, initial, size: 38),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        primary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.1,
                          height: 1.15,
                        ),
                      ),
                      if (roleLabel.isNotEmpty || branchLabel.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (roleLabel.isNotEmpty)
                              _RoleBadge(label: roleLabel, color: scheme.primary),
                            if (roleLabel.isNotEmpty && branchLabel.isNotEmpty)
                              const SizedBox(width: 4),
                            if (branchLabel.isNotEmpty)
                              Flexible(
                                child: Text(
                                  branchLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (showEmailLine) ...[
                        const SizedBox(height: 2),
                        Text(
                          email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurfaceVariant
                                .withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(AppIcons.menu,
                    size: 14, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Только имя филиала (без роли) — роль показываем как отдельный badge.
  String _branchLabel(BuildContext context, AppUser? u) {
    if (u == null) return '';
    if (u.role.isCreator || u.role.isDirector) return 'все филиалы';
    if (u.assignedBranchIds.isEmpty) return 'без филиала';
    final all = context.read<DashboardBloc>().state.branches;
    final byId = {for (final b in all) b.id: b};
    final names = u.assignedBranchIds
        .map((id) => byId[id]?.name)
        .whereType<String>()
        .toList();
    if (names.isEmpty) return 'филиал не загружен';
    return names.length > 2
        ? '${names.take(2).join(', ')} +${names.length - 2}'
        : names.join(', ');
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
          color: color,
        ),
      ),
    );
  }
}
