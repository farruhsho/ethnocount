import 'package:intl/intl.dart';

/// Currency metadata: flags, full names, and supported list.
class CurrencyUtils {
  CurrencyUtils._();

  /// All supported currencies in the system.
  static const List<String> supported = [
    'USD',
    'USDT',
    'EUR',
    'RUB',
    'UZS',
    'TRY',
    'AED',
    'CNY',
    'KZT',
    'KGS',
    'TJS',
  ];

  /// Flag emoji for each currency (based on issuing country).
  static const Map<String, String> flags = {
    'USD': '🇺🇸',
    'USDT': '₮',
    'EUR': '🇪🇺',
    'RUB': '🇷🇺',
    'UZS': '🇺🇿',
    'TRY': '🇹🇷',
    'AED': '🇦🇪',
    'CNY': '🇨🇳',
    'KZT': '🇰🇿',
    'KGS': '🇰🇬',
    'TJS': '🇹🇯',
  };

  /// Full currency names in Russian.
  static const Map<String, String> names = {
    'USD': 'Доллар США',
    'USDT': 'Tether',
    'EUR': 'Евро',
    'RUB': 'Российский рубль',
    'UZS': 'Узбекский сум',
    'TRY': 'Турецкая лира',
    'AED': 'Дирхам ОАЭ',
    'CNY': 'Китайский юань',
    'KZT': 'Казахстанский тенге',
    'KGS': 'Кыргызский сом',
    'TJS': 'Таджикский сомони',
  };

  /// Currency symbols.
  static const Map<String, String> symbols = {
    'USD': '\$',
    'USDT': '₮',
    'EUR': '€',
    'RUB': '₽',
    'UZS': 'сум',
    'TRY': '₺',
    'AED': 'د.إ',
    'CNY': '¥',
    'KZT': '₸',
    'KGS': 'с',
    'TJS': 'с.',
  };

  static String flag(String currency) => flags[currency] ?? '🏳️';
  static String name(String currency) => names[currency] ?? currency;
  static String symbol(String currency) => symbols[currency] ?? currency;

  /// Display string: flag + code, e.g. "🇺🇸 USD"
  static String display(String currency) => '${flag(currency)} $currency';

  /// Full display: flag + code + name, e.g. "🇺🇸 USD — Доллар США"
  static String fullDisplay(String currency) =>
      '${flag(currency)} $currency — ${name(currency)}';

  /// Format an amount with currency symbol.
  static String format(double amount, String currency) {
    final sym = symbol(currency);
    final formatted = amount.toStringAsFixed(2);
    return '$sym $formatted';
  }

  /// Display order for balance breakdown (USD, USDT, RUB, UZS first).
  static const List<String> displayOrder = [
    'USD', 'USDT', 'RUB', 'UZS', 'EUR', 'TRY', 'AED', 'CNY', 'KZT', 'KGS', 'TJS',
  ];

  /// Format balance breakdown by currency for display.
  /// E.g. "5 000 USD, 100 USDT, 19 000 RUB, 120 000 000 UZS"
  /// Uses consistent order and locale-aware number formatting.
  static String formatBalanceBreakdown(Map<String, double> byCurrency) {
    if (byCurrency.isEmpty) return '0';
    final entries = byCurrency.entries
        .where((e) => e.value != 0)
        .toList();
    if (entries.isEmpty) return '0';
    entries.sort((a, b) {
      final ai = displayOrder.indexOf(a.key);
      final bi = displayOrder.indexOf(b.key);
      if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
      if (ai >= 0) return -1;
      if (bi >= 0) return 1;
      return a.key.compareTo(b.key);
    });
    return entries
        .map((e) => '${_formatAmount(e.value, e.key)} ${e.key}')
        .join(', ');
  }

  /// Format amount: no decimals for UZS/KZT/KGS (large numbers), 2 decimals for others.
  static String _formatAmount(double value, String currency) {
    final noDecimals = ['UZS', 'KZT', 'KGS'];
    final formatter = NumberFormat.decimalPattern()
      ..minimumFractionDigits = noDecimals.contains(currency) ? 0 : 2
      ..maximumFractionDigits = noDecimals.contains(currency) ? 0 : 2;
    return formatter.format(value);
  }
}
