import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/balance_utils.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/presentation/analytics/bloc/analytics_bloc.dart';

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
    _tabController = TabController(length: 4, vsync: this);
    context.read<AnalyticsBloc>().add(const AnalyticsLoadRequested());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Аналитика'),
        actions: [
          BlocBuilder<AnalyticsBloc, AnalyticsBlocState>(
            buildWhen: (a, b) => a.excludeCounterpartyAccounts != b.excludeCounterpartyAccounts,
            builder: (context, state) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
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
                        AnalyticsLoadRequested(excludeCounterpartyAccounts: v),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: () => context.read<AnalyticsBloc>().add(
              AnalyticsLoadRequested(
                excludeCounterpartyAccounts:
                    context.read<AnalyticsBloc>().state.excludeCounterpartyAccounts,
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: context.isDesktop,
          tabs: const [
            Tab(text: 'Казначейство', icon: Icon(Icons.account_balance)),
            Tab(text: 'Филиалы', icon: Icon(Icons.business)),
            Tab(text: 'Переводы', icon: Icon(Icons.swap_horiz)),
            Tab(text: 'Валюты', icon: Icon(Icons.currency_exchange)),
          ],
        ),
      ),
      body: BlocBuilder<AnalyticsBloc, AnalyticsBlocState>(
        builder: (context, state) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.errorMessage != null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: AppSpacing.md),
                  Text(state.errorMessage!),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: () => context
                        .read<AnalyticsBloc>()
                        .add(const AnalyticsLoadRequested()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить'),
                  ),
                ],
              ),
            );
          }

          return TabBarView(
            controller: _tabController,
            children: [
              _TreasuryTab(treasury: state.treasury, branches: state.branches),
              _BranchesTab(branches: state.branches),
              _TransfersTab(transfers: state.transfers),
              _CurrencyTab(currencies: state.currencies),
            ],
          );
        },
      ),
    );
  }
}

// ─── Treasury Tab ───

class _TreasuryTab extends StatelessWidget {
  final TreasuryOverviewModel? treasury;
  final List<BranchAnalyticsModel> branches;
  const _TreasuryTab({required this.treasury, required this.branches});

  @override
  Widget build(BuildContext context) {
    if (treasury == null) {
      return const Center(child: Text('Нет данных'));
    }
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Общая ликвидность', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: treasury!.totalLiquidity.entries.map((e) {
              return _KpiCard(
                label: '${e.key} · ликвидность',
                value: formatNumberSpaced(e.value),
                icon: Icons.account_balance_wallet,
                color: theme.colorScheme.primary,
              );
            }).toList(),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Заблокировано (ожидающие)', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (treasury!.pendingLockedByCurrency.isEmpty)
            Text(
              'Нет заблокированных средств по ожидающим переводам',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: treasury!.pendingLockedByCurrency.entries.map((e) {
                return _KpiCard(
                  label: e.key == '\u2014' ? 'Заблокировано' : 'Заблокировано (${e.key})',
                  value: formatNumberSpaced(e.value),
                  icon: Icons.lock_clock,
                  color: Colors.orange,
                );
              }).toList(),
            ),
          const SizedBox(height: AppSpacing.xl),
          Text('Капитал по филиалам (по валютам)', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Балансы по валютам — сложение разных валют не производится',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _CapitalByBranchTable(
            capitalByBranchByCurrency: treasury!.capitalByBranchByCurrency,
            branches: branches,
          ),
          if (treasury!.largeTransfers.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            Text('Крупные переводы (30 дней)', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            _LargeTransfersTable(transfers: treasury!.largeTransfers),
          ],
        ],
      ),
    );
  }
}

class _CapitalByBranchTable extends StatelessWidget {
  final Map<String, Map<String, double>> capitalByBranchByCurrency;
  final List<BranchAnalyticsModel> branches;

  const _CapitalByBranchTable({
    required this.capitalByBranchByCurrency,
    required this.branches,
  });

