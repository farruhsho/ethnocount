import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';

/// Универсальный блок ввода дилерских курсов (buy/sell + base currency).
///
/// Используется в трёх местах:
///   1. PartnerTransferDialog — создание партнёрского перевода
///   2. _AttachToPartnerFromTransferDialog — прикрепление к партнёру
///      существующего перевода из списка переводов
///   3. _AttachTransferDialog — прикрепление перевода из карточки
///      партнёра
///
/// Раньше в каждом месте была своя копия (с разным набором валют,
/// без кнопки «подставить рыночный курс» и т.д.). Теперь — один
/// шаблон с одинаковым UX и edge-case'ами.
///
/// `baseAmount` и `spreadProfit` опциональны: если переданы > 0,
/// внизу появляется live-превью «Долг партнёра + spread». В attach-
/// диалоге их можно не передавать (мы не считаем превью в реальном
/// времени из-за курса перевода).
class DealerRatesBlock extends StatelessWidget {
  const DealerRatesBlock({
    super.key,
    required this.baseCurrency,
    required this.sourceCurrency,
    required this.onBaseChanged,
    required this.buyController,
    required this.sellController,
    this.buyError,
    this.sellError,
    this.onBuyChanged,
    this.onSellChanged,
    this.spreadProfit = 0,
    this.spreadCurrency = '',
    this.baseAmount = 0,
    this.showFillMarketRate = true,
  });

  final String baseCurrency;
  final String sourceCurrency;
  final ValueChanged<String> onBaseChanged;
  final TextEditingController buyController;
  final TextEditingController sellController;
  final String? buyError;
  final String? sellError;
  final VoidCallback? onBuyChanged;
  final VoidCallback? onSellChanged;

  /// Если > 0 — внизу показывается live-превью с suma долга партнёра
  /// и spread profit. В attach-диалогах оставить 0, в форме создания —
  /// передавать рассчитанные значения.
  final double spreadProfit;
  final String spreadCurrency;
  final double baseAmount;

  /// Показывать кнопку «Подставить рыночный курс». В attach-диалогах
  /// уже выбран существующий перевод — курс ему уже задан, market-rate
  /// не нужен. В создании — нужен.
  final bool showFillMarketRate;

  /// Часто-используемые «базы» в нашем сегменте СНГ. Один список на
  /// все три диалога — раньше в одном было 4 валюты, в другом 5.
  static const baseCurrencies = ['USD', 'EUR', 'RUB', 'UZS', 'KZT'];

  /// Тянет последний рыночный курс base → sourceCurrency из
  /// exchange_rates и подставляет в buyController. Sell оставляем
  /// оператору (там обычно ниже buy на маржу).
  Future<void> _fillMarketRate(BuildContext context) async {
    if (baseCurrency == sourceCurrency) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final direct = await sl<ExchangeRateRepository>()
          .getLatestRate(baseCurrency, sourceCurrency)
          .then((r) => r.fold((_) => null, (v) => v));
      double? rate = (direct?.rate ?? 0) > 0 ? direct!.rate : null;
      if (rate == null) {
        final inverse = await sl<ExchangeRateRepository>()
            .getLatestRate(sourceCurrency, baseCurrency)
            .then((r) => r.fold((_) => null, (v) => v));
        if ((inverse?.rate ?? 0) > 0) rate = 1 / inverse!.rate;
      }
      if (rate == null || rate <= 0) {
        messenger.showSnackBar(SnackBar(
          content: Text(
              'Нет курса $baseCurrency → $sourceCurrency. Добавь в «Курсы валют».'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      buyController.text = rate == rate.roundToDouble()
          ? rate.toStringAsFixed(0)
          : rate.toString();
      onBuyChanged?.call();
      messenger.showSnackBar(SnackBar(
        content:
            Text('Buy подставлен: 1 $baseCurrency = $rate $sourceCurrency'),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Не удалось получить курс: $e'),
        backgroundColor: AppColors.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: baseCurrencies.contains(baseCurrency)
                      ? baseCurrency
                      : 'USD',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Базовая валюта учёта',
                    border: OutlineInputBorder(),
                    isDense: true,
                    helperText: 'Saldo с партнёром в этой валюте',
                  ),
                  items: baseCurrencies
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(CurrencyUtils.flag(c)),
                                const SizedBox(width: 6),
                                Text(c,
                                    style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onBaseChanged(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Buy + Sell rate.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: buyController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    DecimalInputFormatter(),
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onChanged: (_) => onBuyChanged?.call(),
                  decoration: InputDecoration(
                    labelText: 'Наш курс приёма (buy)',
                    helperText: '1 $baseCurrency = X $sourceCurrency',
                    border: const OutlineInputBorder(),
                    errorText: buyError,
                    isDense: true,
                    prefixIcon:
                        const Icon(AppIcons.arrow_downward, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextField(
                  controller: sellController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    DecimalInputFormatter(),
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onChanged: (_) => onSellChanged?.call(),
                  decoration: InputDecoration(
                    labelText: 'Курс расчёта с партнёром (sell)',
                    helperText: '1 $baseCurrency = Y $sourceCurrency',
                    border: const OutlineInputBorder(),
                    errorText: sellError,
                    isDense: true,
                    prefixIcon: const Icon(AppIcons.arrow_upward, size: 18),
                  ),
                ),
              ),
            ],
          ),
          if (showFillMarketRate) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: baseCurrency == sourceCurrency
                    ? null
                    : () => _fillMarketRate(context),
                icon: const Icon(AppIcons.refresh, size: 14),
                label: const Text('Подставить рыночный курс',
                    style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                ),
              ),
            ),
          ],
          if (baseAmount > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                children: [
                  Icon(AppIcons.account_tree,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    'Долг партнёра: ${baseAmount.formatCurrencyNoDecimals()} $baseCurrency',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (spreadProfit > 0) ...[
                    Icon(Icons.trending_up,
                        size: 14, color: Colors.green.shade600),
                    const SizedBox(width: 4),
                    Text(
                      '+${spreadProfit.formatCurrencyNoDecimals()} $spreadCurrency',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Colors.green.shade600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ] else if (spreadProfit < 0)
                    Text(
                      'Убыток ${spreadProfit.abs().formatCurrencyNoDecimals()} $spreadCurrency',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.red.shade600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
