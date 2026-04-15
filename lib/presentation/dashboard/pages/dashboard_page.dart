import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/theme/glassmorphism.dart';
import 'package:ethnocount/core/utils/balance_utils.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/dashboard/widgets/branch_balance_card.dart';
import 'package:ethnocount/presentation/dashboard/widgets/dashboard_currency_chart.dart';
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
            ? _DesktopDashboard(state: filtered, hasAllBranchesAccess: hasAllBranchesAccess)
            : _MobileDashboard(state: filtered, hasAllBranchesAccess: hasAllBranchesAccess);
      },
    );
  }
}

Map<String, double> _totalBalanceByCurrency(DashboardState state) {
  final allAccounts = state.branchAccounts.values.expand((l) => l).toList();
  return balanceByCurrency(allAccounts, state.accountBalances);
}

class _DesktopDashboard extends StatelessWidget {
  const _DesktopDashboard({required this.state, required this.hasAllBranchesAccess});
  final DashboardState state;
  final bool hasAllBranchesAccess;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ethno Logistics Treasury',
                      style: context.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${state.branches.length} филиалов • ${state.pendingCount} ожидающих переводов',
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TreasuryQuickActions(compact: true),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          // KPI row (overall balance only for users with access to all branches)
          Row(
            children: [
              if (hasAllBranchesAccess) ...[
                Expanded(child: _KpiCard(
                  label: 'Общий баланс',
                  icon: Icons.account_balance_wallet_rounded,
                  iconColor: AppColors.primary,
                  child: Text(
                    CurrencyUtils.formatBalanceBreakdown(_totalBalanceByCurrency(state)),
                    style: context.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                )),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(child: _KpiCard(
                label: 'Активных филиалов',
                icon: Icons.business_rounded,
                iconColor: AppColors.secondary,
                child: Text(
                  '${state.branches.length}',
                  style: context.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: _KpiCard(
                label: 'Ожидающие переводы',
                icon: Icons.pending_actions_rounded,
                iconColor: AppColors.warning,
                child: Text(
                  '${state.pendingCount}',
                  style: context.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: state.pendingCount > 0 ? AppColors.warning : null,
                  ),
                ),
              )),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: _KpiCard(
                label: 'Счетов',
                icon: Icons.credit_card_rounded,
                iconColor: AppColors.info,
                child: Text(
                  '${state.branchAccounts.values.fold<int>(0, (s, list) => s + list.length)}',
                  style: context.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          // Branches grid
          Text(
            'Филиалы',
            style: context.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: _BranchesGrid(
              state: state,
              crossAxisCount: context.isWidescreen ? 4 : 3,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileDashboard extends StatelessWidget {
  const _MobileDashboard({required this.state, required this.hasAllBranchesAccess});
  final DashboardState state;
  final bool hasAllBranchesAccess;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        context.read<DashboardBloc>().add(const DashboardRefreshRequested());
      },
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 80,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                'Treasury',
                style: context.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            sliver: SliverToBoxAdapter(
              child: GlassContainer(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _MobileQuickStatsRow(state: state),
                    const SizedBox(height: AppSpacing.md),
                    const Divider(height: 1),
                    const SizedBox(height: AppSpacing.md),
                    DashboardCurrencyChart(
                      balancesByCurrency: _totalBalanceByCurrency(state),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (hasAllBranchesAccess)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              sliver: SliverToBoxAdapter(
                child: _TotalBalanceCard(state: state),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            sliver: SliverToBoxAdapter(
              child: TreasuryQuickActions(compact: false),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.sectionGap)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            sliver: SliverList.builder(
              itemCount: state.branches.length,
              itemBuilder: (context, index) {
                final branch = state.branches[index];
                final accounts = state.branchAccounts[branch.id] ?? [];
                final byCur = balanceByCurrency(accounts, state.accountBalances);
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: BranchBalanceCard(
                    branch: branch,
                    accountCount: accounts.length,
                    balancesByCurrency: byCur,
                    onTap: () => context.read<DashboardBloc>().add(
                          DashboardBranchSelected(branch.id),
                        ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileQuickStatsRow extends StatelessWidget {
  const _MobileQuickStatsRow({required this.state});
  final DashboardState state;

  @override
  Widget build(BuildContext context) {
    final accountCount = state.branchAccounts.values
        .fold<int>(0, (s, list) => s + list.length);
    return Row(
      children: [
        Expanded(
          child: _MiniStatTile(
            icon: Icons.business_rounded,
            label: 'Филиалы',
            value: '${state.branches.length}',
            color: AppColors.secondary,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _MiniStatTile(
            icon: Icons.pending_actions_rounded,
            label: 'Ожидают',
            value: '${state.pendingCount}',
            color: state.pendingCount > 0
                ? AppColors.warning
                : AppColors.info,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _MiniStatTile(
            icon: Icons.account_balance_wallet_rounded,
            label: 'Счетов',
            value: '$accountCount',
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}

class _MiniStatTile extends StatelessWidget {
  const _MiniStatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(
          color: color.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
              fontFamily: 'JetBrains Mono',
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalBalanceCard extends StatelessWidget {
  const _TotalBalanceCard({required this.state});
  final DashboardState state;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Общий баланс казначейства',
            style: context.textTheme.bodySmall?.copyWith(
              color: context.isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            CurrencyUtils.formatBalanceBreakdown(_totalBalanceByCurrency(state)),
            style: context.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFamily: 'JetBrains Mono',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _MetricChip(
                icon: Icons.business,
                label: '${state.branches.length} филиалов',
              ),
              const SizedBox(width: AppSpacing.md),
              _MetricChip(
                icon: Icons.pending_actions,
                label: '${state.pendingCount} ожидающих',
                color: state.pendingCount > 0 ? AppColors.warning : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final chipColor = color ??
        (context.isDark
            ? AppColors.darkTextSecondary
            : AppColors.lightTextSecondary);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: chipColor),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: chipColor)),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.child,
    required this.icon,
    required this.iconColor,
  });

  final String label;
  final Widget child;
  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 4),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchesGrid extends StatelessWidget {
  const _BranchesGrid({required this.state, required this.crossAxisCount});
  final DashboardState state;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
        childAspectRatio: 2.2,
      ),
      itemCount: state.branches.length,
      itemBuilder: (context, index) {
        final branch = state.branches[index];
        final accounts = state.branchAccounts[branch.id] ?? [];
        final byCur = balanceByCurrency(accounts, state.accountBalances);

        return FadeSlideTransition(
          delay: Duration(milliseconds: index * 50),
          child: _DesktopBranchCard(
            branch: branch,
            accounts: accounts,
            balancesByCurrency: byCur,
            balances: state.accountBalances,
            onAccountTap: (acc) => context.go(
              '/ledger?branchId=${branch.id}&accountId=${acc.id}',
            ),
          ),
        );
      },
    );
  }
}

class _DesktopBranchCard extends StatelessWidget {
  const _DesktopBranchCard({
    required this.branch,
    required this.accounts,
    required this.balancesByCurrency,
    required this.balances,
    this.onAccountTap,
  });

  final Branch branch;
  final List<BranchAccount> accounts;
  final Map<String, double> balancesByCurrency;
  final Map<String, double> balances;
  final void Function(BranchAccount)? onAccountTap;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              onTap: () => context.read<DashboardBloc>().add(
                    DashboardBranchSelected(branch.id),
                  ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      branch.code,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          branch.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${branch.baseCurrency} • ${accounts.length} счетов',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? AppColors.darkTextSecondary
                                : AppColors.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (accounts.isNotEmpty && onAccountTap != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: accounts.take(4).map((acc) {
                  final bal = balances[acc.id] ?? 0;
                  return Tooltip(
                    message: '${acc.name}: ${bal.toStringAsFixed(2)} ${acc.currency}\nНажмите — полная история',
                    child: InkWell(
                      onTap: () => onAccountTap!(acc),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.white : Colors.black)
                              .withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              acc.type.icon,
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              acc.name,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${bal.formatCurrency()} ${acc.currency}',
                              style: TextStyle(
                                fontSize: 10,
                                fontFamily: 'JetBrains Mono',
                                color: bal >= 0
                                    ? AppColors.primary
                                    : AppColors.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
            const Spacer(),
            Text(
              CurrencyUtils.formatBalanceBreakdown(balancesByCurrency),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFamily: 'JetBrains Mono',
                color: (balancesByCurrency.values.fold(0.0, (a, b) => a + b) >= 0)
                    ? (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary)
                    : AppColors.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
