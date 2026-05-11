import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
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
    final totalUsd =
        totals['USD'] ?? totals.values.fold<double>(0, (a, b) => a + b);
    final filteredBranches = _branchFilter == 'Все'
        ? state.branches
        : state.branches
            .where((b) => b.code.toUpperCase().contains(_branchFilter))
            .toList();
    final isDark = context.isDark;
    final bgGradient = isDark
        ? [
            AppColors.primary.withValues(alpha: 0.10),
            Colors.transparent,
          ]
        : [
            AppColors.primary.withValues(alpha: 0.05),
            Colors.transparent,
          ];

    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-1, -1),
          radius: 1.4,
          colors: bgGradient,
        ),
      ),
      child: RefreshIndicator(
        onRefresh: () async {
          context.read<DashboardBloc>().add(const DashboardRefreshRequested());
        },
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                100, // под bottom-bar с FAB
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  // ── Header (date label + Treasury title + actions) ──
                  _MobileHeader(pendingCount: state.pendingCount),
                  const SizedBox(height: AppSpacing.md),

                  // ── Hero balance card ──
                  if (widget.hasAllBranchesAccess || totals.isNotEmpty)
                    _HeroBalanceCard(totals: totals),
                  const SizedBox(height: AppSpacing.md),

                  // ── Quick actions: 4 крупные иконки ──
                  const _MobileQuickActions(),
                  const SizedBox(height: AppSpacing.md),

                  // ── KPI 2×2 ──
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.55,
                    children: [
                      _MobileKpiTile(
                        label: 'Филиалы',
                        value: '${state.branches.length}',
                        sub: '${state.branches.where((b) => b.isActive).length} активных',
                        icon: Icons.business_rounded,
                        color: AppColors.secondary,
                      ),
                      _MobileKpiTile(
                        label: 'Ожидают',
                        value: '${state.pendingCount}',
                        sub: state.pendingCount > 0
                            ? 'требуют действия'
                            : 'нет ожидающих',
                        icon: Icons.pending_actions_rounded,
                        color: AppColors.warning,
                        emphasizeValue: state.pendingCount > 0,
                      ),
                      _MobileKpiTile(
                        label: 'Счетов',
                        value: '${_accountCount(state)}',
                        sub: '${totals.length} валют${totals.length == 1 ? 'а' : (totals.length < 5 ? 'ы' : '')}',
                        icon: Icons.credit_card_rounded,
                        color: AppColors.primary,
                      ),
                      _MobileKpiTile(
                        label: 'Валюты',
                        value: '${totals.length}',
                        sub: 'на балансах',
                        icon: Icons.currency_exchange_rounded,
                        color: AppColors.info,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // ── Balance chart ──
                  BalanceChartCard(currentTotal: totalUsd),
                  const SizedBox(height: AppSpacing.md),

                  // ── Currency donut ──
                  CurrencyDonutCard(balancesByCurrency: totals),
                  const SizedBox(height: AppSpacing.lg),

                  // ── Branches header + chips ──
                  _MobileSectionHeader(
                    title: 'Филиалы',
                    actionLabel: 'Все',
                    onAction: () => context.go('/branches'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    height: 32,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _branchFilters.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (_, i) {
                        final f = _branchFilters[i];
                        return _FilterChip(
                          label: f,
                          selected: f == _branchFilter,
                          onTap: () => setState(() => _branchFilter = f),
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
                        child: _MobileBranchTile(
                          branch: filteredBranches[i],
                          balance: _branchUsdEquivalent(
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
                          onTap: () => context
                              .read<DashboardBloc>()
                              .add(DashboardBranchSelected(
                                  filteredBranches[i].id)),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  const SizedBox(height: AppSpacing.lg),

                  // ── Pending ──
                  PendingTransfersCard(
                    transfers: state.pendingTransfers,
                    branches: state.branches,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  // ── FX ──
                  const FxRatesCard(),
                  const SizedBox(height: AppSpacing.md),

                  // ── Activity ──
                  const ActivityFeedCard(),
                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Mobile Header ───

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({required this.pendingCount});
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final scheme = Theme.of(context).colorScheme;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    final now = DateTime.now();
    const months = [
      'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
    ];
    final dateLabel = '${now.day} ${months[now.month - 1]}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Дашборд · $dateLabel',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: secondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Treasury',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ],
          ),
        ),
        _HeaderIconButton(
          icon: Icons.search_rounded,
          onTap: () {},
        ),
        const SizedBox(width: 8),
        _HeaderIconButton(
          icon: Icons.notifications_outlined,
          onTap: () => context.go('/notifications'),
          badge: pendingCount > 0,
          badgeColor: scheme.tertiary == scheme.primary
              ? AppColors.warning
              : AppColors.warning,
        ),
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.badge = false,
    this.badgeColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool badge;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const SizedBox(width: 38, height: 38),
            Icon(icon, size: 18, color: scheme.onSurface),
            if (badge)
              Positioned(
                right: 9,
                top: 9,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: badgeColor ?? AppColors.warning,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Hero Balance Card ───

class _HeroBalanceCard extends StatelessWidget {
  const _HeroBalanceCard({required this.totals});
  final Map<String, double> totals;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final scheme = Theme.of(context).colorScheme;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    final ordered = _orderedTotals(totals);
    final mainEntry = ordered.isNotEmpty ? ordered.first : null;
    final secondaryLine = ordered.length > 1
        ? ordered
            .skip(1)
            .take(3)
            .map((e) => '${_compact(e.value)} ${e.key}')
            .join(' · ')
        : null;

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // Background card
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.16),
                  AppColors.secondary.withValues(alpha: 0.08),
                  scheme.surface,
                ],
                stops: const [0, 0.6, 1],
              ),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.18),
                width: 0.6,
              ),
            ),
          ),
        ),
        // Glow in top-right corner
        Positioned(
          top: -60,
          right: -60,
          width: 200,
          height: 200,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.22),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Общий баланс казначейства',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: secondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Live-indicator chip — обновляется realtime через ledger stream
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'live',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      mainEntry == null
                          ? '—'
                          : mainEntry.value.formatCurrencyNoDecimals(),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        height: 1,
                      ),
                    ),
                    if (mainEntry != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        mainEntry.key,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (secondaryLine != null) ...[
                const SizedBox(height: 6),
                Text(
                  '≈ $secondaryLine',
                  style: TextStyle(fontSize: 11.5, color: secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(2)} млрд';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(1)} млн';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)} тыс';
    return v.toStringAsFixed(0);
  }

  static List<MapEntry<String, double>> _orderedTotals(Map<String, double> t) {
    if (t.isEmpty) return const [];
    final order = const ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'KZT', 'KGS', 'TJS'];
    final entries = t.entries.where((e) => e.value != 0).toList();
    entries.sort((a, b) {
      final ai = order.indexOf(a.key);
      final bi = order.indexOf(b.key);
      if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
      if (ai >= 0) return -1;
      if (bi >= 0) return 1;
      return b.value.compareTo(a.value);
    });
    return entries;
  }
}

