import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/routing/app_router.dart';
import 'package:ethnocount/core/routing/auth_router_refresh.dart';
import 'package:ethnocount/core/routing/route_persistence.dart';
import 'package:ethnocount/core/services/fcm_service.dart';
import 'package:ethnocount/core/theme/app_theme.dart';
import 'package:ethnocount/presentation/analytics/bloc/analytics_bloc.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/exchange_rates/bloc/exchange_rate_bloc.dart';
import 'package:ethnocount/presentation/ledger/bloc/ledger_bloc.dart';
import 'package:ethnocount/presentation/notifications/bloc/notification_bloc.dart';
import 'package:ethnocount/presentation/settings/bloc/theme_cubit.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart'
    show TransferBloc, TransferBlocState, TransferBlocStatus;

class EthnoCountApp extends StatelessWidget {
  const EthnoCountApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => sl<AuthBloc>()..add(const AuthCheckRequested()),
        ),
        BlocProvider(create: (_) => sl<DashboardBloc>()),
        BlocProvider(create: (_) => sl<TransferBloc>()),
        BlocProvider(create: (_) => sl<AnalyticsBloc>()),
        BlocProvider(create: (_) => sl<LedgerBloc>()),
        BlocProvider(
          create: (_) => sl<ExchangeRateBloc>()
            ..add(const ExchangeRateLoadRequested())
            ..add(const ExchangeRateCurrenciesRequested()),
        ),
        BlocProvider(create: (_) => sl<NotificationBloc>()),
        BlocProvider(create: (_) => ThemeCubit()),
      ],
      child: BlocListener<AuthBloc, AuthState>(
        listenWhen: (prev, curr) =>
            curr.status == AuthStatus.unauthenticated ||
            (curr.user != prev.user && curr.user != null),
        listener: (context, state) {
          if (state.status == AuthStatus.unauthenticated) {
            unawaited(RoutePersistence.clear());
            unawaited(sl<FcmService>().dispose());
          } else if (state.user != null) {
            final user = state.user!;
            context.read<DashboardBloc>().add(const DashboardStarted());
            // Request OS notification permission (Android 13+) and create
            // the channel before subscribing, so the permission prompt
            // appears once the user is authenticated rather than on every
            // notification arrival.
            unawaited(sl<FcmService>().initialize());
            unawaited(sl<FcmService>().subscribeToUser(user.id));
            if (!user.role.isCreator && user.assignedBranchIds.isNotEmpty) {
              sl<FcmService>().subscribeToBranches(user.assignedBranchIds);
            }
          }
        },
        child: BlocListener<DashboardBloc, DashboardState>(
          listenWhen: (prev, curr) =>
              curr.branches.isNotEmpty &&
              (prev.branches.isEmpty ||
                  prev.branches.length != curr.branches.length),
          listener: (context, state) {
            final user = context.read<AuthBloc>().state.user;
            if (user?.role.isCreator == true && state.branches.isNotEmpty) {
              sl<FcmService>().subscribeToBranches(
                state.branches.map((b) => b.id).toList(),
              );
            }
          },
          child: BlocListener<TransferBloc, TransferBlocState>(
            listenWhen: (prev, curr) =>
                curr.status == TransferBlocStatus.success &&
                (prev.successMessage != curr.successMessage),
            listener: (context, state) {
              if (state.successMessage?.contains('confirmed') == true) {
                context.read<AnalyticsBloc>().add(const AnalyticsLoadRequested());
              }
            },
            child: BlocBuilder<ThemeCubit, ThemeMode>(
              builder: (context, themeMode) {
                return _RootMaterialApp(themeMode: themeMode);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Owns [GoRouter] so we can refresh redirects when [AuthBloc] changes and
/// repaint after Android resume (reduces blank/black frames).
class _RootMaterialApp extends StatefulWidget {
  const _RootMaterialApp({required this.themeMode});

  final ThemeMode themeMode;

  @override
  State<_RootMaterialApp> createState() => _RootMaterialAppState();
}

class _RootMaterialAppState extends State<_RootMaterialApp>
    with WidgetsBindingObserver {
  GoRouter? _router;
  AuthGoRouterRefresh? _authRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_router != null) return;
    final auth = context.read<AuthBloc>();
    _authRefresh = AuthGoRouterRefresh(auth);
    final router = AppRouter.buildRouter(refreshListenable: _authRefresh!);
    router.routerDelegate.addListener(_onRouterNavigated);
    _router = router;
  }

  void _onRouterNavigated() {
    final r = _router;
    if (r == null) return;
    unawaited(RoutePersistence.onNavigated(r.state.uri));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routerDelegate.removeListener(_onRouterNavigated);
    _authRefresh?.dispose();
    AppRouter.unregisterRouter();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
      // Re-check auth so role/permissions refresh and a server-side
      // revoke is detected when the user returns from recents. Debounced
      // inside the bloc so rapid resumes don't spam the network.
      try {
        context.read<AuthBloc>().add(const AuthCheckRequested());
      } catch (_) {/* bloc not available yet */}
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = _router;
    if (router == null) {
      return const SizedBox.shrink();
    }
    return MaterialApp.router(
      title: 'Ethno Logistics',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: widget.themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final surface = Theme.of(context).colorScheme.surface;
        return ColoredBox(
          color: surface,
          child: child ?? SizedBox(height: MediaQuery.sizeOf(context).height),
        );
      },
    );
  }
}
