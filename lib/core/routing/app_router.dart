import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/core/routing/route_names.dart';
import 'package:ethnocount/core/routing/route_persistence.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/presentation/auth/pages/splash_page.dart';
import 'package:ethnocount/presentation/auth/pages/login_page.dart';
import 'package:ethnocount/presentation/auth/pages/register_page.dart';
import 'package:ethnocount/presentation/auth/pages/forgot_password_page.dart';
import 'package:ethnocount/presentation/dashboard/pages/dashboard_page.dart';
import 'package:ethnocount/presentation/transfers/pages/transfers_page.dart';
import 'package:ethnocount/presentation/transfers/pages/accepted_transfers_page.dart';
import 'package:ethnocount/presentation/transfers/pages/manage_transfers_page.dart';
import 'package:ethnocount/presentation/transfers/pages/create_transfer_page.dart';
import 'package:ethnocount/presentation/ledger/pages/ledger_page.dart';
import 'package:ethnocount/presentation/bank_import/pages/bank_import_page.dart';
import 'package:ethnocount/presentation/transfers/pages/branch_topup_page.dart';
import 'package:ethnocount/presentation/bank_import/bloc/bank_import_bloc.dart';
import 'package:ethnocount/presentation/notifications/pages/notifications_page.dart';
import 'package:ethnocount/presentation/settings/pages/settings_page.dart';
import 'package:ethnocount/presentation/exchange_rates/pages/exchange_rates_page.dart';
import 'package:ethnocount/presentation/analytics/pages/analytics_page.dart';
import 'package:ethnocount/presentation/reports/pages/reports_page.dart';
import 'package:ethnocount/presentation/clients/pages/clients_page.dart';
import 'package:ethnocount/presentation/clients/bloc/client_bloc.dart';
import 'package:ethnocount/presentation/purchases/pages/purchases_page.dart';
import 'package:ethnocount/presentation/purchases/bloc/purchase_bloc.dart';
import 'package:ethnocount/presentation/branches/pages/branches_page.dart';
import 'package:ethnocount/presentation/admin/pages/admin_panel_page.dart';
import 'package:ethnocount/presentation/approvals/pages/approvals_page.dart';
import 'package:ethnocount/presentation/common/widgets/adaptive_scaffold.dart';

/// Application router using go_router.
class AppRouter {
  AppRouter._();

  static final _rootNavigatorKey = GlobalKey<NavigatorState>();
  static final _shellNavigatorKey = GlobalKey<NavigatorState>();

  static GoRouter? _routerInstance;

  /// Root navigator (ShellRoute uses a nested key; use this for app-wide overlays / FCM).
  static GlobalKey<NavigatorState> get rootNavigatorKey => _rootNavigatorKey;

  static bool get isReady => _routerInstance != null;

  static GoRouter get router {
    final r = _routerInstance;
    assert(r != null, 'GoRouter not initialized yet');
    return r!;
  }

  /// Called when the widget that owns the router is disposed (e.g. tests / hot restart edge cases).
  static void unregisterRouter() {
    _routerInstance = null;
  }