// ─── Mobile Quick Actions (4-up row) ───

class _MobileQuickActions extends StatelessWidget {
  const _MobileQuickActions();

  @override
  Widget build(BuildContext context) {
    final canBranchTopUp =
        context.read<AuthBloc>().state.user?.canBranchTopUp ?? false;
    final actions = <_QuickAct>[
      _QuickAct(
        icon: Icons.send_rounded,
        label: 'Перевод',
        color: AppColors.primary,
        onTap: () => context.goNamed(RouteNames.createTransfer),
      ),
      if (canBranchTopUp)
        _QuickAct(
          icon: Icons.add_business_rounded,
          label: 'Внести',
          color: AppColors.secondary,
          onTap: () => context.go('/transfers/topup'),
        )
      else
        _QuickAct(
          icon: Icons.receipt_long_rounded,
          label: 'Журнал',
          color: AppColors.secondary,
          onTap: () => context.go('/ledger'),
        ),
      _QuickAct(
        icon: Icons.currency_exchange_rounded,
        label: 'Курсы',
        color: AppColors.warning,
        onTap: () => context.go('/exchange-rates'),
      ),
      _QuickAct(
        icon: Icons.file_download_rounded,
        label: 'Отчёты',
        color: AppColors.info,
        onTap: () => context.go('/reports'),
      ),
    ];

    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          Expanded(child: _QuickActionTile(action: actions[i])),
          if (i < actions.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _QuickAct {
  const _QuickAct({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({required this.action});
  final _QuickAct action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: action.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: action.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(action.icon, color: action.color, size: 17),
              ),
              const SizedBox(height: 6),
              Text(
                action.label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Mobile KPI Tile ───

class _MobileKpiTile extends StatelessWidget {
  const _MobileKpiTile({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
    this.emphasizeValue = false,
  });

  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;
  final bool emphasizeValue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = scheme.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 14),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: secondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: emphasizeValue ? color : scheme.onSurface,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(fontSize: 11, color: secondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Mobile Section Header ───

class _MobileSectionHeader extends StatelessWidget {
  const _MobileSectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
  });
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.1,
            ),
          ),
          const Spacer(),
          if (actionLabel != null && onAction != null)
            InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      actionLabel!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Filter Chip (pill style) ───

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? AppColors.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(100),
        side: BorderSide(
          color: selected
              ? AppColors.primary
              : scheme.outline.withValues(alpha: 0.18),
          width: selected ? 1 : 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Mobile Branch Tile (compact horizontal) ───

class _MobileBranchTile extends StatelessWidget {
  const _MobileBranchTile({
    required this.branch,
    required this.balance,
    required this.shareOfTotal,
    required this.accountCount,
    required this.onTap,
  });

  final Branch branch;
  final double balance;
  final double shareOfTotal;
  final int accountCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final isLow = balance < 1000;
    final accent = isLow ? AppColors.error : AppColors.primary;

    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  branch.code.isNotEmpty
                      ? branch.code.substring(
                          0, branch.code.length.clamp(0, 3))
                      : '?',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            branch.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isLow) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: AppColors.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${branch.baseCurrency} · $accountCount счёт${accountCount == 1 ? '' : (accountCount < 5 ? 'а' : 'ов')} · ${(shareOfTotal * 100).toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 11, color: secondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(100),
                      child: LinearProgressIndicator(
                        value: shareOfTotal.clamp(0.0, 1.0).toDouble(),
                        minHeight: 3,
                        backgroundColor:
                            scheme.outline.withValues(alpha: 0.12),
                        valueColor: AlwaysStoppedAnimation(
                          accent.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _compact(balance),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: balance < 0
                          ? AppColors.error
                          : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    branch.baseCurrency,
                    style: TextStyle(fontSize: 10, color: secondary),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: secondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(2)} млрд';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(1)} млн';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)} тыс';
    return v.toStringAsFixed(0);
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

