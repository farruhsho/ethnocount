import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
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
                        : _RatesView(rates: state.rates),
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

// ─── Unified responsive view (desktop + tablet + phone) ───
//
// Структура одинакова на всех экранах: «Текущие курсы» сверху —
// сетка адаптивных карточек, «История» — список карточек. На широких
// экранах карточки выстраиваются в несколько колонок, на узких — в одну.

class _RatesView extends StatelessWidget {
  final List<ExchangeRate> rates;
  const _RatesView({required this.rates});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');

    final latestByPair = <String, ExchangeRate>{};
    for (final r in rates) {
      final key = '${r.fromCurrency}/${r.toCurrency}';
      latestByPair.putIfAbsent(key, () => r);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Текущие курсы',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.md),
          _ResponsiveCardGrid(
            minCardWidth: 220,
            children: [
              for (final entry in latestByPair.entries)
                _CurrentRateCard(rate: entry.value, dateFmt: dateFmt),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('История изменений',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.md),
          _ResponsiveCardGrid(
            minCardWidth: 280,
            children: [
              for (final r in rates) _HistoryRateCard(rate: r, dateFmt: dateFmt),
            ],
          ),
        ],
      ),
    );
  }
}

/// Универсальная сетка: внутри Wrap, ширина каждой карточки считается из
/// доступной ширины так, чтобы поместилось максимум целых колонок при
/// `minCardWidth`. Высота — по содержимому.
class _ResponsiveCardGrid extends StatelessWidget {
  const _ResponsiveCardGrid({
    required this.children,
    required this.minCardWidth,
  });
  final List<Widget> children;
  final double minCardWidth;
  static const double spacing = AppSpacing.md;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final cols = (c.maxWidth / minCardWidth).floor().clamp(1, 6);
        final cardWidth =
            (c.maxWidth - (cols - 1) * spacing) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: cardWidth, child: child),
          ],
        );
      },
    );
  }
}

class _CurrentRateCard extends StatelessWidget {
  const _CurrentRateCard({required this.rate, required this.dateFmt});
  final ExchangeRate rate;
  final DateFormat dateFmt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
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
                  child: Text(
                    '${rate.fromCurrency}/${rate.toCurrency}',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                rate.rate.toStringAsFixed(4),
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
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
    );
  }
}

class _HistoryRateCard extends StatelessWidget {
  const _HistoryRateCard({required this.rate, required this.dateFmt});
  final ExchangeRate rate;
  final DateFormat dateFmt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.18)),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.currency_exchange,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${rate.fromCurrency} / ${rate.toCurrency}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                rate.rate.toStringAsFixed(4),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.swap_vert_rounded, size: 12, color: secondary),
              const SizedBox(width: 4),
              Text('Обратный: ${rate.inverseRate.toStringAsFixed(4)}',
                  style: TextStyle(fontSize: 11, color: secondary)),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 12, color: secondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(dateFmt.format(rate.effectiveAt),
                    style: TextStyle(fontSize: 11, color: secondary)),
              ),
            ],
          ),
          if (rate.setBy.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(Icons.person_outline, size: 12, color: secondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('Установил: ${rate.setBy}',
                      style: TextStyle(fontSize: 11, color: secondary),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
