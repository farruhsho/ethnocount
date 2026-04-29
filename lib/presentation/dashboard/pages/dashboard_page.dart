import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/routing/route_names.dart';
import 'package:ethnocount/core/utils/balance_utils.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/dashboard/widgets/activity_feed_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/balance_chart_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/branch_card_compact.dart';
import 'package:ethnocount/presentation/dashboard/widgets/currency_donut_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/fx_rates_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/kpi_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/pending_transfers_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/quick_actions.dart';
import 'package:ethnocount/presentation/common/widgets/shimmer_loading.dart';
import 'package:ethnocount/presentation/common/animations/fade_slide.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.select<AuthBloc, dynamic>((b) => b.state.user);

    return BlocBuilder<DashboardBloc, DashboardState>(
      builder: (context, state) {
        if (state.status == DashboardStatus.loading &&
            state.branches.isEmpty) {
          return const _LoadingView();
        }

        if (state.status == DashboardStatus.error &&
            state.branches.isEmpty) {
          return _ErrorView(message: state.errorMessage ?? 'Ошибка загрузки');
        }

        final visibleBranches = filterBranchesByAccess(state.branches, user);
        final filtered = state.copyWith(branches: visibleBranches);
        final hasAllBranchesAccess = user?.role.isAdminOrCreator ?? false;

        return context.isDesktop
            ? _DesktopDashboard(
                state: filtered,
                hasAllBranchesAccess: hasAllBranchesAccess,
              )
            : _MobileDashboard(
                state: filtered,
                hasAllBranchesAccess: hasAllBranchesAccess,
              );
      },
    );
  }
}

// ─── Helpers ───

Map<String, double> _balancesByCurrency(DashboardState s) {
  final allAccounts = s.branchAccounts.values.expand((l) => l).toList();
  return balanceByCurrency(allAccounts, s.accountBalances);
}

double _branchUsdEquivalent(
  DashboardState s,
  Branch b,
) {
  // Без курсов берём сумму как есть в базовой валюте филиала.
  final accs = s.branchAccounts[b.id] ?? const [];
  return accs.fold<double>(0, (sum, a) => sum + (s.accountBalances[a.id] ?? 0));
}

int _accountCount(DashboardState s) =>
    s.branchAccounts.values.fold<int>(0, (acc, l) => acc + l.length);

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// DESKTOP
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _DesktopDashboard extends StatefulWidget {
  const _DesktopDashboard({
    required this.state,
    required this.hasAllBranchesAccess,
  });
  final DashboardState state;
  final bool hasAllBranchesAccess;

  @override
  State<_DesktopDashboard> createState() => _DesktopDashboardState();
}

class _DesktopDashboardState extends State<_DesktopDashboard> {
  String _branchFilter = 'Все';
  static const _branchFilters = ['Все', 'UZ', 'RU', 'KZ'];

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final branches = _branchFilter == 'Все'
        ? state.branches
        : state.branches
            .where((b) => b.code.toUpperCase().contains(_branchFilter))
            .toList();
    final totals = _balancesByCurrency(state);
    final totalUsd = totals['USD'] ?? totals.values.fold<double>(0, (a, b) => a + b);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            branchCount: state.branches.length,
            pendingCount: state.pendingCount,
          ),
          const SizedBox(height: AppSpacing.lg),

          // KPI row — 4 карточки. Aspect 1.4 даёт ~170px высоты при ~240px
          // ширине: места достаточно даже для hero-варианта.
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
            childAspectRatio: 1.4,
            children: [
              KpiCard(
                hero: true,
                label: 'Общий баланс казначейства',
                primary: CurrencyUtils.formatBalanceBreakdown(totals)
                    .split(', ')
                    .first,
                secondary: totals.length > 1
                    ? totals.entries
                        .skip(1)
                        .map((e) => '${_compact(e.value)} ${e.key}')
                        .join(' · ')
                    : null,
                icon: Icons.account_balance_wallet_rounded,
                iconColor: AppColors.primary,
              ),
              KpiCard(
                label: 'Активных филиалов',
                primary: '${state.branches.where((b) => b.isActive).length}',
                secondary: '${state.branches.length} всего',
                icon: Icons.business_rounded,
                iconColor: AppColors.secondary,
              ),
              KpiCard(
                label: 'Ожидающие переводы',
                primary: '${state.pendingCount}',
                secondary: state.pendingCount > 0
                    ? 'требуют действия'
                    : 'нет ожидающих',
                icon: Icons.pending_actions_rounded,
                iconColor: AppColors.warning,
              ),
              KpiCard(
                label: 'Активных счетов',
                primary: '${_accountCount(state)}',
                secondary: 'по всем филиалам',
                icon: Icons.credit_card_rounded,
                iconColor: AppColors.info,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Charts row 1.7 / 1
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 17,
                child: BalanceChartCard(currentTotal: totalUsd),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 10,
                child: CurrencyDonutCard(balancesByCurrency: totals),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Branches grid + Pending
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 17,
                child: _BranchesSection(
                  branches: branches,
                  state: state,
                  filter: _branchFilter,
                  onFilter: (v) => setState(() => _branchFilter = v),
                  filters: _branchFilters,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 10,
                child: PendingTransfersCard(
                  transfers: state.pendingTransfers,
                  branches: state.branches,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Activity + FX
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 17,
                child: const ActivityFeedCard(),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 10,
                child: const FxRatesCard(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.branchCount, required this.pendingCount});
  final int branchCount;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ethno Logistics Treasury',
                style: context.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$branchCount филиалов · $pendingCount ожидают подтверждения',
                style: context.textTheme.bodyMedium?.copyWith(color: secondary),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.file_download_outlined, size: 18),
          label: const Text('Экспорт'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.tune_rounded, size: 18),
          label: const Text('Фильтры'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () => context.goNamed(RouteNames.createTransfer),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Новый перевод'),
        ),
      ],
    );
  }
}

