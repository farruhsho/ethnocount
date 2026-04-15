import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// An immutable double-entry ledger record.
/// Balances are computed as: SUM(credits) - SUM(debits) for an account.
class LedgerEntry extends Equatable {
  final String id;
  final String branchId;
  final String accountId;
  final LedgerEntryType type;
  final double amount;
  final String currency;
  final LedgerReferenceType referenceType;
  final String referenceId;
  final String description;
  final String createdBy;
  final DateTime createdAt;

  const LedgerEntry({
    required this.id,
    required this.branchId,
    required this.accountId,
    required this.type,
    required this.amount,
    required this.currency,
    required this.referenceType,
    required this.referenceId,
    required this.description,
    required this.createdBy,
    required this.createdAt,
  });

  /// Signed amount: positive for credits, negative for debits.
  double get signedAmount =>
      type == LedgerEntryType.credit ? amount : -amount;

  @override
  List<Object?> get props => [
        id,
        branchId,
        accountId,
        type,
        amount,
        currency,
        referenceType,
        referenceId,
        createdAt,
      ];
}