  static GoRouter buildRouter({required Listenable refreshListenable}) {
    final router = GoRouter(
      navigatorKey: _rootNavigatorKey,
      initialLocation: '/splash',
      refreshListenable: refreshListenable,
      debugLogDiagnostics: kDebugMode,
      redirect: (context, state) {
        final path = state.uri.path;
        final AuthState auth;
        try {
          auth = context.read<AuthBloc>().state;
        } catch (_) {
          return null;
        }

        final authFlow = path == '/splash' ||
            path == '/login' ||
            path == '/register' ||
            path == '/forgot-password';

        if (auth.status == AuthStatus.initial ||
            auth.status == AuthStatus.loading) {
          if (!authFlow) return '/splash';
          return null;
        }

        if (auth.status == AuthStatus.unauthenticated ||
            auth.status == AuthStatus.error) {
          if (path == '/splash') return '/login';
          if (!authFlow) return '/login';
          return null;
        }

        if (auth.status == AuthStatus.authenticated) {
          if (path == '/splash' ||
              path == '/login' ||
              path == '/register' ||
              path == '/forgot-password') {
            return RoutePersistence.homeAfterAuth();
          }
        }

        try {
          final user = auth.user;
          if (user != null && !user.role.isCreator) {
            final p = user.permissions;
            if (path.startsWith('/users') && !user.role.canManageUsers) {
              return '/';
            }
            if (path.startsWith('/transfers') &&
                !p.canTransfers &&
                !(path == '/transfers/topup' && p.canBranchTopUp)) {
              return '/';
            }
            if (path.startsWith('/purchases') && !p.canPurchases) return '/';
            if (path.startsWith('/clients') && !p.canClients) return '/';
            if (path.startsWith('/ledger') && !p.canLedger) return '/';
            if (path.startsWith('/analytics') && !p.canAnalytics) return '/';
            if (path.startsWith('/reports') && !p.canReports) return '/';
            if (path.startsWith('/exchange-rates') && !p.canExchangeRates) {
              return '/';
            }
            if (path.startsWith('/branches') && !p.canBranchesView) return '/';
            // Согласования видны только creator/director (одобряют), но и
            // accountant может зайти посмотреть свои отправленные. Здесь
            // блокировать не нужно — фильтр сделает RLS.
          }
        } catch (_) {}
        return null;
      },
      routes: [
        GoRoute(
          path: '/splash',
          name: RouteNames.splash,
          builder: (context, state) => const SplashPage(),
        ),
        GoRoute(
          path: '/login',
          name: RouteNames.login,
          builder: (context, state) => const LoginPage(),
        ),
        GoRoute(
          path: '/register',
          name: RouteNames.register,
          builder: (context, state) => const RegisterPage(),
        ),
        GoRoute(
          path: '/forgot-password',
          name: RouteNames.forgotPassword,
          builder: (context, state) => const ForgotPasswordPage(),
        ),
        ShellRoute(
          navigatorKey: _shellNavigatorKey,
          builder: (context, state, child) => AdaptiveShell(child: child),
          routes: [
            GoRoute(
              path: '/',
              name: RouteNames.dashboard,
              builder: (context, state) => const DashboardPage(),
            ),
            GoRoute(
              path: '/transfers',
              name: RouteNames.transfers,
              builder: (context, state) => const TransfersPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  name: RouteNames.createTransfer,
                  builder: (context, state) => const CreateTransferPage(),
                ),
                GoRoute(
                  path: 'accepted',
                  name: RouteNames.acceptedTransfers,
                  builder: (context, state) => const AcceptedTransfersPage(),
                ),
                GoRoute(
                  path: 'manage',
                  name: RouteNames.manageTransfers,
                  builder: (context, state) => const ManageTransfersPage(),
                ),
                GoRoute(
                  path: 'topup',
                  name: RouteNames.branchTopUp,
                  builder: (context, state) => const BranchTopUpPage(),
                ),
              ],
            ),
            GoRoute(
              path: '/ledger',
              name: RouteNames.ledger,
              builder: (context, state) {
                final branchId = state.uri.queryParameters['branchId'];
                final accountId = state.uri.queryParameters['accountId'];
                return LedgerPage(
                  initialBranchId: branchId,
                  initialAccountId: accountId,
                );
              },
            ),
            GoRoute(
              path: '/bank-import',
              name: RouteNames.bankImport,
              builder: (context, state) => BlocProvider(
                create: (_) => sl<BankImportBloc>(),
                child: const BankImportPage(),
              ),
            ),
            GoRoute(
              path: '/clients',
              name: RouteNames.clients,
              builder: (context, state) => BlocProvider(
                create: (_) => sl<ClientBloc>(),
                child: const ClientsPage(),
              ),
            ),
            GoRoute(
              path: '/purchases',
              name: RouteNames.purchases,
              builder: (context, state) => BlocProvider(
                create: (_) => sl<PurchaseBloc>(),
                child: const PurchasesPage(),
              ),
            ),
            GoRoute(
              path: '/branches',
              name: RouteNames.branches,
              builder: (context, state) => const BranchesPage(),
            ),
            GoRoute(
              path: '/users',
              name: RouteNames.users,
              builder: (context, state) => const AdminPanelPage(),
            ),
            GoRoute(
              path: '/analytics',
              name: RouteNames.analytics,
              builder: (context, state) => const AnalyticsPage(),
            ),
            GoRoute(
              path: '/exchange-rates',
              name: RouteNames.exchangeRates,
              // ExchangeRateBloc провайдится глобально в app.dart, чтобы
              // дашборд тоже мог читать актуальные курсы. Здесь — просто
              // страница.
              builder: (context, state) => const ExchangeRatesPage(),
            ),
            GoRoute(
              path: '/reports',
              name: RouteNames.reports,
              builder: (context, state) => const ReportsPage(),
            ),
            GoRoute(
              path: '/notifications',
              name: RouteNames.notifications,
              builder: (context, state) => const NotificationsPage(),
            ),
            GoRoute(
              path: '/approvals',
              name: RouteNames.approvals,
              builder: (context, state) => const ApprovalsPage(),
            ),
            GoRoute(
              path: '/settings',
              name: RouteNames.settings,
              builder: (context, state) => const SettingsPage(),
            ),
          ],
        ),
      ],
    );
    _routerInstance = router;
    return router;
  }
}