  @override
  Widget build(BuildContext context) {
    final nameMap = {
      for (final b in branches) b.branchId: b.branchName,
    };
    final cap = <String, Map<String, double>>{};
    for (final e in capitalByBranchByCurrency.entries) {
      cap[e.key] = Map<String, double>.from(e.value);
    }
    for (final b in branches) {
      final cur = cap[b.branchId];
      if (cur == null || cur.isEmpty) {
        if (b.balancesByCurrency.isNotEmpty) {
          cap[b.branchId] = Map<String, double>.from(b.balancesByCurrency);
        }
      }
    }
    final bids = cap.keys.toList()
      ..sort((a, b) =>
          (nameMap[a] ?? a).toLowerCase().compareTo((nameMap[b] ?? b).toLowerCase()));

    return DataTable(
      columns: const [
        DataColumn(label: Text('Филиал')),
        DataColumn(label: Text('Баланс по валютам')),
      ],
      rows: bids.map((bid) {
        final byCur = Map<String, double>.from(cap[bid] ?? const {});
        return DataRow(cells: [
          DataCell(Text(nameMap[bid] ?? bid)),
          DataCell(Text(
            CurrencyUtils.formatBalanceBreakdown(byCur),
          )),
        ]);
      }).toList(),
    );
  }
}

class _LargeTransfersTable extends StatelessWidget {
  final List<Map<String, dynamic>> transfers;

  const _LargeTransfersTable({required this.transfers});

  @override
  Widget build(BuildContext context) {
    return DataTable(
      columns: const [
        DataColumn(label: Text('ID')),
        DataColumn(label: Text('Сумма'), numeric: true),
        DataColumn(label: Text('Валюта')),
        DataColumn(label: Text('Откуда')),
        DataColumn(label: Text('Куда')),
        DataColumn(label: Text('Дата')),
      ],
      rows: transfers.map((t) {
        return DataRow(cells: [
          DataCell(Text((t['id'] as String?)?.substring(0, 8) ?? '')),
          DataCell(Text(formatNumberSpaced(t['amount'] ?? 0))),
          DataCell(Text(t['currency'] as String? ?? '')),
          DataCell(Text(t['from'] ?? '')),
          DataCell(Text(t['to'] ?? '')),
          DataCell(Text(_formatDate(t['date'] as String?))),
        ]);
      }).toList(),
    );
  }
}

// ─── Branches Tab ───

class _BranchesTab extends StatelessWidget {
  final List<BranchAnalyticsModel> branches;
  const _BranchesTab({required this.branches});

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) return const Center(child: Text('Нет данных'));

    final theme = Theme.of(context);

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: branches.length,
      itemBuilder: (context, index) {
        final b = branches[index];
        return Card(
          margin: const EdgeInsets.only(bottom: AppSpacing.md),
          child: ExpansionTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                b.branchName.isNotEmpty ? b.branchName[0] : '?',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
            title: Text(b.branchName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              'Баланс: ${CurrencyUtils.formatBalanceBreakdown(
                b.balancesByCurrency.isNotEmpty
                    ? b.balancesByCurrency
                    : balanceByCurrencyFromAccounts(b.accounts),
              )}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (b.pendingTransfersCount > 0)
                  Chip(
                    label: Text('${b.pendingTransfersCount} ожид.'),
                    backgroundColor: Colors.orange.shade100,
                    labelStyle: TextStyle(color: Colors.orange.shade800, fontSize: 12),
                  ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  CurrencyUtils.formatBalanceBreakdown(
                    b.balancesByCurrency.isNotEmpty
                        ? b.balancesByCurrency
                        : balanceByCurrencyFromAccounts(b.accounts),
                  ),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  )),
              ],
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _MiniStat('Подтверждено', '${b.confirmedTransfersCount}'),
                        const SizedBox(width: AppSpacing.lg),
                        _MiniStat('В ожидании', '${b.pendingTransfersCount}'),
                        const SizedBox(width: AppSpacing.lg),
                        _MiniStat('Комиссии (сумма)', formatNumberSpaced(b.totalCommissions)),
                      ],
                    ),
                    Text(
                      'Комиссии могут быть в разных валютах; число — арифметическая сумма.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (b.accounts.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text('Счета', style: theme.textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.sm),
                      ...b.accounts.entries.map((e) {
                        final acc = Map<String, dynamic>.from(e.value as Map);
                        return ListTile(
                          dense: true,
                          title: Text(e.key),
                          trailing: Text(
                            '${formatNumberSpaced(acc['balance'] ?? 0)} ${acc['currency'] ?? ''}',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        );
                      }),
                    ],
                    if (b.monthlySummary.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Помесечная активность (проводки по валютам)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      DataTable(
                        columnSpacing: 24,
                        columns: const [
                          DataColumn(label: Text('Месяц')),
                          DataColumn(label: Text('Вал.')),
                          DataColumn(label: Text('Дебет'), numeric: true),
                          DataColumn(label: Text('Кредит'), numeric: true),
                          DataColumn(label: Text('Операций'), numeric: true),
                        ],
                        rows: () {
                          final sorted = b.monthlySummary.entries.toList()
                            ..sort((a, c) => a.key.compareTo(c.key));
                          return sorted.map((e) {
                            final m = Map<String, dynamic>.from(e.value as Map);
                            final mc = _splitMonthCurrencyKey(e.key);
                            return DataRow(cells: [
                              DataCell(Text(mc.$1)),
                              DataCell(Text(mc.$2)),
                              DataCell(Text(formatNumberSpaced(m['debit'] ?? 0))),
                              DataCell(Text(formatNumberSpaced(m['credit'] ?? 0))),
                              DataCell(Text('${m['count'] ?? 0}')),
                            ]);
                          }).toList();
                        }(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        )),
        Text(value, style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
        )),
      ],
    );
  }
}

