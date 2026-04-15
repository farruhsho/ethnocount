import 'package:equatable/equatable.dart';

/// Historical exchange rate record.
/// Rates are immutable once created — never overwritten.
class ExchangeRate extends Equatable {
  final String id;
  final String fromCurrency;
  final String toCurrency;
  final double rate;
  final String setBy;
  final DateTime effectiveAt;
  final DateTime createdAt;

  const ExchangeRate({
    required this.id,
    required this.fromCurrency,
    required this.toCurrency,
    required this.rate,
    required this.setBy,
    required this.effectiveAt,
    required this.createdAt,
  });

  /// Convert an amount using this rate.
  double convert(double amount) => amount * rate;

  /// Inverse rate for reverse conversion.
  double get inverseRate => rate != 0 ? 1 / rate : 0;

  @override
  List<Object?> get props =>
      [id, fromCurrency, toCurrency, rate, effectiveAt];
}