class _BranchesSection extends StatelessWidget {
  const _BranchesSection({
    required this.branches,
    required this.state,
    required this.filter,
    required this.onFilter,
    required this.filters,
  });
  final List<Branch> branches;
  final DashboardState state;
  final String filter;
  final ValueChanged<String> onFilter;
  final List<String> filters;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final totalUsd = branches.fold<double>(
        0, (s, b) => s + _branchUsdEquivalent(state, b));

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Филиалы',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
              const Spacer(),
              Wrap(
                spacing: 4,
                children: [
                  for (final f in filters)
                    ChoiceChip(
                      label: Text(f, style: const TextStyle(fontSize: 11)),
                      selected: f == filter,
                      onSelected: (_) => onFilter(f),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                        color: secondary.withValues(alpha: 0.2),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (branches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(
                child: Text(
                  'Нет филиалов с этим фильтром',
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                childAspectRatio: 1.45,
                crossAxisSpacing: AppSpacing.md,
                mainAxisSpacing: AppSpacing.md,
              ),
              itemCount: branches.length,
              itemBuilder: (context, i) {
                final b = branches[i];
                final balance = _branchUsdEquivalent(state, b);
                final share = totalUsd > 0 ? balance / totalUsd : 0.0;
                return FadeSlideTransition(
                  delay: Duration(milliseconds: 50 * i),
                  child: BranchCardCompact(
                    branch: b,
                    balanceUsd: balance,
                    shareOfTotal: share,
                    accountCount: (state.branchAccounts[b.id] ?? const []).length,
                    lowBalance: balance < 1000,
                    onTap: () => context
                        .read<DashboardBloc>()
                        .add(DashboardBranchSelected(b.id)),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MOBILE
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _MobileDashboard extends StatefulWidget {
  const _MobileDashboard({
    required this.state,
    required this.hasAllBranchesAccess,
  });
  final DashboardState state;
  final bool hasAllBranchesAccess;

  @override
  State<_MobileDashboard> createState() => _MobileDashboardState();
}

class _MobileDashboardState extends State<_MobileDashboard> {
  String _branchFilter = 'Все';
  static const _branchFilters = ['Все', 'UZ', 'RU', 'KZ'];

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final totals = _balancesByCurrency(state);
    final totalUsd = totals['USD'] ?? totals.values.fold<double>(0, (a, b) => a + b);
    final filteredBranches = _branchFilter == 'Все'
        ? state.branches
        : state.branches
            .where((b) => b.code.toUpperCase().contains(_branchFilter))
            .toList();
    final isDark = context.isDark;

    return RefreshIndicator(
      onRefresh: () async {
        context.read<DashboardBloc>().add(const DashboardRefreshRequested());
      },
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
            elevation: 0,
            scrolledUnderElevation: 0.5,
            title: const Text(
              'Treasury',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search_rounded),
                onPressed: () {},
              ),
              Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.notifications_outlined),
                    onPressed: () => context.go('/notifications'),
                  ),
                  if (state.pendingCount > 0)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.warning,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Hero balance card
                if (widget.hasAllBranchesAccess)
                  KpiCard(
                    hero: true,
                    label: 'Общий баланс казначейства',
                    primary: CurrencyUtils.formatBalanceBreakdown(totals)
                        .split(', ')
                        .first,
                    secondary: totals.length > 1
                        ? totals.entries
                            .skip(1)
                            .map((e) => '${_compact(e.value)} ${e.key}')
                            .join(' · ')
                        : null,
                    icon: Icons.account_balance_wallet_rounded,
                    iconColor: AppColors.primary,
                  ),
                const SizedBox(height: AppSpacing.md),

                // Quick actions row (existing widget — full mobile mode)
                TreasuryQuickActions(),
                const SizedBox(height: AppSpacing.md),

                // KPI grid 2×2
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  crossAxisSpacing: AppSpacing.md,
                  mainAxisSpacing: AppSpacing.md,
                  childAspectRatio: 1.7,
                  children: [
                    KpiCard(
                      label: 'Филиалов',
                      primary: '${state.branches.length}',
                      icon: Icons.business_rounded,
                      iconColor: AppColors.secondary,
                    ),
                    KpiCard(
                      label: 'Ожидают',
                      primary: '${state.pendingCount}',
                      icon: Icons.pending_actions_rounded,
                      iconColor: AppColors.warning,
                    ),
                    KpiCard(
                      label: 'Счетов',
                      primary: '${_accountCount(state)}',
                      icon: Icons.credit_card_rounded,
                      iconColor: AppColors.info,
                    ),
                    KpiCard(
                      label: 'Валют',
                      primary: '${totals.length}',
                      icon: Icons.currency_exchange_rounded,
                      iconColor: AppColors.primary,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),

                BalanceChartCard(currentTotal: totalUsd),
                const SizedBox(height: AppSpacing.md),

                CurrencyDonutCard(balancesByCurrency: totals),
                const SizedBox(height: AppSpacing.md),

                // Branches: filter chips + list
                _MobileSectionHeader(title: 'Филиалы'),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _branchFilters.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final f = _branchFilters[i];
                      return ChoiceChip(
                        label: Text(f, style: const TextStyle(fontSize: 11)),
                        selected: f == _branchFilter,
                        onSelected: (_) =>
                            setState(() => _branchFilter = f),
                        visualDensity: VisualDensity.compact,
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (filteredBranches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Center(
                      child: Text(
                        'Нет филиалов',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.lightTextSecondary,
                        ),
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < filteredBranches.length; i++) ...[
                    FadeSlideTransition(
                      delay: Duration(milliseconds: 50 * i),
                      child: BranchCardCompact(
                        branch: filteredBranches[i],
                        balanceUsd: _branchUsdEquivalent(
                            state, filteredBranches[i]),
                        shareOfTotal: totalUsd > 0
                            ? _branchUsdEquivalent(
                                    state, filteredBranches[i]) /
                                totalUsd
                            : 0,
                        accountCount: (state.branchAccounts[
                                    filteredBranches[i].id] ??
                                const [])
                            .length,
                        lowBalance: _branchUsdEquivalent(
                                state, filteredBranches[i]) <
                            1000,
                        onTap: () => context
                            .read<DashboardBloc>()
                            .add(DashboardBranchSelected(
                                filteredBranches[i].id)),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                const SizedBox(height: AppSpacing.sm),

                PendingTransfersCard(
                  transfers: state.pendingTransfers,
                  branches: state.branches,
                ),
                const SizedBox(height: AppSpacing.md),

                const FxRatesCard(),
                const SizedBox(height: AppSpacing.md),

                const ActivityFeedCard(),
                const SizedBox(height: 80),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}

class _MobileSectionHeader extends StatelessWidget {
  const _MobileSectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
      ],
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Loading / Error
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: List.generate(
          4,
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: ShimmerLoading.card(height: 80),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: AppColors.error),
          const SizedBox(height: AppSpacing.md),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: () => context
                .read<DashboardBloc>()
                .add(const DashboardRefreshRequested()),
            icon: const Icon(Icons.refresh),
            label: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}