// ─── Transfers Tab ───

class _TransfersTab extends StatelessWidget {
  final TransferAnalyticsModel? transfers;
  const _TransfersTab({required this.transfers});

  @override
  Widget build(BuildContext context) {
    if (transfers == null) return const Center(child: Text('Нет данных'));

    final theme = Theme.of(context);
    final t = transfers!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Общая статистика переводов', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Объём подтверждённых и выданных — по валютам (включая сплит‑переводы). '
            'Сумма поля amount без разбивки не показывается как одна цифра.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              if (t.volumeByCurrency.isNotEmpty)
                ...t.volumeByCurrency.entries.map((e) {
                  return _KpiCard(
                    label: 'Объём (${e.key})',
                    value: formatNumberSpaced(e.value),
                    icon: Icons.trending_up,
                    color: theme.colorScheme.primary,
                  );
                })
              else
                _KpiCard(
                  label: 'Объём (amount, выборка)',
                  value: formatNumberSpaced(t.totalVolume),
                  icon: Icons.trending_up,
                  color: theme.colorScheme.primary,
                ),
              _KpiCard(
                label: 'Всего переводов',
                value: '${t.totalCount}',
                icon: Icons.receipt_long,
                color: theme.colorScheme.secondary,
              ),
              _KpiCard(
                label: 'Ср. время обработки',
                value: t.avgProcessingFormatted,
                icon: Icons.timer,
                color: Colors.teal,
              ),
              _KpiCard(
                label: 'Комиссии (сумма)',
                value: formatNumberSpaced(t.totalCommissions),
                icon: Icons.payments,
                color: Colors.deepOrange,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Поле «Комиссии» — арифметическая сумма по всем комиссиям; валюты могут различаться.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('По статусам', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          context.isDesktop
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 320,
                      height: 200,
                      child: _TransferStatusBarChart(transfers: t),
                    ),
                    const SizedBox(width: AppSpacing.xl),
                    Expanded(child: _StatusBreakdown(transfers: t)),
                  ],
                )
              : Column(
                  children: [
                    SizedBox(
                      height: 180,
                      child: _TransferStatusBarChart(transfers: t),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _StatusBreakdown(transfers: t),
                  ],
                ),
        ],
      ),
    );
  }
}

class _TransferStatusBarChart extends StatelessWidget {
  final TransferAnalyticsModel transfers;
  const _TransferStatusBarChart({required this.transfers});

