import 'package:equatable/equatable.dart';

/// A single part of a split-currency transfer.
/// Example: 500 USD from account A + 30,000 RUB from account B.
class TransferPart extends Equatable {
  final String accountId;
  final String accountName;
  final double amount;
  final String currency;

  const TransferPart({
    required this.accountId,
    required this.accountName,
    required this.amount,
    required this.currency,
  });

  factory TransferPart.fromMap(Map<String, dynamic> m) {
    return TransferPart(
      accountId: m['accountId'] ?? '',
      accountName: m['accountName'] ?? '',
      amount: (m['amount'] ?? 0).toDouble(),
      currency: m['currency'] ?? 'USD',
    );
  }

  Map<String, dynamic> toMap() => {
        'accountId': accountId,
        'accountName': accountName,
        'amount': amount,
        'currency': currency,
      };

  @override
  List<Object?> get props => [accountId, amount, currency];
}
