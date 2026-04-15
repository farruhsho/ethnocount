import 'package:intl/intl.dart';

/// Extensions on num for currency and display formatting.
extension NumberX on num {
  /// Format as currency: "1,234,567.89"
  String formatCurrency([String symbol = '']) {
    final formatter = NumberFormat.currency(
      symbol: symbol,
      decimalDigits: 2,
    );
    return formatter.format(this);
  }

  /// Format as whole number (no kopecks): "1,234,568"
  String formatCurrencyNoDecimals([String symbol = '']) {
    final formatter = NumberFormat.currency(
      symbol: symbol,
      decimalDigits: 0,
    );
    return formatter.format(this.round());
  }

  /// Format with currency code: "1,234.56 UZS"
  String withCurrency(String currency) {
    return '${formatCurrency()} $currency';
  }

  /// Format compact: "1.2K", "3.4M"
  String get compact => NumberFormat.compact().format(this);

  /// Format percentage: "45.2%"
  String get percentage => '${toStringAsFixed(1)}%';

  /// Format as signed: "+1,234.00" or "-1,234.00"
  String get signed {
    final formatted = abs().formatCurrency();
    return this >= 0 ? '+$formatted' : '-$formatted';
  }
}
