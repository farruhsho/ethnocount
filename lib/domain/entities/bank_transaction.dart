import 'package:equatable/equatable.dart';

/// Raw bank transaction parsed from CSV/Excel or API.
/// Used for import into ledger with categorization and counterparty linking.
class BankTransaction extends Equatable {
  /// Date of the transaction.
  final DateTime date;

  /// Amount (always positive; use isCredit to determine direction).
  final double amount;

  final String currency;

  /// Bank's description of the transaction.
  final String description;

  /// true = поступление (credit), false = списание (debit).
  final bool isCredit;

  /// Optional counterparty from bank statement (e.g. "ИП Иванов").
  final String? counterpartyRaw;

  /// Source bank name (Sberbank, Alfa, etc.) for display.
  final String? bankName;

  const BankTransaction({
    required this.date,
    required this.amount,
    this.currency = 'RUB',
    required this.description,
    required this.isCredit,
    this.counterpartyRaw,
    this.bankName,
  });

  @override
  List<Object?> get props => [date, amount, currency, description, isCredit];
}
