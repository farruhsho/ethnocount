import 'package:equatable/equatable.dart';

/// One payout tranche of a confirmed transfer.
///
/// A confirmed transfer can be paid out to the recipient in multiple parts;
/// each tranche becomes a `transfer_issuances` row and bumps
/// `transfers.issued_amount`. The transfer flips to `issued` status only
/// when the cumulative tranches reach the credited amount.
class TransferIssuance extends Equatable {
  final String id;
  final String transferId;
  final double amount;
  final String currency;
  final String issuedBy;
  final DateTime issuedAt;
  final String? note;

  /// Счёт получающего филиала, с которого реально вышли деньги
  /// (наличная касса / карта). null для старых записей до миграции 014.
  final String? fromAccountId;

  const TransferIssuance({
    required this.id,
    required this.transferId,
    required this.amount,
    required this.currency,
    required this.issuedBy,
    required this.issuedAt,
    this.note,
    this.fromAccountId,
  });

  factory TransferIssuance.fromMap(Map<String, dynamic> m) {
    return TransferIssuance(
      id: m['id']?.toString() ?? '',
      transferId: m['transfer_id']?.toString() ?? '',
      amount: (m['amount'] ?? 0).toDouble(),
      currency: m['currency']?.toString() ?? 'USD',
      issuedBy: m['issued_by']?.toString() ?? '',
      issuedAt: DateTime.tryParse(m['issued_at']?.toString() ?? '') ??
          DateTime.now(),
      note: (m['note'] is String && (m['note'] as String).trim().isNotEmpty)
          ? m['note'] as String
          : null,
      fromAccountId: m['from_account_id']?.toString(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        transferId,
        amount,
        currency,
        issuedBy,
        issuedAt,
        note,
        fromAccountId,
      ];
}
