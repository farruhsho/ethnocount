import 'package:intl/intl.dart';

/// Number formatting helpers.
///
/// Project rule: thousands separator is a regular space (not comma) and the
/// decimal separator is a dot — `3 000.00`. We format with the en_US pattern
/// (which uses commas) and then post-process commas to spaces, keeping the
/// rest of intl's locale-aware behavior intact.
String formatNumberSpaced(num value, {int decimals = 2}) {
  final pattern = decimals > 0 ? '#,##0.${'0' * decimals}' : '#,##0';
  return NumberFormat(pattern, 'en_US').format(value).replaceAll(',', ' ');
}

/// Extensions on num for currency and display formatting.
extension NumberX on num {
  /// Format as currency: "1 234 567.89" — thousands separated by space.
  String formatCurrency([String symbol = '']) {
    final formatted = formatNumberSpaced(this, decimals: 2);
    return symbol.isEmpty ? formatted : '$symbol$formatted';
  }

  /// Format as whole number (no kopecks): "1 234 568".
  String formatCurrencyNoDecimals([String symbol = '']) {
    final formatted = formatNumberSpaced(round(), decimals: 0);
    return symbol.isEmpty ? formatted : '$symbol$formatted';
  }

  /// Format with currency code: "1 234.56 UZS"
  String withCurrency(String currency) {
    return '${formatCurrency()} $currency';
  }

  /// Format compact: "1.2K", "3.4M"
  String get compact => NumberFormat.compact().format(this);

  /// Format percentage: "45.2%"
  String get percentage => '${toStringAsFixed(1)}%';

  /// Format as signed: "+1 234.00" or "-1 234.00"
  String get signed {
    final formatted = abs().formatCurrency();
    return this >= 0 ? '+$formatted' : '-$formatted';
  }
}
