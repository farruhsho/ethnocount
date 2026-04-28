import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/ethno_logo.dart';
import 'package:ethnocount/presentation/common/widgets/offline_banner.dart';

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
        final extended = _railExpanded || context.screenWidth > AppSpacing.breakpointWidescreen;
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                extended: extended,
                selectedIndex: _navIndexForPath(GoRouterState.of(context).uri.path, routes),
                onDestinationSelected: (index) {
                  if (index >= 0 && index < routes.length) {
                    context.go(routes[index]);
                  }
                },
                leading: Column(
                  children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                        child: const EthnoLogo(height: 48),
                      ),
                    IconButton(
                      icon: Icon(
                        _railExpanded ? Icons.chevron_left : Icons.chevron_right,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _railExpanded = !_railExpanded),
                      tooltip: _railExpanded ? 'Свернуть меню' : 'Развернуть меню',
                    ),
                  ],
                ),
                destinations: dests,
              ),
              const VerticalDivider(width: 1),
              Expanded(child: widget.child),
            ],
          ),
        );
      },
    );
  }

  (List<String> routes, List<NavigationRailDestination> dests) _buildNavItems(
      BuildContext context, dynamic user) {
    final isCreator = user?.role.isCreator ?? false;
    final perms = user?.permissions ?? AccountantPermissions.all;

    final all = [
      ('/', const NavigationRailDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard_rounded),
          label: Text('Обзор'))),
      ('/transfers', const NavigationRailDestination(
          icon: Icon(Icons.swap_horiz_outlined),
          selectedIcon: Icon(Icons.swap_horiz_rounded),
          label: Text('Переводы'))),
      ('/ledger', const NavigationRailDestination(
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long_rounded),
          label: Text('Журнал'))),
      ('/clients', const NavigationRailDestination(
          icon: Icon(Icons.people_outline_rounded),
          selectedIcon: Icon(Icons.people_rounded),
          label: Text('Клиенты'))),
      ('/purchases', const NavigationRailDestination(
          icon: Icon(Icons.shopping_cart_outlined),
          selectedIcon: Icon(Icons.shopping_cart_rounded),
          label: Text('Покупки'))),
      ('/analytics', const NavigationRailDestination(
          icon: Icon(Icons.analytics_outlined),
          selectedIcon: Icon(Icons.analytics_rounded),
          label: Text('Аналитика'))),
      ('/exchange-rates', const NavigationRailDestination(
          icon: Icon(Icons.currency_exchange_outlined),
          selectedIcon: Icon(Icons.currency_exchange_rounded),
          label: Text('Курсы'))),
      ('/reports', const NavigationRailDestination(
          icon: Icon(Icons.file_download_outlined),
          selectedIcon: Icon(Icons.file_download_rounded),
          label: Text('Отчёты'))),
      ('/branches', const NavigationRailDestination(
          icon: Icon(Icons.business_outlined),
          selectedIcon: Icon(Icons.business_rounded),
          label: Text('Филиалы'))),
      ('/users', const NavigationRailDestination(
          icon: Icon(Icons.admin_panel_settings_outlined),
          selectedIcon: Icon(Icons.admin_panel_settings_rounded),
          label: Text('Управление'))),
      ('/notifications', const NavigationRailDestination(
          icon: Icon(Icons.notifications_outlined),
          selectedIcon: Icon(Icons.notifications_rounded),
          label: Text('Уведомления'))),
      ('/settings', const NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: Text('Настройки'))),
    ];

    final filtered = <(String, NavigationRailDestination)>[];
    for (final e in all) {
      final route = e.$1;
      if (route == '/') {
        filtered.add(e);
        continue;
      }
      if (route == '/transfers' && !perms.canTransfers && !isCreator) continue;
      if (route == '/ledger' && !perms.canLedger && !isCreator) continue;
      if (route == '/clients' && !perms.canClients && !isCreator) continue;
      if (route == '/purchases' && !perms.canPurchases && !isCreator) continue;
      if (route == '/analytics' && !perms.canAnalytics && !isCreator) continue;
      if (route == '/exchange-rates' && !perms.canExchangeRates && !isCreator) continue;
      if (route == '/reports' && !perms.canReports && !isCreator) continue;
      if (route == '/branches' && !perms.canBranchesView && !isCreator) continue;
      if (route == '/users' && !isCreator) continue;
      filtered.add(e);
    }
    return (
      filtered.map((e) => e.$1).toList(),
      filtered.map((e) => e.$2).toList(),
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
        final perms = user?.permissions ?? AccountantPermissions.all;

        final userEmail = user?.email ?? '';
        final userName = user?.displayName ?? '';
        final roleLabel = isCreator ? 'Создатель' : 'Бухгалтер';

        return Scaffold(
          body: SafeArea(
            top: true,
            bottom: false,
            child: widget.child,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _mobileIndex(context),
            onDestinationSelected: (index) => _onMobileTap(
              context,
              index,
              perms,
              isCreator,
              userEmail: userEmail,
              userName: userName,
              roleLabel: roleLabel,
            ),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard_rounded),
                label: 'Обзор',
              ),
              NavigationDestination(
                icon: Icon(Icons.swap_horiz_outlined),
                selectedIcon: Icon(Icons.swap_horiz_rounded),
                label: 'Переводы',
              ),
              NavigationDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long_rounded),
                label: 'Журнал',
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline_rounded),
                selectedIcon: Icon(Icons.people_rounded),
                label: 'Клиенты',
              ),
              NavigationDestination(
                icon: Icon(Icons.apps_rounded),
                selectedIcon: Icon(Icons.apps_rounded),
                label: 'Ещё',
              ),
            ],
          ),
        );
      },
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
  String userEmail = '',
  String userName = '',
  String roleLabel = '',
}) async {
  final items = <_MoreDestination>[
    if (perms.canPurchases || isCreator)
      const _MoreDestination(
        icon: Icons.shopping_cart_outlined,
        label: 'Покупки',
        route: '/purchases',
      ),
    if (perms.canAnalytics || isCreator)
      const _MoreDestination(
        icon: Icons.analytics_outlined,
        label: 'Аналитика',
        route: '/analytics',
      ),
    if (perms.canExchangeRates || isCreator)
      const _MoreDestination(
        icon: Icons.currency_exchange_outlined,
        label: 'Курсы',
        route: '/exchange-rates',
      ),
    if (perms.canReports || isCreator)
      const _MoreDestination(
        icon: Icons.file_download_outlined,
        label: 'Отчёты',
        route: '/reports',
      ),
    if (perms.canBranchesView || isCreator)
      const _MoreDestination(
        icon: Icons.business_outlined,
        label: 'Филиалы',
        route: '/branches',
      ),
    if (isCreator)
      const _MoreDestination(
        icon: Icons.admin_panel_settings_outlined,
        label: 'Управление',
        route: '/users',
      ),
    const _MoreDestination(
      icon: Icons.notifications_outlined,
      label: 'Уведомления',
      route: '/notifications',
    ),
    const _MoreDestination(
      icon: Icons.settings_outlined,
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
                  const EthnoLogo(height: 24),
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
  if (location.startsWith('/transfers')) return 1;
  if (location.startsWith('/ledger')) return 2;
  if (location.startsWith('/clients')) return 3;
  // Any non-main route is shown as part of "Ещё".
  return 4;
}

const _mobileRoutes = ['/', '/transfers', '/ledger', '/clients'];

void _onMobileTap(
  BuildContext context,
  int index,
  AccountantPermissions perms,
  bool isCreator, {
  String userEmail = '',
  String userName = '',
  String roleLabel = '',
}) {
  if (index == 4) {
    unawaited(_showMoreSheet(
      context,
      perms: perms,
      isCreator: isCreator,
      userEmail: userEmail,
      userName: userName,
      roleLabel: roleLabel,
    ));
    return;
  }
  if (index >= 0 && index < _mobileRoutes.length) {
    context.go(_mobileRoutes[index]);
  }
}
