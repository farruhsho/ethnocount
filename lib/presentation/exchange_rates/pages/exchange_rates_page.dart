import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/domain/entities/exchange_rate.dart';
import 'package:ethnocount/presentation/exchange_rates/bloc/exchange_rate_bloc.dart';

class ExchangeRatesPage extends StatefulWidget {
  const ExchangeRatesPage({super.key});

  @override
  State<ExchangeRatesPage> createState() => _ExchangeRatesPageState();
}

class _ExchangeRatesPageState extends State<ExchangeRatesPage> {
  String? _filterFrom;
  String? _filterTo;

  @override
  void initState() {
    super.initState();
    final bloc = context.read<ExchangeRateBloc>();
    bloc.add(const ExchangeRateLoadRequested());
    bloc.add(const ExchangeRateCurrenciesRequested());
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ExchangeRateBloc, ExchangeRateBlocState>(
      listener: (context, state) {
        if (state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage!),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        if (state.successMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage!),
              backgroundColor: Colors.green.shade700,
            ),
          );
        }
      },
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Курсы валют'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Установить курс',
                onPressed: () => _showSetRateDialog(context, state.currencies),
              ),
            ],
          ),
          body: Column(
            children: [
              _FilterBar(
                currencies: state.currencies,
                filterFrom: _filterFrom,
                filterTo: _filterTo,
                onFromChanged: (v) {
                  setState(() => _filterFrom = v);
                  context.read<ExchangeRateBloc>().add(
                        ExchangeRateLoadRequested(
                          fromCurrency: v,
                          toCurrency: _filterTo,
                        ),
                      );
                },
                onToChanged: (v) {
                  setState(() => _filterTo = v);
                  context.read<ExchangeRateBloc>().add(
                        ExchangeRateLoadRequested(
                          fromCurrency: _filterFrom,
                          toCurrency: v,
                        ),
                      );
                },
              ),
              Expanded(
                child: state.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : state.rates.isEmpty
                        ? const Center(
                            child: Text('Нет данных о курсах. Установите первый курс.'))
                        : context.isDesktop
                            ? _DesktopRatesGrid(rates: state.rates)
                            : _MobileRatesList(rates: state.rates),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSetRateDialog(BuildContext context, List<String> currencies) {
    final formKey = GlobalKey<FormState>();
    String? from;
    String? to;
    final rateController = TextEditingController();

    final defaultCurrencies = currencies.isNotEmpty
        ? currencies
        : ['USD', 'USDT', 'RUB', 'UZS', 'KGS', 'TRY', 'KZT', 'TJS', 'CNY', 'AED'];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Установить курс'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Из валюты'),
                items: defaultCurrencies
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => from = v,
                validator: (v) => v == null ? 'Выберите валюту' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'В валюту'),
                items: defaultCurrencies
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => to = v,
                validator: (v) {
                  if (v == null) return 'Выберите валюту';
                  if (v == from) return 'Должна отличаться от исходной';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: rateController,
                decoration: const InputDecoration(
                  labelText: 'Курс',
                  hintText: '0.0000',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Введите курс';
                  final parsed = double.tryParse(v);
                  if (parsed == null || parsed <= 0) return 'Курс должен быть > 0';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                context.read<ExchangeRateBloc>().add(
                      ExchangeRateSetRequested(
                        fromCurrency: from!,
                        toCurrency: to!,
                        rate: double.parse(rateController.text),
                      ),
                    );
                Navigator.pop(ctx);
              }
            },
            child: const Text('Установить'),
          ),
        ],
      ),
    );
  }
}

// ─── Filter Bar ───

class _FilterBar extends StatelessWidget {
  final List<String> currencies;
  final String? filterFrom;
  final String? filterTo;
  final ValueChanged<String?> onFromChanged;
  final ValueChanged<String?> onToChanged;

  const _FilterBar({
    required this.currencies,
    required this.filterFrom,
    required this.filterTo,
    required this.onFromChanged,
    required this.onToChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      const DropdownMenuItem<String>(value: null, child: Text('Все')),
      ...currencies.map((c) => DropdownMenuItem(
            value: c,
            child: Text(CurrencyUtils.display(c)),
          )),
    ];

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.sm,
        children: [
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              key: ValueKey('from-$filterFrom'),
              initialValue: filterFrom,
              decoration: const InputDecoration(
                labelText: 'Из валюты',
                isDense: true,
              ),
              items: items,
              onChanged: onFromChanged,
            ),
          ),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              key: ValueKey('to-$filterTo'),
              initialValue: filterTo,
              decoration: const InputDecoration(
                labelText: 'В валюту',
                isDense: true,
              ),
              items: items,
              onChanged: onToChanged,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Desktop Grid ───

class _DesktopRatesGrid extends StatelessWidget {
  final List<ExchangeRate> rates;
  const _DesktopRatesGrid({required this.rates});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');

    // Group by unique pair and show latest
    final latestByPair = <String, ExchangeRate>{};
    for (final r in rates) {
      final key = '${r.fromCurrency}/${r.toCurrency}';
      if (!latestByPair.containsKey(key)) {
        latestByPair[key] = r;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Текущие курсы', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          _CurrentRatesCards(latestByPair: latestByPair, dateFmt: dateFmt),
          const SizedBox(height: AppSpacing.xl),
          Text('История изменений', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          _RatesDataTable(rates: rates, dateFmt: dateFmt),
        ],
      ),
    );
  }
}

class _CurrentRatesCards extends StatelessWidget {
  final Map<String, ExchangeRate> latestByPair;
  final DateFormat dateFmt;

  const _CurrentRatesCards({required this.latestByPair, required this.dateFmt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.md,
      children: latestByPair.entries.map((e) {
        final rate = e.value;
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
                      Text(
                        '${CurrencyUtils.flag(rate.fromCurrency)} → ${CurrencyUtils.flag(rate.toCurrency)}',
                        style: const TextStyle(fontSize: 18),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(e.key,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    rate.rate.toStringAsFixed(4),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    dateFmt.format(rate.effectiveAt),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _RatesDataTable extends StatelessWidget {
  final List<ExchangeRate> rates;
  final DateFormat dateFmt;

  const _RatesDataTable({required this.rates, required this.dateFmt});

  @override
  Widget build(BuildContext context) {
    return DataTable(
      columns: const [
        DataColumn(label: Text('Пара')),
        DataColumn(label: Text('Курс'), numeric: true),
        DataColumn(label: Text('Обратный'), numeric: true),
        DataColumn(label: Text('Дата')),
        DataColumn(label: Text('Установил')),
      ],
      rows: rates.map((r) {
        return DataRow(cells: [
          DataCell(Text('${r.fromCurrency}/${r.toCurrency}')),
          DataCell(Text(r.rate.toStringAsFixed(4))),
          DataCell(Text(r.inverseRate.toStringAsFixed(4))),
          DataCell(Text(dateFmt.format(r.effectiveAt))),
          DataCell(Text(r.setBy)),
        ]);
      }).toList(),
    );
  }
}

// ─── Mobile List ───

class _MobileRatesList extends StatelessWidget {
  final List<ExchangeRate> rates;
  const _MobileRatesList({required this.rates});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');

    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: rates.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final r = rates[index];
        return Card(
          child: ListTile(
            leading: Icon(Icons.currency_exchange, color: theme.colorScheme.primary),
            title: Text('${r.fromCurrency}/${r.toCurrency}'),
            subtitle: Text(dateFmt.format(r.effectiveAt)),
            trailing: Text(
              r.rate.toStringAsFixed(4),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        );
      },
    );
  }
}
