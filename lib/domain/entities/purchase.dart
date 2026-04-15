import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';

AccountType? _accountTypeFromStorage(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  for (final t in AccountType.values) {
    if (t.name == raw) return t;
  }
  return null;
}

/// A single payment source in a split-payment purchase.
class PurchasePayment extends Equatable {
  final String accountId;
  final String accountName;
  final double amount;
  final String currency;

  /// Branch account kind (cash, card, …). Null in older Firestore documents.
  final AccountType? accountType;

  /// Percentage of total purchase amount (0–100).
  final double percentage;

  const PurchasePayment({
    required this.accountId,
    required this.accountName,
    required this.amount,
    required this.currency,
    this.accountType,
    required this.percentage,
  });

  factory PurchasePayment.fromMap(Map<String, dynamic> m) {
    return PurchasePayment(
      accountId: m['accountId'] ?? '',
      accountName: m['accountName'] ?? '',
      amount: (m['amount'] ?? 0).toDouble(),
      currency: m['currency'] ?? 'USD',
      accountType: _accountTypeFromStorage(m['accountType']),
      percentage: (m['percentage'] ?? 0).toDouble(),
    );
  }

  Map<String, dynamic> toMap() => {
        'accountId': accountId,
        'accountName': accountName,
        'amount': amount,
        'currency': currency,
        if (accountType != null) 'accountType': accountType!.name,
        'percentage': percentage,
      };

  @override
  List<Object?> get props =>
      [accountId, accountName, amount, currency, percentage, accountType];
}

/// A purchase transaction — money spent from branch accounts.
/// Supports split payments from multiple account sources.
///
/// Example: 1000$ purchase paid as:
///   - 500$ cash  (50%)
///   - 300$ card  (30%)
///   - 200$ bank  (20%)
class Purchase extends Equatable {
  final String id;

  /// Human-readable unique code: ETH-TX-2026-000145.
  final String transactionCode;

  final String branchId;

  /// Optional — which client this purchase is for.
  final String? clientId;
  final String? clientName;

  /// What was purchased.
  final String description;

  /// Optional category tag.
  final String? category;

  final double totalAmount;
  final String currency;

  /// Breakdown of payments across accounts.
  final List<PurchasePayment> payments;

  final String createdBy;
  final DateTime createdAt;

  const Purchase({
    required this.id,
    required this.transactionCode,
    required this.branchId,
    this.clientId,
    this.clientName,
    required this.description,
    this.category,
    required this.totalAmount,
    required this.currency,
    required this.payments,
    required this.createdBy,
    required this.createdAt,
  });

  /// Portion paid from **cash** accounts ([AccountType.cash]).
  ///
  /// Legacy purchases without [PurchasePayment.accountType] contribute `0` here.
  /// For “sum in [currency] regardless of account kind”, use [amountInPurchaseCurrency].
  double get cashAmount => payments
      .where((p) => p.accountType == AccountType.cash)
      .fold<double>(0, (s, p) => s + p.amount);

  /// Sum of payment lines whose line currency matches this purchase’s [currency].
  double get amountInPurchaseCurrency => payments
      .where((p) => p.currency == currency)
      .fold<double>(0, (s, p) => s + p.amount);

  @override
  List<Object?> get props =>
      [id, transactionCode, branchId, totalAmount, currency, createdAt];
}