  @override
  Widget build(BuildContext context) {
    final data = [
      (transfers.confirmedCount.toDouble(), Colors.green, 'Принят'),
      (transfers.issuedCount.toDouble(), Colors.teal, 'Выдан'),
      (transfers.pendingCount.toDouble(), Colors.orange, 'Ожид.'),
      (transfers.rejectedCount.toDouble(), Colors.red, 'Откл.'),
      (transfers.cancelledCount.toDouble(), Colors.grey, 'Отмен.'),
    ];
    final maxY = data.map((e) => e.$1).reduce((a, b) => a > b ? a : b);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY <= 0 ? 1 : maxY * 1.2,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              return BarTooltipItem(
                '${rod.toY.toInt()}',
                const TextStyle(color: Colors.white),
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
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final label = data[value.toInt()].$3;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(label, style: const TextStyle(fontSize: 11)),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(
          show: true,
          drawVerticalLine: false,
        ),
        barGroups: data.asMap().entries.map((entry) {
          final i = entry.key;
          final item = entry.value;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: item.$1 <= 0 ? 0.001 : item.$1,
                color: item.$2,
                width: 32,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(6)),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _StatusBreakdown extends StatelessWidget {
  final TransferAnalyticsModel transfers;
  const _StatusBreakdown({required this.transfers});

  @override
  Widget build(BuildContext context) {
    final total = transfers.totalCount;
    final items = [
      _StatusItem('В ожидании', transfers.pendingCount, Colors.orange),
      _StatusItem('Принято', transfers.confirmedCount, Colors.green),
      _StatusItem('Выдано', transfers.issuedCount, Colors.teal),
      _StatusItem('Отклонено', transfers.rejectedCount, Colors.red),
      _StatusItem('Отменено', transfers.cancelledCount, Colors.grey),
    ];

    return Column(
      children: items.map((item) {
        final pct = total > 0 ? item.count / total : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: Text(item.label,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              Expanded(
                child: LinearProgressIndicator(
                  value: pct,
                  backgroundColor: item.color.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation(item.color),
                  minHeight: 20,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              SizedBox(
                width: 80,
                child: Text(
                  '${item.count} (${(pct * 100).toStringAsFixed(1)}%)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _StatusItem {
  final String label;
  final int count;
  final Color color;
  const _StatusItem(this.label, this.count, this.color);
}

// ─── Currency Tab ───

class _CurrencyTab extends StatelessWidget {
  final List<CurrencyAnalyticsModel> currencies;
  const _CurrencyTab({required this.currencies});

  @override
  Widget build(BuildContext context) {
    if (currencies.isEmpty) return const Center(child: Text('Нет данных о валютах'));

    final theme = Theme.of(context);

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: currencies.length,
      itemBuilder: (context, index) {
        final c = currencies[index];
        return Card(
          margin: const EdgeInsets.only(bottom: AppSpacing.md),
          child: ExpansionTile(
            leading: Text(
              _pairFlag(c.pair),
              style: const TextStyle(fontSize: 24),
            ),
            title: Text(c.pair,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('Текущий курс: ${c.latestRate.toStringAsFixed(4)}'),
            trailing: Text(
              'Объём: ${formatNumberSpaced(c.conversionVolume)}',
              style: theme.textTheme.bodySmall,
            ),
            children: [
              if (c.rateHistory.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 160,
                        child: _RateLineChart(history: c.rateHistory),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      DataTable(
                        columnSpacing: 24,
                        columns: const [
                          DataColumn(label: Text('Курс'), numeric: true),
                          DataColumn(label: Text('Дата')),
                        ],
                        rows: c.rateHistory.take(8).map((h) {
                          return DataRow(cells: [
                            DataCell(Text(
                                (h['rate'] as num?)?.toStringAsFixed(4) ?? '')),
                            DataCell(Text(_formatDate(h['date'] as String?))),
                          ]);
                        }).toList(),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RateLineChart extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  const _RateLineChart({required this.history});

  @override
  Widget build(BuildContext context) {
    final reversed = history.reversed.toList();
    final spots = reversed.asMap().entries.map((e) {
      final rate = (e.value['rate'] as num?)?.toDouble() ?? 0;
      return FlSpot(e.key.toDouble(), rate);
    }).toList();

    if (spots.isEmpty) return const SizedBox.shrink();

    final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final yPad = (maxY - minY) * 0.15;

    return LineChart(
      LineChartData(
        minY: minY - yPad,
        maxY: maxY + yPad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 48,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(2),
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: AppColors.primary,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: spots.length <= 10,
              getDotPainter: (spot, pct, bar, idx) =>
                  FlDotCirclePainter(
                radius: 3,
                color: AppColors.primary,
                strokeWidth: 0,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              color: AppColors.primary.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared Widgets ───

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _KpiCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

String _formatDate(String? isoDate) {
  if (isoDate == null || isoDate.isEmpty) return '';
  try {
    final date = DateTime.parse(isoDate);
    return DateFormat('dd.MM.yyyy HH:mm').format(date);
  } catch (_) {
    return isoDate;
  }
}

/// Ключ вида `YYYY-MM|CUR` из aggregateAnalytics; [legacy] — только месяц.
(String, String) _splitMonthCurrencyKey(String raw) {
  final i = raw.indexOf('|');
  if (i <= 0) return (raw, '—');
  return (raw.substring(0, i), raw.substring(i + 1));
}
