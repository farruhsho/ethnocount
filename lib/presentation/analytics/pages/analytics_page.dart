import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/balance_utils.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/presentation/analytics/bloc/analytics_bloc.dart';
import 'package:ethnocount/presentation/analytics/widgets/commission_profit_card.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';
import 'package:ethnocount/presentation/dashboard/widgets/delta_chip.dart';
import 'package:ethnocount/presentation/dashboard/widgets/kpi_card.dart';
import 'package:ethnocount/core/icons/app_icons.dart';

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AnalyticsBloc>().add(const AnalyticsLoadRequested());
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final bloc = context.read<AnalyticsBloc>();
    bloc.add(
      AnalyticsLoadRequested(
        excludeCounterpartyAccounts: bloc.state.excludeCounterpartyAccounts,
      ),
    );
    await bloc.stream.firstWhere((s) => !s.isLoading);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Аналитика'),
        elevation: 0,
        actions: [
          BlocBuilder<AnalyticsBloc, AnalyticsBlocState>(
            buildWhen: (a, b) =>
                a.excludeCounterpartyAccounts != b.excludeCounterpartyAccounts,
            builder: (context, state) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Без транзита',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Switch(
                    value: state.excludeCounterpartyAccounts,
                    onChanged: (v) => context.read<AnalyticsBloc>().add(
                          AnalyticsLoadRequested(
                            excludeCounterpartyAccounts: v,
                          ),
                        ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(AppIcons.refresh),
            tooltip: 'Обновить',
            onPressed: () => context.read<AnalyticsBloc>().add(
                  AnalyticsLoadRequested(
                    excludeCounterpartyAccounts: context
                        .read<AnalyticsBloc>()
                        .state
                        .excludeCounterpartyAccounts,
                  ),
                ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Обзор', icon: Icon(AppIcons.insights)),
            Tab(text: 'Казначейство', icon: Icon(AppIcons.account_balance)),
            Tab(text: 'Переводы', icon: Icon(AppIcons.swap_horiz)),
            Tab(text: 'Филиалы', icon: Icon(AppIcons.business)),
            Tab(text: 'Валюты', icon: Icon(AppIcons.currency_exchange)),
            Tab(text: 'Партнёры', icon: Icon(AppIcons.account_tree)),
            Tab(text: 'Прибыль', icon: Icon(AppIcons.payments)),
          ],
        ),
      ),
      body: BlocBuilder<AnalyticsBloc, AnalyticsBlocState>(
        builder: (context, rawState) {
          if (rawState.isLoading && rawState.treasury == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (rawState.errorMessage != null) {
            return _ErrorView(message: rawState.errorMessage!);
          }
          // Бухгалтер видит аналитику только своего филиала; директор и
          // creator — общую. Фильтр применяется на клиенте поверх raw данных.
          final user = context.read<AuthBloc>().state.user;
          final state = _scopeForUser(rawState, user);
          return TabBarView(
            controller: _tabController,
            children: [
              RefreshIndicator(
                onRefresh: _refresh,
                child: _OverviewTab(state: state),
              ),
              RefreshIndicator(
                onRefresh: _refresh,
                child: _TreasuryTab(state: state),
              ),
              RefreshIndicator(
                onRefresh: _refresh,
                child: _TransfersTab(state: state),
              ),
              RefreshIndicator(
                onRefresh: _refresh,
                child: _BranchesTab(state: state),
              ),
              RefreshIndicator(
                onRefresh: _refresh,
                child: _CurrenciesTab(state: state),
              ),
              RefreshIndicator(
                onRefresh: _refresh,
                child: const _PartnersTab(),
              ),
              // Прибыль с комиссий: per-branch × per-currency × период.
              // Использует RPC commission_profit_by_branch / _totals
              // (миграция 050). Виджет self-contained, со своим
              // фильтром периода — не зависит от AnalyticsBloc.
              SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: const CommissionProfitCard(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Ограничивает аналитику для бухгалтера — он видит только свой филиал;
/// директор и creator получают полный raw-state.
/// Фильтрует branches + переcчитывает treasury totalLiquidity на основе
/// видимых филиалов (без них бухгалтер видел общую ликвидность всей сети).
AnalyticsBlocState _scopeForUser(AnalyticsBlocState raw, AppUser? user) {
  if (user == null || user.role.isAdminOrCreator || user.role.isDirector) {
    return raw;
  }
  final allowed = user.assignedBranchIds.toSet();
  if (allowed.isEmpty) return raw;
  final filteredBranches =
      raw.branches.where((b) => allowed.contains(b.branchId)).toList();

  // Treasury — сумма ликвидности только по доступным филиалам.
  // raw.treasury.totalLiquidity содержит всю сеть; пересобираем из
  // filteredBranches.balancesByCurrency.
  TreasuryOverviewModel? scopedTreasury;
  if (raw.treasury != null) {
    final liq = <String, double>{};
    for (final b in filteredBranches) {
      b.balancesByCurrency.forEach((cur, val) {
        liq[cur] = (liq[cur] ?? 0) + val;
      });
    }
    scopedTreasury = TreasuryOverviewModel(
      totalLiquidity: liq,
      capitalByBranchByCurrency: raw.treasury!.capitalByBranchByCurrency,
      pendingLockedByCurrency: const {},
      largeTransfers: const [],
    );
  }

  return raw.copyWith(
    branches: filteredBranches,
    treasury: scopedTreasury,
  );
}

/// Возвращает branch_id для accountant (его единственный assigned филиал),
/// null для creator/director (без фильтра). Используется в RPC-вызовах
/// `partner_profit_*` чтобы бухгалтер не получал данные чужих филиалов.
String? _branchScopeFor(AppUser? user) {
  if (user == null) return null;
  if (user.role.isAdminOrCreator || user.role.isDirector) return null;
  if (user.assignedBranchIds.isEmpty) return null;
  return user.assignedBranchIds.first;
}

// ────────────────────────────────────────────────────────────────
// Error view
// ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.error_outline, size: 48, color: AppColors.error),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: () => context
                .read<AnalyticsBloc>()
                .add(const AnalyticsLoadRequested()),
            icon: const Icon(AppIcons.refresh),
            label: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Tab 1: Обзор — mission control
// ────────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.state});
  final AnalyticsBlocState state;

  @override
  Widget build(BuildContext context) {
    final treasury = state.treasury;
    final transfers = state.transfers;
    final branches = state.branches;

    final isWide = MediaQuery.sizeOf(context).width >= 900;

    final liquidityPrimary = _primaryLiquidity(treasury);
    final lockedPrimary = _primaryLocked(treasury);
    final lockedPct = (liquidityPrimary > 0)
        ? lockedPrimary / liquidityPrimary * 100
        : 0.0;

    final totalCount = transfers?.totalCount ?? 0;
    final successRate = (totalCount > 0)
        ? (transfers!.confirmedCount + transfers.issuedCount) /
            totalCount *
            100
        : 0.0;
    final issuanceRate = (transfers?.confirmedCount ?? 0) > 0
        ? transfers!.issuedCount /
            (transfers.confirmedCount + transfers.issuedCount) *
            100
        : 0.0;
    final rejectionRate = 0.0; // отклонение/отмена удалены из workflow

    // ── Monthly counts aggregated across branches for MoM delta ──
    final monthly = _aggregateMonthlyCounts(branches);
    final monthsSorted = monthly.keys.toList()..sort();
    int currMonth = 0, prevMonth = 0;
    if (monthsSorted.isNotEmpty) {
      currMonth = monthly[monthsSorted.last] ?? 0;
      if (monthsSorted.length >= 2) {
        prevMonth = monthly[monthsSorted[monthsSorted.length - 2]] ?? 0;
      }
    }
    final momDelta =
        prevMonth > 0 ? (currMonth - prevMonth) / prevMonth * 100 : null;

    // ── Health score (0-100) ──
    final health = _computeHealthScore(
      treasury: treasury,
      transfers: transfers,
      branches: branches,
    );

    final activeBranches = branches.where((b) =>
        b.confirmedTransfersCount > 0 ||
        b.pendingTransfersCount > 0).length;

    final kpis = [
      KpiCard(
        label: 'Общая ликвидность',
        primary: liquidityPrimary > 0
            ? '${formatNumberSpaced(liquidityPrimary)} ${_primaryLiquidityCurrency(treasury)}'
            : '—',
        secondary: treasury == null
            ? null
            : _multiCurrencySubtitle(treasury.totalLiquidity),
        icon: AppIcons.account_balance_wallet,
        iconColor: AppColors.primary,
        hero: true,
      ),
      KpiCard(
        label: 'Заблокировано',
        primary: lockedPrimary > 0
            ? '${formatNumberSpaced(lockedPrimary)} ${_primaryLiquidityCurrency(treasury)}'
            : '0',
        secondary: '${lockedPct.toStringAsFixed(1)}% от ликвидности',
        icon: AppIcons.lock_clock,
        iconColor: AppColors.warning,
      ),
      KpiCard(
        label: 'Переводов всего',
        primary: '$totalCount',
        secondary: transfers == null
            ? null
            : 'Ср. размер ${formatNumberSpaced(_avgSize(transfers))}',
        icon: AppIcons.receipt_long,
        iconColor: AppColors.secondary,
        delta: momDelta == null
            ? null
            : '${momDelta >= 0 ? '+' : ''}${momDelta.toStringAsFixed(1)}%',
        deltaValue: momDelta,
      ),
      KpiCard(
        label: 'Доля успеха',
        primary: '${successRate.toStringAsFixed(1)}%',
        secondary: 'Отклонено ${rejectionRate.toStringAsFixed(1)}%',
        icon: AppIcons.task_alt,
        iconColor: AppColors.success,
      ),
    ];

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero block: composite health + meta
          _HeroSummary(
            healthScore: health,
            activeBranches: activeBranches,
            totalBranches: branches.length,
            totalOps: totalCount,
            generatedAt: state.generatedAt,
          ),
          const SizedBox(height: AppSpacing.xl),

          _SectionTitle('Ключевые показатели'),
          const SizedBox(height: AppSpacing.md),
          _GridOfKpis(items: kpis, isWide: isWide),
          const SizedBox(height: AppSpacing.xl),

          // Monthly activity chart
          if (monthly.length >= 2) ...[
            _SectionTitle('Динамика операций'),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(
              child: _MonthlyOpsChart(monthly: monthly),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Operations health
          _SectionTitle('Здоровье операций'),
          const SizedBox(height: AppSpacing.md),
          _GridOfKpis(
            isWide: isWide,
            items: [
              KpiCard(
                label: 'Подтверждение',
                primary: totalCount > 0
                    ? '${((transfers!.confirmedCount + transfers.issuedCount) / totalCount * 100).toStringAsFixed(1)}%'
                    : '—',
                secondary: 'Принято + выдано',
                icon: AppIcons.check_circle,
                iconColor: AppColors.success,
              ),
              KpiCard(
                label: 'Выдача',
                primary: '${issuanceRate.toStringAsFixed(1)}%',
                secondary: 'От принятых',
                icon: AppIcons.outbox,
                iconColor: Colors.teal,
              ),
              KpiCard(
                label: 'У курьера',
                primary: transfers == null ? '—' : '${transfers.withCourierCount}',
                secondary: 'В транзите',
                icon: AppIcons.local_shipping,
                iconColor: AppColors.info,
              ),
              KpiCard(
                label: 'Время обработки',
                primary: transfers?.avgProcessingFormatted ?? '—',
                secondary: 'Среднее по периоду',
                icon: AppIcons.timer,
                iconColor: AppColors.info,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),

          // Status overview chart + breakdown
          if (transfers != null && totalCount > 0) ...[
            _SectionTitle('Статусы переводов'),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 260,
                          height: 220,
                          child: _StatusPie(transfers: transfers),
                        ),
                        const SizedBox(width: AppSpacing.xl),
                        Expanded(
                          child: _StatusLegend(transfers: transfers),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        SizedBox(
                          height: 200,
                          child: _StatusPie(transfers: transfers),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _StatusLegend(transfers: transfers),
                      ],
                    ),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Branch leaderboard
          if (branches.isNotEmpty) ...[
            _SectionTitle('Топ филиалов по подтверждённым переводам'),
            const SizedBox(height: AppSpacing.md),
            _BranchLeaderboard(branches: branches),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Concentration card
          if (branches.length >= 2) ...[
            _SectionTitle('Концентрация сети'),
            const SizedBox(height: AppSpacing.md),
            _ConcentrationCard(branches: branches),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Партнёры — секция с топом и прибылью
          const _PartnerProfitOverview(),
          const SizedBox(height: AppSpacing.xl),

          // Pending backlog warning
          _PendingBacklogStrip(branches: branches),
        ],
      ),
    );
  }
}

/// Сводка по партнёрским переводам: топ-N партнёров по объёму +
/// агрегированная прибыль с курса и комиссии. Тянет через
/// `partner_profit_top_partners` RPC (миграция 036). Если миграция не
/// применена — секция тихо скрывается (без ошибок).
class _PartnerProfitOverview extends StatefulWidget {
  const _PartnerProfitOverview();

  @override
  State<_PartnerProfitOverview> createState() =>
      _PartnerProfitOverviewState();
}

class _PartnerProfitOverviewState extends State<_PartnerProfitOverview> {
  List<Map<String, dynamic>> _top = const [];
  bool _loading = true;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _unavailable = false;
    });
    try {
      // Период — последний месяц (как и monthly chart выше).
      final start = DateTime.now().subtract(const Duration(days: 30));
      final user = context.read<AuthBloc>().state.user;
      final branchScope = _branchScopeFor(user);
      final params = <String, dynamic>{
        'p_start': start.toUtc().toIso8601String(),
        'p_limit': 5,
      };
      if (branchScope != null) params['p_branch_id'] = branchScope;
      final rows = await Supabase.instance.client
          .rpc('partner_profit_top_partners', params: params)
          .timeout(const Duration(seconds: 15));
      final list =
          (rows as List).map((m) => Map<String, dynamic>.from(m as Map)).toList();
      if (!mounted) return;
      setState(() {
        _top = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _loading = false;
        _unavailable = s.contains('PGRST') ||
            s.contains('42883') ||
            s.contains('does not exist');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) {
      // Тихо скрываемся — не пугаем пользователя «миграция отсутствует»
      // на главной вкладке.
      return const SizedBox.shrink();
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (_top.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final totalSpread = _top.fold<double>(
        0, (s, r) => s + ((r['total_spread_proxy'] as num?)?.toDouble() ?? 0));
    final totalCommission = _top.fold<double>(
        0,
        (s, r) =>
            s + ((r['total_commission_proxy'] as num?)?.toDouble() ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Партнёры — топ за 30 дней'),
        const SizedBox(height: AppSpacing.md),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Суммарная плашка.
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Row(
                  children: [
                    Icon(Icons.trending_up,
                        size: 18, color: Colors.green.shade600),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Прибыль с партнёрских переводов за период',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    _ProfitChip(
                        label: 'Курс',
                        value: totalSpread,
                        color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    _ProfitChip(
                        label: 'Комиссия',
                        value: totalCommission,
                        color: scheme.primary),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final r in _top) _TopPartnerRow(row: r),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfitChip extends StatelessWidget {
  const _ProfitChip({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
              color: color,
            ),
          ),
          Text(
            formatNumberSpaced(value),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopPartnerRow extends StatelessWidget {
  const _TopPartnerRow({required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = (row['name'] ?? '—').toString();
    final city = (row['city'] as String?)?.trim() ?? '';
    final txCount = (row['transfer_count'] as num?)?.toInt() ?? 0;
    final volume = (row['total_volume_usd_proxy'] as num?)?.toDouble() ?? 0;
    final spread = (row['total_spread_proxy'] as num?)?.toDouble() ?? 0;
    final commission =
        (row['total_commission_proxy'] as num?)?.toDouble() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: scheme.primary.withValues(alpha: 0.15),
            child: Text(
              name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '$txCount оп. · объём ≈ ${formatNumberSpaced(volume)}'
                  '${city.isEmpty ? '' : ' · $city'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (spread > 0 || commission > 0)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.trending_up,
                      size: 12, color: Colors.green.shade700),
                  const SizedBox(width: 4),
                  Text(
                    formatNumberSpaced(spread + commission),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.green.shade700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Tab 2: Казначейство
// ────────────────────────────────────────────────────────────────

class _TreasuryTab extends StatelessWidget {
  const _TreasuryTab({required this.state});
  final AnalyticsBlocState state;

  @override
  Widget build(BuildContext context) {
    final treasury = state.treasury;
    if (treasury == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          EmptyState(
            icon: AppIcons.account_balance,
            title: 'Нет данных казначейства',
            subtitle: 'Подождите загрузки или нажмите Обновить.',
          ),
        ],
      );
    }
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Ликвидность по валютам'),
          const SizedBox(height: AppSpacing.md),
          _LiquidityGrid(
            liquidity: treasury.totalLiquidity,
            locked: treasury.pendingLockedByCurrency,
            isWide: isWide,
          ),
          const SizedBox(height: AppSpacing.xl),

          if (treasury.totalLiquidity.length >= 2) ...[
            _SectionTitle('Структура ликвидности'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Размер сектора — относительный объём в его валюте.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 220,
                          height: 200,
                          child: _CurrencyMixDonut(
                              liquidity: treasury.totalLiquidity),
                        ),
                        const SizedBox(width: AppSpacing.xl),
                        Expanded(
                          child: _CurrencyMixLegend(
                              liquidity: treasury.totalLiquidity),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        SizedBox(
                          height: 200,
                          child: _CurrencyMixDonut(
                              liquidity: treasury.totalLiquidity),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _CurrencyMixLegend(
                            liquidity: treasury.totalLiquidity),
                      ],
                    ),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Free vs locked
          _SectionTitle('Свободная ликвидность'),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            child: _LiquidityBreakdown(
              liquidity: treasury.totalLiquidity,
              locked: treasury.pendingLockedByCurrency,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // Top branches by capital
          if (treasury.capitalByBranchByCurrency.length >= 2) ...[
            _SectionTitle('Топ филиалов по капиталу'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'По основной валюте сети (наибольшая ликвидность).',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.md),
            _TopBranchesByCapital(
              primaryCurrency: _primaryLiquidityCurrency(treasury),
              capitalByBranchByCurrency: treasury.capitalByBranchByCurrency,
              branches: state.branches,
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Capital by branch table
          _SectionTitle('Капитал по филиалам'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Баланс по валютам — сложение разных валют не производится.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          _CapitalByBranchTable(
            capitalByBranchByCurrency: treasury.capitalByBranchByCurrency,
            branches: state.branches,
          ),
          if (treasury.largeTransfers.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            _SectionTitle('Крупные переводы (30 дней)'),
            const SizedBox(height: AppSpacing.md),
            _LargeTransfersList(transfers: treasury.largeTransfers),
          ],
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Tab 3: Переводы
// ────────────────────────────────────────────────────────────────

class _TransfersTab extends StatelessWidget {
  const _TransfersTab({required this.state});
  final AnalyticsBlocState state;

  @override
  Widget build(BuildContext context) {
    final t = state.transfers;
    if (t == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          EmptyState(
            icon: AppIcons.swap_horiz,
            title: 'Нет данных о переводах',
            subtitle: 'Подождите загрузки или нажмите Обновить.',
          ),
        ],
      );
    }
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    String? avgTicketLabel;
    if (t.volumeByCurrency.isNotEmpty && t.totalCount > 0) {
      final top = t.volumeByCurrency.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final v = top.first;
      avgTicketLabel =
          '${formatNumberSpaced(v.value / t.totalCount)} ${v.key}';
    } else if (t.totalCount > 0) {
      avgTicketLabel = formatNumberSpaced(t.totalVolume / t.totalCount);
    }

    final conversionRate = t.totalCount > 0
        ? (t.confirmedCount + t.issuedCount) / t.totalCount * 100
        : 0.0;

    double commissionRate = 0;
    if (t.volumeByCurrency.isNotEmpty) {
      final volume =
          t.volumeByCurrency.values.fold<double>(0, (a, b) => a + b);
      if (volume > 0) commissionRate = t.totalCommissions / volume * 100;
    } else if (t.totalVolume > 0) {
      commissionRate = t.totalCommissions / t.totalVolume * 100;
    }

    final kpis = <Widget>[
      ...t.volumeByCurrency.entries.map(
        (e) => KpiCard(
          label: 'Объём (${e.key})',
          primary: formatNumberSpaced(e.value),
          secondary: e.value > 0
              ? '${(t.totalCount > 0 ? e.value / t.totalCount : 0).toStringAsFixed(2)} ср.'
              : null,
          icon: AppIcons.trending_up,
          iconColor: AppColors.primary,
        ),
      ),
      if (t.volumeByCurrency.isEmpty)
        KpiCard(
          label: 'Объём (сумма amount)',
          primary: formatNumberSpaced(t.totalVolume),
          icon: AppIcons.trending_up,
          iconColor: AppColors.primary,
        ),
      KpiCard(
        label: 'Всего переводов',
        primary: '${t.totalCount}',
        secondary: avgTicketLabel == null ? null : 'Ср. чек $avgTicketLabel',
        icon: AppIcons.receipt_long,
        iconColor: AppColors.secondary,
      ),
      KpiCard(
        label: 'Конверсия',
        primary: '${conversionRate.toStringAsFixed(1)}%',
        secondary: 'Приняты или выданы',
        icon: AppIcons.task_alt,
        iconColor: AppColors.success,
      ),
      KpiCard(
        label: 'Ср. время обработки',
        primary: t.avgProcessingFormatted,
        icon: AppIcons.timer,
        iconColor: Colors.teal,
      ),
      KpiCard(
        label: 'Комиссии',
        primary: formatNumberSpaced(t.totalCommissions),
        secondary: commissionRate > 0
            ? '${commissionRate.toStringAsFixed(2)}% от объёма'
            : 'Сумма по всем валютам',
        icon: AppIcons.payments,
        iconColor: Colors.deepOrange,
      ),
    ];

    final monthly = _aggregateMonthlyCounts(state.branches);

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Объём и динамика'),
          const SizedBox(height: AppSpacing.md),
          _GridOfKpis(items: kpis, isWide: isWide),
          const SizedBox(height: AppSpacing.xl),

          if (monthly.length >= 2) ...[
            _SectionTitle('Помесячная активность'),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(child: _MonthlyOpsChart(monthly: monthly)),
            const SizedBox(height: AppSpacing.xl),
          ],

          _SectionTitle('Воронка статусов'),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(child: _StatusFunnel(transfers: t)),
          const SizedBox(height: AppSpacing.xl),

          _SectionTitle('Распределение по статусам'),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 320,
                          height: 220,
                          child: _StatusBarChart(transfers: t)),
                      const SizedBox(width: AppSpacing.xl),
                      Expanded(child: _StatusLegend(transfers: t)),
                    ],
                  )
                : Column(
                    children: [
                      SizedBox(
                          height: 200, child: _StatusBarChart(transfers: t)),
                      const SizedBox(height: AppSpacing.md),
                      _StatusLegend(transfers: t),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Tab 4: Филиалы
// ────────────────────────────────────────────────────────────────

enum _BranchSort { activity, pending, name }

class _BranchesTab extends StatefulWidget {
  const _BranchesTab({required this.state});
  final AnalyticsBlocState state;

  @override
  State<_BranchesTab> createState() => _BranchesTabState();
}

class _BranchesTabState extends State<_BranchesTab> {
  _BranchSort _sort = _BranchSort.activity;

  @override
  Widget build(BuildContext context) {
    final branches = widget.state.branches;
    if (branches.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          EmptyState(
            icon: AppIcons.business,
            title: 'Нет данных по филиалам',
            subtitle: 'Подождите загрузки или нажмите Обновить.',
          ),
        ],
      );
    }

    final sorted = [...branches];
    switch (_sort) {
      case _BranchSort.activity:
        sorted.sort((a, b) =>
            b.confirmedTransfersCount.compareTo(a.confirmedTransfersCount));
        break;
      case _BranchSort.pending:
        sorted.sort((a, b) =>
            b.pendingTransfersCount.compareTo(a.pendingTransfersCount));
        break;
      case _BranchSort.name:
        sorted.sort((a, b) => a.branchName
            .toLowerCase()
            .compareTo(b.branchName.toLowerCase()));
        break;
    }

    final avgConfirmed = branches.isEmpty
        ? 0.0
        : branches.fold<int>(0, (s, b) => s + b.confirmedTransfersCount) /
            branches.length;

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: sorted.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, i) {
        if (i == 0) {
          return _BranchSortBar(
            sort: _sort,
            onChanged: (s) => setState(() => _sort = s),
            total: branches.length,
          );
        }
        return _BranchCard(
          branch: sorted[i - 1],
          avgConfirmed: avgConfirmed,
        );
      },
    );
  }
}

class _BranchSortBar extends StatelessWidget {
  const _BranchSortBar({
    required this.sort,
    required this.onChanged,
    required this.total,
  });
  final _BranchSort sort;
  final ValueChanged<_BranchSort> onChanged;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          '$total ${_plural(total, ["филиал", "филиала", "филиалов"])}',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        SegmentedButton<_BranchSort>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStateProperty.all(
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          segments: const [
            ButtonSegment(
              value: _BranchSort.activity,
              label: Text('Активность'),
              icon: Icon(AppIcons.bolt, size: 14),
            ),
            ButtonSegment(
              value: _BranchSort.pending,
              label: Text('Ожидание'),
              icon: Icon(AppIcons.schedule, size: 14),
            ),
            ButtonSegment(
              value: _BranchSort.name,
              label: Text('А-Я'),
              icon: Icon(AppIcons.sort_by_alpha, size: 14),
            ),
          ],
          selected: {sort},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({required this.branch, this.avgConfirmed = 0});
  final BranchAnalyticsModel branch;
  final double avgConfirmed;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final scheme = Theme.of(context).colorScheme;
    final balances = branch.balancesByCurrency.isNotEmpty
        ? branch.balancesByCurrency
        : balanceByCurrencyFromAccounts(branch.accounts);
    final hasBacklog = branch.pendingTransfersCount > 0;

    final deltaVsAvg = avgConfirmed > 0
        ? (branch.confirmedTransfersCount - avgConfirmed) / avgConfirmed * 100
        : null;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.md,
          ),
          leading: CircleAvatar(
            backgroundColor: AppColors.primarySurface,
            child: Text(
              branch.branchName.isNotEmpty ? branch.branchName[0] : '?',
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          title: Text(
            branch.branchName,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              CurrencyUtils.formatBalanceBreakdown(balances),
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasBacklog)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    '${branch.pendingTransfersCount} ожид.',
                    style: const TextStyle(
                      color: AppColors.warning,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              const Icon(AppIcons.expand_more, size: 20),
            ],
          ),
          children: [
            Row(
              children: [
                _MiniStat(
                  'Подтверждено',
                  '${branch.confirmedTransfersCount}',
                  AppColors.success,
                ),
                const SizedBox(width: AppSpacing.lg),
                _MiniStat(
                  'В ожидании',
                  '${branch.pendingTransfersCount}',
                  AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.lg),
                _MiniStat(
                  'Комиссии',
                  formatNumberSpaced(branch.totalCommissions),
                  AppColors.primary,
                ),
                if (deltaVsAvg != null) ...[
                  const Spacer(),
                  DeltaChip(
                    label:
                        '${deltaVsAvg >= 0 ? '+' : ''}${deltaVsAvg.toStringAsFixed(0)}% vs ср.',
                    delta: deltaVsAvg,
                  ),
                ],
              ],
            ),
            if (branch.accounts.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              const _SubTitle('Счета'),
              const SizedBox(height: AppSpacing.xs),
              ...branch.accounts.entries.map((e) {
                final acc = Map<String, dynamic>.from(e.value as Map);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.key,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        '${formatNumberSpaced(acc['balance'] ?? 0)} ${acc['currency'] ?? ''}',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: ((acc['balance'] as num?)?.toDouble() ?? 0) < 0
                              ? AppColors.error
                              : scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
            if (branch.monthlySummary.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              const _SubTitle('Помесячная активность'),
              const SizedBox(height: AppSpacing.xs),
              _MonthlyTable(monthly: branch.monthlySummary),
            ],
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Tab 5: Валюты
// ────────────────────────────────────────────────────────────────

class _CurrenciesTab extends StatelessWidget {
  const _CurrenciesTab({required this.state});
  final AnalyticsBlocState state;

  @override
  Widget build(BuildContext context) {
    final currencies = state.currencies;
    if (currencies.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          EmptyState(
            icon: AppIcons.currency_exchange,
            title: 'Нет данных по валютам',
            subtitle: 'Когда будут конвертации — здесь появятся пары и курсы.',
          ),
        ],
      );
    }

    final totalVolume =
        currencies.fold<double>(0, (s, c) => s + c.conversionVolume);

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: currencies.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, i) => _CurrencyPairCard(
        model: currencies[i],
        totalConversionVolume: totalVolume,
      ),
    );
  }
}

class _CurrencyPairCard extends StatelessWidget {
  const _CurrencyPairCard({
    required this.model,
    required this.totalConversionVolume,
  });
  final CurrencyAnalyticsModel model;
  final double totalConversionVolume;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final scheme = Theme.of(context).colorScheme;

    final history = model.rateHistory;
    double? prev;
    if (history.length >= 2) {
      prev = (history[1]['rate'] as num?)?.toDouble();
    }
    final deltaPct = (prev != null && prev != 0)
        ? ((model.latestRate - prev) / prev * 100)
        : null;

    double minRate = 0, maxRate = 0, avgRate = 0, volatility = 0;
    if (history.isNotEmpty) {
      final rates = history
          .map((e) => (e['rate'] as num?)?.toDouble() ?? 0)
          .where((r) => r > 0)
          .toList();
      if (rates.isNotEmpty) {
        maxRate = rates.reduce((a, b) => a > b ? a : b);
        minRate = rates.reduce((a, b) => a < b ? a : b);
        avgRate = rates.reduce((a, b) => a + b) / rates.length;
        if (avgRate > 0) volatility = (maxRate - minRate) / avgRate * 100;
      }
    }

    final volumeShare = totalConversionVolume > 0
        ? model.conversionVolume / totalConversionVolume * 100
        : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _pairFlag(model.pair),
                style: const TextStyle(fontSize: 22),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  model.pair,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (deltaPct != null)
                DeltaChip(
                  label:
                      '${deltaPct >= 0 ? '+' : ''}${deltaPct.toStringAsFixed(2)}%',
                  delta: deltaPct,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Текущий курс',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      model.latestRate.toStringAsFixed(4),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _MiniStat(
                          'Волатильность',
                          '${volatility.toStringAsFixed(2)}%',
                          volatility > 5 ? AppColors.warning : AppColors.info,
                        ),
                        const SizedBox(width: AppSpacing.md),
                        _MiniStat(
                          'Объём конв.',
                          formatNumberSpaced(model.conversionVolume),
                          AppColors.primary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (history.isNotEmpty)
                SizedBox(
                  width: 140,
                  height: 80,
                  child: _Sparkline(
                    history: history,
                    color: (deltaPct ?? 0) >= 0
                        ? AppColors.primary
                        : AppColors.error,
                  ),
                ),
            ],
          ),
          if (minRate > 0 && maxRate > 0) ...[
            const SizedBox(height: AppSpacing.md),
            _RateBand(
              min: minRate,
              max: maxRate,
              avg: avgRate,
              current: model.latestRate,
            ),
          ],
          if (volumeShare > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(AppIcons.pie_chart,
                    size: 12, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  'Доля в обороте конверсий: ${volumeShare.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RateBand extends StatelessWidget {
  const _RateBand({
    required this.min,
    required this.max,
    required this.avg,
    required this.current,
  });
  final double min;
  final double max;
  final double avg;
  final double current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final range = max - min;
    final pos = range > 0 ? ((current - min) / range).clamp(0.0, 1.0) : 0.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Мин ${min.toStringAsFixed(4)}',
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              'Ср ${avg.toStringAsFixed(4)}',
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            Expanded(
              child: Text(
                'Макс ${max.toStringAsFixed(4)}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, c) {
            // Маркер 12px выше полосы 6px — даём ему выступать вверх/вниз
            // на 3px. Без clipBehavior: Clip.none Stack обрезает половину.
            return SizedBox(
              height: 12,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.error.withValues(alpha: 0.45),
                          AppColors.warning.withValues(alpha: 0.55),
                          AppColors.success.withValues(alpha: 0.55),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(100),
                    ),
                  ),
                  Positioned(
                    left: (c.maxWidth - 10) * pos,
                    child: Container(
                      width: 10,
                      height: 12,
                      decoration: BoxDecoration(
                        color: scheme.onSurface,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: scheme.surface, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Hero summary (Overview)
// ────────────────────────────────────────────────────────────────

class _HeroSummary extends StatelessWidget {
  const _HeroSummary({
    required this.healthScore,
    required this.activeBranches,
    required this.totalBranches,
    required this.totalOps,
    required this.generatedAt,
  });
  final double healthScore;
  final int activeBranches;
  final int totalBranches;
  final int totalOps;
  final String? generatedAt;

  bool get _noData => healthScore < 0;

  String _verdict() {
    if (_noData) return 'Нет данных для оценки';
    if (healthScore >= 85) return 'Сеть работает отлично';
    if (healthScore >= 70) return 'Стабильная работа';
    if (healthScore >= 50) return 'Требует внимания';
    return 'Критические показатели';
  }

  Color _scoreColor() {
    if (_noData) return AppColors.darkTextSecondary;
    if (healthScore >= 85) return AppColors.success;
    if (healthScore >= 70) return AppColors.primary;
    if (healthScore >= 50) return AppColors.warning;
    return AppColors.error;
  }

  String _genAtLabel() {
    if (generatedAt == null) return '';
    final dt = DateTime.tryParse(generatedAt!);
    if (dt == null) return '';
    return 'Обновлено ${_safeFmt(dt.toLocal(), 'd MMM, HH:mm')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final scoreColor = _scoreColor();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primarySurface,
            AppColors.secondary.withValues(alpha: 0.05),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _HealthScoreGauge(score: healthScore, color: scoreColor),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ИНДЕКС ЗДОРОВЬЯ',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _verdict(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: scoreColor,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: 6,
                  children: [
                    _MicroFact(
                      icon: AppIcons.business,
                      text:
                          'Активные $activeBranches / $totalBranches филиалов',
                    ),
                    _MicroFact(
                      icon: AppIcons.swap_horiz,
                      text: '$totalOps операций',
                    ),
                  ],
                ),
                if (generatedAt != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        AppIcons.access_time,
                        size: 11,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _genAtLabel(),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.lightTextSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MicroFact extends StatelessWidget {
  const _MicroFact({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: scheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _HealthScoreGauge extends StatelessWidget {
  const _HealthScoreGauge({required this.score, required this.color});
  final double score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final noData = score < 0;
    final pct = noData ? 0.0 : (score / 100).clamp(0.0, 1.0);
    return SizedBox(
      width: 92,
      height: 92,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: 8,
              valueColor: AlwaysStoppedAnimation(color.withValues(alpha: 0.12)),
            ),
          ),
          if (!noData)
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: pct,
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                noData ? '—' : score.toStringAsFixed(0),
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: color,
                  height: 1.0,
                ),
              ),
              Text(
                '/100',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Monthly ops chart
// ────────────────────────────────────────────────────────────────

enum _Range { m6, m12, all }

class _MonthlyOpsChart extends StatefulWidget {
  const _MonthlyOpsChart({required this.monthly});
  final Map<String, int> monthly;

  @override
  State<_MonthlyOpsChart> createState() => _MonthlyOpsChartState();
}

class _MonthlyOpsChartState extends State<_MonthlyOpsChart> {
  _Range _range = _Range.m6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sortedKeys = widget.monthly.keys.toList()..sort();
    final cut = switch (_range) {
      _Range.m6 => 6,
      _Range.m12 => 12,
      _Range.all => sortedKeys.length,
    };
    final keys = sortedKeys.length > cut
        ? sortedKeys.sublist(sortedKeys.length - cut)
        : sortedKeys;
    final values = keys.map((k) => widget.monthly[k] ?? 0).toList();
    final maxY = values.isEmpty
        ? 1.0
        : values.reduce((a, b) => a > b ? a : b).toDouble();

    final total = values.fold<int>(0, (s, v) => s + v);
    final avg = values.isEmpty ? 0.0 : total / values.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Операции по месяцам',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$total за период · ср. ${avg.toStringAsFixed(0)}/мес',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            _RangeChips(
              value: _range,
              onChanged: (r) => setState(() => _range = r),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 180,
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY <= 0 ? 1 : maxY * 1.25,
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipItem: (group, i, rod, ri) {
                    final month = _formatMonthLabel(keys[group.x.toInt()]);
                    return BarTooltipItem(
                      '$month\n${rod.toY.toInt()} опер.',
                      const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    );
                  },
                ),
              ),
              titlesData: FlTitlesData(
                leftTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= keys.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _formatMonthLabelShort(keys[i]),
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: maxY <= 0 ? 1 : (maxY / 3).ceilToDouble(),
                getDrawingHorizontalLine: (v) => FlLine(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.10),
                  strokeWidth: 0.7,
                  dashArray: const [3, 4],
                ),
              ),
              barGroups: List.generate(values.length, (i) {
                final isLast = i == values.length - 1;
                return BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: values[i].toDouble(),
                      width: 18,
                      color: isLast
                          ? AppColors.primary
                          : AppColors.primary.withValues(alpha: 0.55),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(6),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

class _RangeChips extends StatelessWidget {
  const _RangeChips({required this.value, required this.onChanged});
  final _Range value;
  final ValueChanged<_Range> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      children: [
        _chip(context, _Range.m6, '6м'),
        _chip(context, _Range.m12, '12м'),
        _chip(context, _Range.all, 'Всё'),
      ],
    );
  }

  Widget _chip(BuildContext context, _Range r, String label) {
    final selected = r == value;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onChanged(r),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.18)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.45)
                : Colors.transparent,
            width: 0.7,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: selected ? AppColors.primary : scheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Concentration card (HHI + Top-3)
// ────────────────────────────────────────────────────────────────

class _ConcentrationCard extends StatelessWidget {
  const _ConcentrationCard({required this.branches});
  final List<BranchAnalyticsModel> branches;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counts = branches.map((b) => b.confirmedTransfersCount).toList();
    final total = counts.fold<int>(0, (s, v) => s + v);
    if (total == 0) {
      return _SectionCard(
        child: Text(
          'Пока нет подтверждённых операций для оценки концентрации.',
          style: TextStyle(
            fontSize: 12.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final shares = counts.map((c) => c / total).toList()
      ..sort((a, b) => b.compareTo(a));
    final top3 = shares.take(3).fold<double>(0, (s, v) => s + v) * 100;
    final hhi = shares.fold<double>(0, (s, v) => s + v * v) * 10000;

    String hhiVerdict;
    Color hhiColor;
    if (hhi < 1500) {
      hhiVerdict = 'Низкая концентрация';
      hhiColor = AppColors.success;
    } else if (hhi < 2500) {
      hhiVerdict = 'Умеренная концентрация';
      hhiColor = AppColors.warning;
    } else {
      hhiVerdict = 'Высокая концентрация';
      hhiColor = AppColors.error;
    }

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Доля топ-3 филиалов',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.4,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${top3.toStringAsFixed(1)}%',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'HHI',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hhi.toStringAsFixed(0),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: hhiColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: hhiColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hhi < 1500
                      ? AppIcons.check_circle_outline
                      : (hhi < 2500
                          ? AppIcons.info_outline
                          : AppIcons.warning_amber),
                  size: 14,
                  color: hhiColor,
                ),
                const SizedBox(width: 5),
                Text(
                  hhiVerdict,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: hhiColor,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'HHI < 1500 — низкая · 1500-2500 — умеренная · >2500 — высокая концентрация. Измеряет, насколько объём операций сконцентрирован в немногих филиалах.',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Currency mix donut
// ────────────────────────────────────────────────────────────────

class _CurrencyMixDonut extends StatelessWidget {
  const _CurrencyMixDonut({required this.liquidity});
  final Map<String, double> liquidity;

  @override
  Widget build(BuildContext context) {
    final entries = liquidity.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (s, e) => s + e.value);
    if (total <= 0) return const SizedBox.shrink();
    final palette = AppColors.chartPalette;

    return PieChart(
      PieChartData(
        sectionsSpace: 2,
        centerSpaceRadius: 50,
        sections: List.generate(entries.length, (i) {
          final e = entries[i];
          final pct = e.value / total * 100;
          return PieChartSectionData(
            value: e.value,
            color: palette[i % palette.length],
            radius: 44,
            title: pct >= 5 ? '${pct.toStringAsFixed(0)}%' : '',
            titleStyle: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          );
        }),
      ),
    );
  }
}

class _CurrencyMixLegend extends StatelessWidget {
  const _CurrencyMixLegend({required this.liquidity});
  final Map<String, double> liquidity;

  @override
  Widget build(BuildContext context) {
    final entries = liquidity.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (s, e) => s + e.value);
    if (total <= 0) return const SizedBox.shrink();
    final palette = AppColors.chartPalette;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: List.generate(entries.length, (i) {
        final e = entries[i];
        final pct = e.value / total * 100;
        final color = palette[i % palette.length];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 48,
                child: Text(
                  e.key,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (pct / 100).clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: color.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: 110,
                child: Text(
                  '${formatNumberSpaced(e.value)} · ${pct.toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Top branches by capital
// ────────────────────────────────────────────────────────────────

class _TopBranchesByCapital extends StatelessWidget {
  const _TopBranchesByCapital({
    required this.primaryCurrency,
    required this.capitalByBranchByCurrency,
    required this.branches,
  });
  final String primaryCurrency;
  final Map<String, Map<String, double>> capitalByBranchByCurrency;
  final List<BranchAnalyticsModel> branches;

  @override
  Widget build(BuildContext context) {
    if (primaryCurrency.isEmpty) return const SizedBox.shrink();
    final nameMap = {for (final b in branches) b.branchId: b.branchName};

    final rows = <MapEntry<String, double>>[];
    capitalByBranchByCurrency.forEach((bid, byCur) {
      final v = byCur[primaryCurrency] ?? 0;
      if (v != 0) rows.add(MapEntry(nameMap[bid] ?? bid, v));
    });
    if (rows.isEmpty) return const SizedBox.shrink();

    rows.sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    final top = rows.take(5).toList();
    final maxAbs = top.map((e) => e.value.abs()).reduce(math.max);

    return _SectionCard(
      child: Column(
        children: top.asMap().entries.map((entry) {
          final i = entry.key;
          final r = entry.value;
          final pct = maxAbs > 0 ? (r.value.abs() / maxAbs) : 0.0;
          final neg = r.value < 0;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.key,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct.clamp(0.0, 1.0),
                          minHeight: 8,
                          backgroundColor: (neg
                                  ? AppColors.error
                                  : AppColors.primary)
                              .withValues(alpha: 0.10),
                          valueColor: AlwaysStoppedAnimation(
                              neg ? AppColors.error : AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 120,
                  child: Text(
                    '${formatNumberSpaced(r.value)} $primaryCurrency',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: neg ? AppColors.error : null,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Reusable widgets
// ────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  // ignore: unused_element_parameter
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
    );
  }
}

class _SubTitle extends StatelessWidget {
  const _SubTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: child,
    );
  }
}

class _GridOfKpis extends StatelessWidget {
  const _GridOfKpis({required this.items, required this.isWide});
  final List<Widget> items;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final cols = isWide ? 4 : 2;
    return LayoutBuilder(
      builder: (context, c) {
        final spacing = AppSpacing.md;
        final cardW = (c.maxWidth - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: items
              .map((w) => SizedBox(
                    width: cardW,
                    height: 120,
                    child: w,
                  ))
              .toList(),
        );
      },
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value, [this.color = AppColors.primary]);
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: scheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Status charts
// ────────────────────────────────────────────────────────────────

class _StatusPie extends StatelessWidget {
  const _StatusPie({required this.transfers});
  final TransferAnalyticsModel transfers;

  @override
  Widget build(BuildContext context) {
    final data = [
      (transfers.pendingCount, AppColors.warning, 'Создан'),
      (transfers.confirmedCount, AppColors.secondary, 'К выдаче'),
      (transfers.withCourierCount, AppColors.info, 'Курьер'),
      (transfers.issuedCount, AppColors.primary, 'Выдан'),
    ].where((e) => e.$1 > 0).toList();
    if (data.isEmpty) return const SizedBox.shrink();

    final total = data.fold<int>(0, (s, e) => s + e.$1);

    return PieChart(
      PieChartData(
        sectionsSpace: 2,
        centerSpaceRadius: 50,
        sections: data
            .map(
              (e) => PieChartSectionData(
                value: e.$1.toDouble(),
                color: e.$2,
                radius: 42,
                title: '${(e.$1 / total * 100).toStringAsFixed(0)}%',
                titleStyle: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _StatusBarChart extends StatelessWidget {
  const _StatusBarChart({required this.transfers});
  final TransferAnalyticsModel transfers;

  @override
  Widget build(BuildContext context) {
    final data = [
      (transfers.pendingCount.toDouble(), AppColors.warning, 'Создан'),
      (transfers.confirmedCount.toDouble(), AppColors.secondary, 'К выдаче'),
      (transfers.withCourierCount.toDouble(), AppColors.info, 'Курьер'),
      (transfers.issuedCount.toDouble(), AppColors.primary, 'Выдан'),
    ];
    final maxY = data.map((e) => e.$1).reduce((a, b) => a > b ? a : b);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY <= 0 ? 1 : maxY * 1.2,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, i, rod, ri) => BarTooltipItem(
              '${rod.toY.toInt()}',
              const TextStyle(color: Colors.white),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  data[value.toInt()].$3,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        barGroups: data.asMap().entries.map((entry) {
          final i = entry.key;
          final item = entry.value;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: item.$1 <= 0 ? 0.001 : item.$1,
                color: item.$2,
                width: 28,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _StatusLegend extends StatelessWidget {
  const _StatusLegend({required this.transfers});
  final TransferAnalyticsModel transfers;

  @override
  Widget build(BuildContext context) {
    final total = transfers.totalCount;
    final items = [
      ('Создано', transfers.pendingCount, AppColors.warning),
      ('К выдаче', transfers.confirmedCount, AppColors.secondary),
      ('У курьера', transfers.withCourierCount, AppColors.info),
      ('Выдано', transfers.issuedCount, AppColors.primary),
    ];
    return Column(
      children: items.map((item) {
        final pct = total > 0 ? item.$2 / total : 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  item.$1,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: item.$3.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(item.$3),
                    minHeight: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: Text(
                  '${item.$2} · ${(pct * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _StatusFunnel extends StatelessWidget {
  const _StatusFunnel({required this.transfers});
  final TransferAnalyticsModel transfers;

  @override
  Widget build(BuildContext context) {
    final created = transfers.totalCount;
    final confirmed = transfers.confirmedCount + transfers.issuedCount;
    final issued = transfers.issuedCount;

    final stages = [
      ('Создано', created, AppColors.info),
      ('Принято', confirmed, AppColors.success),
      ('Выдано', issued, Colors.teal),
    ];
    if (created == 0) {
      return const Text('Нет данных для воронки');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: stages.map((s) {
        final pct = s.$2 / created;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      s.$1,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  Text(
                    '${s.$2} · ${(pct * 100).toStringAsFixed(1)}%',
                    style: GoogleFonts.jetBrainsMono(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: s.$3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 12,
                  backgroundColor: s.$3.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation(s.$3),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Liquidity
// ────────────────────────────────────────────────────────────────

class _LiquidityGrid extends StatelessWidget {
  const _LiquidityGrid({
    required this.liquidity,
    required this.locked,
    required this.isWide,
  });
  final Map<String, double> liquidity;
  final Map<String, double> locked;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final entries = liquidity.entries.toList();
    if (entries.isEmpty) {
      return const Text('Нет данных по ликвидности');
    }
    return _GridOfKpis(
      isWide: isWide,
      items: entries.map((e) {
        final lockedAmt = locked[e.key] ?? 0;
        final free = e.value - lockedAmt;
        return KpiCard(
          label: '${e.key} · ликвидность',
          primary: formatNumberSpaced(e.value),
          secondary: 'Свободно ${formatNumberSpaced(free)}',
          icon: AppIcons.account_balance_wallet,
          iconColor: AppColors.primary,
        );
      }).toList(),
    );
  }
}

class _LiquidityBreakdown extends StatelessWidget {
  const _LiquidityBreakdown({
    required this.liquidity,
    required this.locked,
  });
  final Map<String, double> liquidity;
  final Map<String, double> locked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = liquidity.keys.toList()..sort();
    if (keys.isEmpty) {
      return const Text('Нет данных');
    }
    return Column(
      children: keys.map((cur) {
        final total = liquidity[cur] ?? 0;
        final lockedAmt = locked[cur] ?? 0;
        final pct = total > 0 ? lockedAmt / total : 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    cur,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Заблок. ${formatNumberSpaced(lockedAmt)} / ${formatNumberSpaced(total)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct.clamp(0.0, 1.0),
                  minHeight: 10,
                  backgroundColor:
                      AppColors.primary.withValues(alpha: 0.12),
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.warning),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Branch leaderboard + backlog
// ────────────────────────────────────────────────────────────────

class _BranchLeaderboard extends StatelessWidget {
  const _BranchLeaderboard({required this.branches});
  final List<BranchAnalyticsModel> branches;

  @override
  Widget build(BuildContext context) {
    final sorted = [...branches]
      ..sort((a, b) =>
          b.confirmedTransfersCount.compareTo(a.confirmedTransfersCount));
    final top = sorted.take(5).toList();
    if (top.isEmpty) return const SizedBox.shrink();
    final maxCount = top.first.confirmedTransfersCount.toDouble().clamp(1, double.infinity);

    return _SectionCard(
      child: Column(
        children: top.asMap().entries.map((entry) {
          final i = entry.key;
          final b = entry.value;
          final pct = b.confirmedTransfersCount / maxCount;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.branchName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct.toDouble(),
                          minHeight: 8,
                          backgroundColor:
                              AppColors.primary.withValues(alpha: 0.10),
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 60,
                  child: Text(
                    '${b.confirmedTransfersCount}',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _PendingBacklogStrip extends StatelessWidget {
  const _PendingBacklogStrip({required this.branches});
  final List<BranchAnalyticsModel> branches;

  @override
  Widget build(BuildContext context) {
    final withBacklog = branches.where((b) => b.pendingTransfersCount > 0).toList()
      ..sort((a, b) =>
          b.pendingTransfersCount.compareTo(a.pendingTransfersCount));
    if (withBacklog.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.30),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(AppIcons.warning_amber,
                  size: 18, color: AppColors.warning),
              const SizedBox(width: 6),
              Text(
                'Ожидающие переводы в филиалах',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.warning,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: withBacklog.map((b) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  '${b.branchName} · ${b.pendingTransfersCount}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Tables
// ────────────────────────────────────────────────────────────────

class _CapitalByBranchTable extends StatelessWidget {
  const _CapitalByBranchTable({
    required this.capitalByBranchByCurrency,
    required this.branches,
  });
  final Map<String, Map<String, double>> capitalByBranchByCurrency;
  final List<BranchAnalyticsModel> branches;

  @override
  Widget build(BuildContext context) {
    final nameMap = {for (final b in branches) b.branchId: b.branchName};
    final cap = <String, Map<String, double>>{};
    capitalByBranchByCurrency.forEach((k, v) {
      cap[k] = Map<String, double>.from(v);
    });
    for (final b in branches) {
      final cur = cap[b.branchId];
      if ((cur == null || cur.isEmpty) && b.balancesByCurrency.isNotEmpty) {
        cap[b.branchId] = Map<String, double>.from(b.balancesByCurrency);
      }
    }
    final bids = cap.keys.toList()
      ..sort((a, b) => (nameMap[a] ?? a)
          .toLowerCase()
          .compareTo((nameMap[b] ?? b).toLowerCase()));

    return _SectionCard(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 24,
          columns: const [
            DataColumn(label: Text('Филиал')),
            DataColumn(label: Text('Балансы по валютам')),
          ],
          rows: bids.map((bid) {
            final byCur = Map<String, double>.from(cap[bid] ?? const {});
            return DataRow(cells: [
              DataCell(Text(nameMap[bid] ?? bid)),
              DataCell(Text(
                CurrencyUtils.formatBalanceBreakdown(byCur),
                style: GoogleFonts.jetBrainsMono(fontSize: 12),
              )),
            ]);
          }).toList(),
        ),
      ),
    );
  }
}

class _LargeTransfersList extends StatelessWidget {
  const _LargeTransfersList({required this.transfers});
  final List<Map<String, dynamic>> transfers;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        children: transfers.take(10).map((t) {
          final amount = (t['amount'] as num?)?.toDouble() ?? 0;
          final cur = t['currency'] as String? ?? '';
          final from = t['from'] as String? ?? '';
          final to = t['to'] as String? ?? '';
          final dt = _parseDate(t['date'] as String?);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(AppIcons.swap_horiz,
                      size: 16, color: AppColors.primary),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$from → $to',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (dt != null)
                        Text(
                          _safeFmt(dt, 'd MMM, HH:mm'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
                Text(
                  '${formatNumberSpaced(amount)} $cur',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _MonthlyTable extends StatelessWidget {
  const _MonthlyTable({required this.monthly});
  final Map<String, dynamic> monthly;

  @override
  Widget build(BuildContext context) {
    final sorted = monthly.entries.toList()
      ..sort((a, c) => a.key.compareTo(c.key));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 32,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        columns: const [
          DataColumn(label: Text('Месяц')),
          DataColumn(label: Text('Вал.')),
          DataColumn(label: Text('Дебет'), numeric: true),
          DataColumn(label: Text('Кредит'), numeric: true),
          DataColumn(label: Text('Опер.'), numeric: true),
        ],
        rows: sorted.map((e) {
          final m = Map<String, dynamic>.from(e.value as Map);
          final mc = _splitMonthCurrencyKey(e.key);
          return DataRow(cells: [
            DataCell(Text(mc.$1)),
            DataCell(Text(mc.$2)),
            DataCell(Text(formatNumberSpaced(m['debit'] ?? 0),
                style: GoogleFonts.jetBrainsMono(fontSize: 12))),
            DataCell(Text(formatNumberSpaced(m['credit'] ?? 0),
                style: GoogleFonts.jetBrainsMono(fontSize: 12))),
            DataCell(Text('${m['count'] ?? 0}',
                style: GoogleFonts.jetBrainsMono(fontSize: 12))),
          ]);
        }).toList(),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Sparkline
// ────────────────────────────────────────────────────────────────

class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.history, required this.color});
  final List<Map<String, dynamic>> history;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final rev = history.reversed.toList();
    final spots = rev
        .asMap()
        .entries
        .map((e) => FlSpot(
              e.key.toDouble(),
              ((e.value['rate'] as num?)?.toDouble() ?? 0),
            ))
        .toList();
    if (spots.length < 2) return const SizedBox.shrink();

    final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY) * 0.15;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 2,
            color: color,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────

double _primaryLiquidity(TreasuryOverviewModel? t) {
  if (t == null || t.totalLiquidity.isEmpty) return 0;
  final sorted = t.totalLiquidity.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.first.value;
}

String _primaryLiquidityCurrency(TreasuryOverviewModel? t) {
  if (t == null || t.totalLiquidity.isEmpty) return '';
  final sorted = t.totalLiquidity.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.first.key;
}

double _primaryLocked(TreasuryOverviewModel? t) {
  if (t == null || t.pendingLockedByCurrency.isEmpty) return 0;
  final cur = _primaryLiquidityCurrency(t);
  return t.pendingLockedByCurrency[cur] ?? 0;
}

String? _multiCurrencySubtitle(Map<String, double> liquidity) {
  if (liquidity.length <= 1) return null;
  final sorted = liquidity.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final rest = sorted.skip(1).take(3).map(
        (e) => '${formatNumberSpaced(e.value)} ${e.key}',
      );
  return '+ ${rest.join(' · ')}';
}

double _avgSize(TransferAnalyticsModel t) {
  if (t.totalCount == 0) return 0;
  if (t.volumeByCurrency.isNotEmpty) {
    final sum = t.volumeByCurrency.values.reduce((a, b) => a + b);
    return sum / t.totalCount;
  }
  return t.totalVolume / t.totalCount;
}

String _pairFlag(String pair) {
  final parts = pair.split('/');
  if (parts.length == 2) {
    return '${CurrencyUtils.flag(parts[0])} ${CurrencyUtils.flag(parts[1])}';
  }
  final parts2 = pair.split('-');
  if (parts2.length == 2) {
    return '${CurrencyUtils.flag(parts2[0])} ${CurrencyUtils.flag(parts2[1])}';
  }
  return '🏳️';
}

DateTime? _parseDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso);
}

(String, String) _splitMonthCurrencyKey(String raw) {
  final i = raw.indexOf('|');
  if (i <= 0) return (raw, '—');
  return (raw.substring(0, i), raw.substring(i + 1));
}

Map<String, int> _aggregateMonthlyCounts(List<BranchAnalyticsModel> branches) {
  final out = <String, int>{};
  for (final b in branches) {
    for (final entry in b.monthlySummary.entries) {
      final mc = _splitMonthCurrencyKey(entry.key);
      final month = mc.$1;
      final raw = entry.value;
      if (raw is! Map) continue;
      final count = (raw['count'] as num?)?.toInt() ?? 0;
      if (count == 0) continue;
      out.update(month, (v) => v + count, ifAbsent: () => count);
    }
  }
  return out;
}

/// Composite health score in 0..100.
///
/// Возвращает `-1`, когда оценивать нечего (нет филиалов и переводов одновременно)
/// — UI рисует «Нет данных» вместо ложного «Отлично».
double _computeHealthScore({
  required TreasuryOverviewModel? treasury,
  required TransferAnalyticsModel? transfers,
  required List<BranchAnalyticsModel> branches,
}) {
  final hasTransfers = transfers != null && transfers.totalCount > 0;
  final hasBranches = branches.isNotEmpty;
  final hasTreasury = treasury != null && treasury.totalLiquidity.isNotEmpty;
  if (!hasTransfers && !hasBranches && !hasTreasury) return -1;

  // success / rejection / backlog — оцениваем только если есть переводы.
  double success = 0.5;
  double rejectionHealth = 0.5;
  double backlogHealth = 0.5;
  if (hasTransfers) {
    success = (transfers.confirmedCount + transfers.issuedCount) /
        transfers.totalCount;
    // Reject/cancel удалены; "rejection rate" больше неприменим.
    rejectionHealth = 1.0;
    backlogHealth =
        (1 - transfers.pendingCount / transfers.totalCount).clamp(0.0, 1.0);
  }

  // Locked share — оцениваем только если есть ликвидность.
  double lockedHealth = 0.5;
  final liq = _primaryLiquidity(treasury);
  final locked = _primaryLocked(treasury);
  if (liq > 0) {
    lockedHealth = (1 - (locked / liq)).clamp(0.0, 1.0);
  }

  // Speed — оцениваем только если переводы реально обрабатываются.
  double speedHealth = 0.5;
  if (transfers != null && transfers.avgProcessingMs > 0) {
    final mins = transfers.avgProcessingMs / 60000;
    speedHealth = (1 - (mins / 60)).clamp(0.0, 1.0);
  } else if (hasTransfers) {
    // переводы есть, но обработка мгновенная → полный балл за скорость
    speedHealth = 1;
  }

  final composite = 0.35 * success +
      0.20 * rejectionHealth +
      0.15 * lockedHealth +
      0.15 * backlogHealth +
      0.15 * speedHealth;
  return (composite * 100).clamp(0.0, 100.0);
}

String _formatMonthLabel(String yyyymm) {
  final parts = yyyymm.split('-');
  if (parts.length != 2) return yyyymm;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (y == null || m == null) return yyyymm;
  return _safeFmt(DateTime(y, m), 'LLLL yyyy');
}

String _formatMonthLabelShort(String yyyymm) {
  final parts = yyyymm.split('-');
  if (parts.length != 2) return yyyymm;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (y == null || m == null) return yyyymm;
  // Numeric fallback на месяцы (1..12) — короче и не зависит от локали.
  final ruMonths = [
    'янв','фев','мар','апр','май','июн',
    'июл','авг','сен','окт','ноя','дек',
  ];
  try {
    return DateFormat('LLL', 'ru').format(DateTime(y, m));
  } catch (_) {
    return (m >= 1 && m <= 12) ? ruMonths[m - 1] : yyyymm;
  }
}

/// Безопасно отформатировать дату в русской локали.
/// Если `initializeDateFormatting('ru')` не был вызван (или упал) —
/// падаем на дефолтный (en_US) формат вместо LocaleDataException.
String _safeFmt(DateTime dt, String pattern) {
  try {
    return DateFormat(pattern, 'ru').format(dt);
  } catch (_) {
    try {
      return DateFormat(pattern).format(dt);
    } catch (_) {
      return dt.toIso8601String();
    }
  }
}

String _plural(int n, List<String> forms) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return forms[0];
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return forms[1];
  return forms[2];
}

// ════════════════════════════════════════════════════════════════════
// Tab 6: Партнёры
// ════════════════════════════════════════════════════════════════════

/// Полноценная вкладка «Партнёры» в аналитике — крупный обзор с KPI,
/// топом, разбивкой прибыли по партнёрам и списком всех с saldo.
/// Тянет данные через RPC миграции 034/036:
///   • counterparties_list       (миграция 034)
///   • partner_profit_top_partners (миграция 036)
///   • transfer_profit_summary   (миграция 036)
class _PartnersTab extends StatefulWidget {
  const _PartnersTab();
  @override
  State<_PartnersTab> createState() => _PartnersTabState();
}

class _PartnersTabState extends State<_PartnersTab> {
  _PartnerPeriod _period = _PartnerPeriod.month;
  List<Map<String, dynamic>> _topPartners = const [];
  List<Map<String, dynamic>> _allPartners = const [];
  List<Map<String, dynamic>> _profitByCurrency = const [];
  List<Map<String, dynamic>> _monthlyProfit = const [];
  bool _loading = true;
  bool _unavailable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _unavailable = false;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final start = _period.startDate?.toUtc().toIso8601String();
      // Бухгалтер видит только свой филиал во всех RPC.
      final user = context.read<AuthBloc>().state.user;
      final branchScope = _branchScopeFor(user);

      final topParams = <String, dynamic>{'p_limit': 10};
      if (start != null) topParams['p_start'] = start;
      if (branchScope != null) topParams['p_branch_id'] = branchScope;

      final profitParams = <String, dynamic>{'p_partner_only': true};
      if (start != null) profitParams['p_start'] = start;
      if (branchScope != null) profitParams['p_branch_id'] = branchScope;

      // Monthly chart всегда тянем за последние 12 месяцев — period
      // влияет только на «топ»-блоки.
      final monthlyStart = DateTime.now()
          .subtract(const Duration(days: 365))
          .toUtc()
          .toIso8601String();
      final monthlyParams = <String, dynamic>{
        'p_start': monthlyStart,
        'p_partner_only': true,
      };
      if (branchScope != null) monthlyParams['p_branch_id'] = branchScope;

      final results = await Future.wait<dynamic>([
        client
            .rpc('partner_profit_top_partners', params: topParams)
            .timeout(const Duration(seconds: 15)),
        client.rpc('counterparties_list',
            params: {'p_include_archived': false}).timeout(
            const Duration(seconds: 15)),
        client
            .rpc('transfer_profit_summary', params: profitParams)
            .timeout(const Duration(seconds: 15)),
        // 4-й запрос — monthly. Если миграция 037 не применена — словим
        // PGRST и весь tab покажет MigrationNeededView. Это OK, потому
        // что аналитика партнёров без 037 неполная.
        client
            .rpc('partner_profit_monthly', params: monthlyParams)
            .timeout(const Duration(seconds: 15))
            .catchError((_) => <dynamic>[]),
      ]);

      if (!mounted) return;
      setState(() {
        _topPartners = (results[0] as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList();
        _allPartners = (results[1] as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList();
        _profitByCurrency = (results[2] as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList();
        _monthlyProfit = (results[3] as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _loading = false;
        _unavailable = s.contains('PGRST') ||
            s.contains('42883') ||
            s.contains('does not exist');
        if (!_unavailable) _error = s;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unavailable) {
      return _MigrationNeededView(onRetry: _loadAll);
    }
    if (_error != null) {
      return _ErrorView(message: _error!);
    }

    // ── KPI расчёты ─────────────────────────────────────
    final totalPartners = _allPartners.length;
    final activePartners = _allPartners
        .where((p) =>
            ((p['tx_count'] as num?)?.toInt() ?? 0) > 0)
        .length;
    final totalSpread = _profitByCurrency.fold<double>(
        0,
        (s, r) =>
            s + ((r['spread_profit'] as num?)?.toDouble() ?? 0));
    final totalCommission = _profitByCurrency.fold<double>(
        0,
        (s, r) =>
            s + ((r['commission_profit'] as num?)?.toDouble() ?? 0));
    final totalTransfers = _profitByCurrency.fold<int>(
        0,
        (s, r) =>
            s + ((r['transfer_count'] as num?)?.toInt() ?? 0));

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header + переключатель периода.
          Row(
            children: [
              Expanded(
                child: Text(
                  'Аналитика партнёров',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              _PartnerPeriodChips(
                value: _period,
                onChanged: (p) {
                  setState(() => _period = p);
                  _loadAll();
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // KPI grid.
          _GridOfKpis(
            isWide: MediaQuery.sizeOf(context).width >= 900,
            items: [
              KpiCard(
                hero: true,
                label: 'Всего партнёров',
                primary: '$totalPartners',
                secondary: '$activePartners активных',
                icon: AppIcons.account_tree,
                iconColor: AppColors.primary,
              ),
              KpiCard(
                label: 'Переводов через партнёров',
                primary: '$totalTransfers',
                secondary: 'За «${_period.label}»',
                icon: AppIcons.swap_horiz,
                iconColor: AppColors.secondary,
              ),
              KpiCard(
                label: 'Прибыль с курса (spread)',
                primary: formatNumberSpaced(totalSpread),
                secondary: 'По всем валютам',
                icon: AppIcons.currency_exchange,
                iconColor: Colors.green.shade600,
              ),
              KpiCard(
                label: 'Прибыль с комиссии',
                primary: formatNumberSpaced(totalCommission),
                secondary: 'По всем валютам',
                icon: AppIcons.percent,
                iconColor: AppColors.success,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),

          // Динамика прибыли по месяцам.
          if (_monthlyProfit.isNotEmpty) ...[
            _SectionTitle('Динамика прибыли за 12 месяцев'),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(
              child: _PartnerProfitMonthlyChart(rows: _monthlyProfit),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Топ партнёров.
          _SectionTitle('Топ-10 партнёров по объёму'),
          const SizedBox(height: AppSpacing.md),
          if (_topPartners.isEmpty)
            _SectionCard(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  'За «${_period.label}» партнёрских переводов не было.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            _SectionCard(
              child: Column(
                children: [
                  for (final r in _topPartners) _TopPartnerRow(row: r),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.xl),

          // Прибыль по валютам.
          if (_profitByCurrency.isNotEmpty) ...[
            _SectionTitle('Прибыль по валютам'),
            const SizedBox(height: AppSpacing.md),
            _SectionCard(
              child: _ProfitByCurrencyTable(rows: _profitByCurrency),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // Список всех партнёров с saldo.
          _SectionTitle('Все партнёры с открытым сальдо'),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            child: _AllPartnersWithSaldoList(partners: _allPartners),
          ),
        ],
      ),
    );
  }
}

/// Периоды для аналитики партнёров. Дублирует _ProfitPeriod из
/// counterparties_page.dart — но они приватные, не переиспользуются
/// между файлами.
enum _PartnerPeriod {
  week('Неделя'),
  month('Месяц'),
  quarter('Квартал'),
  year('Год'),
  all('Всё');
  const _PartnerPeriod(this.label);
  final String label;

  DateTime? get startDate {
    final now = DateTime.now();
    switch (this) {
      case _PartnerPeriod.week:
        return now.subtract(const Duration(days: 7));
      case _PartnerPeriod.month:
        return DateTime(now.year, now.month - 1, now.day);
      case _PartnerPeriod.quarter:
        return DateTime(now.year, now.month - 3, now.day);
      case _PartnerPeriod.year:
        return DateTime(now.year - 1, now.month, now.day);
      case _PartnerPeriod.all:
        return null;
    }
  }
}

class _PartnerPeriodChips extends StatelessWidget {
  const _PartnerPeriodChips({required this.value, required this.onChanged});
  final _PartnerPeriod value;
  final ValueChanged<_PartnerPeriod> onChanged;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      children: _PartnerPeriod.values.map((p) {
        final selected = p == value;
        return ChoiceChip(
          selected: selected,
          onSelected: (_) => onChanged(p),
          label: Text(p.label),
          labelStyle: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          selectedColor: scheme.primary,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
      }).toList(),
    );
  }
}

class _MigrationNeededView extends StatelessWidget {
  const _MigrationNeededView({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.warning_amber,
                  size: 48, color: AppColors.warning),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Аналитика партнёров недоступна',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Раздел требует миграций 034 и 036. Запусти '
                '«supabase db push» или загрузи SQL-файлы в Supabase Dashboard.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(AppIcons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stacked bar chart: каждая колонка — месяц, две части — spread profit
/// (зелёный) и commission profit (primary). Если несколько валют —
/// показываем dropdown сверху для фильтра. Берём по умолчанию валюту
/// с максимальным total volume.
class _PartnerProfitMonthlyChart extends StatefulWidget {
  const _PartnerProfitMonthlyChart({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  State<_PartnerProfitMonthlyChart> createState() =>
      _PartnerProfitMonthlyChartState();
}

class _PartnerProfitMonthlyChartState
    extends State<_PartnerProfitMonthlyChart> {
  String? _selectedCurrency;

  /// Уникальные валюты, отсортированные по total volume desc.
  List<String> get _availableCurrencies {
    final volumeByCurrency = <String, double>{};
    for (final r in widget.rows) {
      final cur = (r['currency'] ?? '').toString();
      if (cur.isEmpty) continue;
      volumeByCurrency[cur] = (volumeByCurrency[cur] ?? 0) +
          ((r['total_volume'] as num?)?.toDouble() ?? 0);
    }
    final list = volumeByCurrency.keys.toList()
      ..sort((a, b) =>
          (volumeByCurrency[b] ?? 0).compareTo(volumeByCurrency[a] ?? 0));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currencies = _availableCurrencies;
    if (currencies.isEmpty) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            'Партнёрских переводов за 12 месяцев нет',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final selectedCurrency = _selectedCurrency ?? currencies.first;
    // Фильтруем по выбранной валюте + сортируем по месяцу.
    final filtered = widget.rows
        .where((r) => (r['currency'] ?? '').toString() == selectedCurrency)
        .toList()
      ..sort((a, b) =>
          (a['month_start']?.toString() ?? '')
              .compareTo(b['month_start']?.toString() ?? ''));
    // Если данных мало — fill пустыми месяцами.
    final months = _last12Months();
    final byMonth = <String, _MonthBucket>{};
    for (final r in filtered) {
      final dt = DateTime.tryParse(r['month_start']?.toString() ?? '');
      if (dt == null) continue;
      final key = _monthKey(dt);
      byMonth[key] = _MonthBucket(
        spread: (r['spread_profit'] as num?)?.toDouble() ?? 0,
        commission: (r['commission_profit'] as num?)?.toDouble() ?? 0,
        count: (r['transfer_count'] as num?)?.toInt() ?? 0,
      );
    }
    final maxY = months
        .map((m) =>
            (byMonth[m]?.spread ?? 0) + (byMonth[m]?.commission ?? 0))
        .fold<double>(0, (a, b) => a > b ? a : b);

    final totalSpread = filtered.fold<double>(
        0, (s, r) => s + ((r['spread_profit'] as num?)?.toDouble() ?? 0));
    final totalCommission = filtered.fold<double>(
        0, (s, r) => s + ((r['commission_profit'] as num?)?.toDouble() ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header с легендой + currency picker.
        Row(
          children: [
            _LegendDot(color: Colors.green.shade600, label: 'Spread'),
            const SizedBox(width: AppSpacing.sm),
            _LegendDot(color: scheme.primary, label: 'Комиссия'),
            const Spacer(),
            if (currencies.length > 1)
              DropdownButton<String>(
                value: selectedCurrency,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: currencies
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(CurrencyUtils.flag(c)),
                              const SizedBox(width: 4),
                              Text(c,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  )),
                            ],
                          ),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedCurrency = v),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(CurrencyUtils.flag(selectedCurrency)),
                    const SizedBox(width: 4),
                    Text(selectedCurrency,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        )),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        // Totals под чартом.
        Row(
          children: [
            Text(
              'Spread: ${formatNumberSpaced(totalSpread)} $selectedCurrency',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.green.shade700,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              'Комиссия: ${formatNumberSpaced(totalCommission)} $selectedCurrency',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            const Spacer(),
            Text(
              'Итого: ${formatNumberSpaced(totalSpread + totalCommission)} $selectedCurrency',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Colors.green.shade800,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // The chart.
        SizedBox(
          height: 220,
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY <= 0 ? 1 : maxY * 1.2,
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipItem: (group, i, rod, ri) {
                    final m = months[group.x.toInt()];
                    final b = byMonth[m] ?? _MonthBucket.zero();
                    return BarTooltipItem(
                      '$m\n'
                      'Spread: ${formatNumberSpaced(b.spread)}\n'
                      'Комиссия: ${formatNumberSpaced(b.commission)}\n'
                      'Переводов: ${b.count}',
                      const TextStyle(color: Colors.white, fontSize: 11),
                    );
                  },
                ),
              ),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 50,
                    getTitlesWidget: (value, meta) {
                      if (value == 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          _compactNumber(value),
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= months.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          months[i].substring(5),
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: maxY <= 0 ? 1 : maxY / 4,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: scheme.outline.withValues(alpha: 0.12),
                  strokeWidth: 1,
                ),
              ),
              barGroups: months.asMap().entries.map((entry) {
                final i = entry.key;
                final m = entry.value;
                final b = byMonth[m] ?? _MonthBucket.zero();
                return BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: b.spread + b.commission,
                      width: 14,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                      rodStackItems: [
                        BarChartRodStackItem(
                            0, b.spread, Colors.green.shade600),
                        BarChartRodStackItem(b.spread,
                            b.spread + b.commission, scheme.primary),
                      ],
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  List<String> _last12Months() {
    final now = DateTime.now();
    return List.generate(12, (i) {
      final dt = DateTime(now.year, now.month - 11 + i, 1);
      return _monthKey(dt);
    });
  }

  String _monthKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}';

  /// Сокращённый формат числа: 1500 → 1.5k, 12500000 → 12.5M.
  String _compactNumber(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }
}

class _MonthBucket {
  _MonthBucket(
      {required this.spread, required this.commission, required this.count});
  factory _MonthBucket.zero() => _MonthBucket(spread: 0, commission: 0, count: 0);
  final double spread;
  final double commission;
  final int count;
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _ProfitByCurrencyTable extends StatelessWidget {
  const _ProfitByCurrencyTable({required this.rows});
  final List<Map<String, dynamic>> rows;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Группируем по валюте (rows = per branch+currency, схлопываем).
    final byCurrency = <String, _CurrencyAgg>{};
    for (final r in rows) {
      final cur = (r['currency'] ?? '').toString();
      final agg = byCurrency.putIfAbsent(cur, () => _CurrencyAgg());
      agg.transferCount += (r['transfer_count'] as num?)?.toInt() ?? 0;
      agg.volume += (r['total_volume'] as num?)?.toDouble() ?? 0;
      agg.spread += (r['spread_profit'] as num?)?.toDouble() ?? 0;
      agg.commission += (r['commission_profit'] as num?)?.toDouble() ?? 0;
    }
    final sorted = byCurrency.entries.toList()
      ..sort((a, b) => b.value.volume.compareTo(a.value.volume));

    Widget header(String text, {TextAlign align = TextAlign.start}) => Text(
          text.toUpperCase(),
          textAlign: align,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: scheme.onSurfaceVariant,
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 70, child: header('Валюта')),
              Expanded(flex: 2, child: header('Объём', align: TextAlign.end)),
              Expanded(flex: 2, child: header('Spread', align: TextAlign.end)),
              Expanded(
                  flex: 2,
                  child: header('Комиссия', align: TextAlign.end)),
              Expanded(flex: 2, child: header('Всего', align: TextAlign.end)),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outline.withValues(alpha: 0.15)),
        for (final e in sorted)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 70,
                  child: Row(
                    children: [
                      Text(CurrencyUtils.flag(e.key),
                          style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 4),
                      Text(
                        e.key,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    formatNumberSpaced(e.value.volume),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    formatNumberSpaced(e.value.spread),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: e.value.spread > 0
                          ? Colors.green.shade700
                          : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    formatNumberSpaced(e.value.commission),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: e.value.commission > 0
                          ? Colors.green.shade700
                          : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    formatNumberSpaced(e.value.totalProfit),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: e.value.totalProfit > 0
                          ? Colors.green.shade800
                          : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CurrencyAgg {
  int transferCount = 0;
  double volume = 0;
  double spread = 0;
  double commission = 0;
  double get totalProfit => spread + commission;
}

class _AllPartnersWithSaldoList extends StatelessWidget {
  const _AllPartnersWithSaldoList({required this.partners});
  final List<Map<String, dynamic>> partners;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Отбрасываем партнёров без открытого сальдо — здесь нас интересуют
    // только те, с кем есть незавершённые расчёты.
    final withSaldo = <Map<String, dynamic>>[];
    for (final p in partners) {
      final saldoRaw = p['saldo_by_currency'];
      if (saldoRaw is Map) {
        final hasOpen = saldoRaw.values.any((v) {
          final d = v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0;
          return d.abs() > 0.005;
        });
        if (hasOpen) withSaldo.add(p);
      }
    }
    if (withSaldo.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          'Все расчёты с партнёрами закрыты.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      children: [
        for (final p in withSaldo)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor:
                      scheme.primary.withValues(alpha: 0.15),
                  child: Text(
                    (p['name'] ?? '?').toString().characters.first.toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        (p['name'] ?? '—').toString(),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if ((p['city'] as String?)?.isNotEmpty == true)
                        Text(
                          p['city'].toString(),
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                _SaldoChipsRow(saldo: p['saldo_by_currency']),
              ],
            ),
          ),
      ],
    );
  }
}

class _SaldoChipsRow extends StatelessWidget {
  const _SaldoChipsRow({required this.saldo});
  final dynamic saldo;
  @override
  Widget build(BuildContext context) {
    if (saldo is! Map) return const SizedBox.shrink();
    final entries = <MapEntry<String, double>>[];
    saldo.forEach((k, v) {
      final d = v is num
          ? v.toDouble()
          : double.tryParse(v.toString()) ?? 0;
      if (d.abs() > 0.005) entries.add(MapEntry(k.toString(), d));
    });
    entries.sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: entries.take(3).map((e) {
        final positive = e.value > 0;
        final color = positive ? Colors.green.shade600 : Colors.red.shade600;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${positive ? '+' : ''}${formatNumberSpaced(e.value)} ${e.key}',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      }).toList(),
    );
  }
}

