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
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      buildWhen: (prev, curr) => prev.user?.role != curr.user?.role ||
          prev.user?.permissions != curr.user?.permissions,
      builder: (context, authState) {
        final user = authState.user;
        final isCreator = user?.role.isCreator ?? false;
        final perms = user?.permissions ?? AccountantPermissions.all;

        return Scaffold(
          key: _scaffoldKey,
          body: SafeArea(
            top: true,
            bottom: false,
            child: widget.child,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _mobileIndex(context),
            onDestinationSelected: (index) => _onMobileTap(context, index, _scaffoldKey),
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
                icon: Icon(Icons.more_horiz),
                selectedIcon: Icon(Icons.more_horiz),
                label: 'Ещё',
              ),
            ],
          ),
          endDrawer: Drawer(
            child: ListView(
              children: [
                DrawerHeader(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const EthnoLogo(height: 48),
                      const SizedBox(height: 12),
                      Text('Ethno Logistics',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 20)),
                    ],
                  ),
                ),
                if (perms.canPurchases || isCreator)
                  ListTile(
                    leading: const Icon(Icons.shopping_cart_outlined),
                    title: const Text('Покупки'),
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/purchases');
                    },
                  ),
                if (perms.canAnalytics || isCreator)
                  ListTile(
                    leading: const Icon(Icons.analytics_outlined),
                    title: const Text('Аналитика'),
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/analytics');
                    },
                  ),
                if (perms.canExchangeRates || isCreator)
                  ListTile(
                    leading: const Icon(Icons.currency_exchange_outlined),
                    title: const Text('Курсы валют'),
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/exchange-rates');
                    },
                  ),
                if (perms.canReports || isCreator)
                  ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: const Text('Отчёты'),
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/reports');
                    },
                  ),
                if (perms.canBranchesView || isCreator)
                  ListTile(
                    leading: const Icon(Icons.business_outlined),
                    title: const Text('Филиалы'),
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/branches');
                    },
                  ),
                if (isCreator)
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: const Text('Управление'),
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/users');
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Уведомления'),
                  onTap: () {
                    Navigator.pop(context);
                    context.go('/notifications');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Настройки'),
                  onTap: () {
                    Navigator.pop(context);
                    context.go('/settings');
                  },
                ),
              ],
            ),
          ),
        );
      },
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
  if (location.startsWith('/transfers')) return 1;
  if (location.startsWith('/ledger')) return 2;
  if (location.startsWith('/clients')) return 3;
  return 0;
}

const _mobileRoutes = ['/', '/transfers', '/ledger', '/clients'];

void _onMobileTap(BuildContext context, int index, GlobalKey<ScaffoldState> scaffoldKey) {
  if (index == 4) {
    scaffoldKey.currentState?.openEndDrawer();
    return;
  }
  if (index >= 0 && index < _mobileRoutes.length) {
    context.go(_mobileRoutes[index]);
  }
}
