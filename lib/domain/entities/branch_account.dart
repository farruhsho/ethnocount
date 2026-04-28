import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// An account within a branch (cash, card, reserve, transit).
/// Balance is NOT stored here — it is computed from ledger entries.
class BranchAccount extends Equatable {
  final String id;
  final String branchId;
  final String name;
  final AccountType type;
  final String currency;
  final bool isActive;

  /// Card-specific fields (nullable for non-card accounts).
  final String? cardNumber;
  final String? cardLast4; // generated column — computed server-side
  final String? cardholderName;
  final String? bankName;
  final int? expiryMonth;
  final int? expiryYear;
  final String? notes;

  final int sortOrder;
  final DateTime? archivedAt;
  final DateTime createdAt;

  const BranchAccount({
    required this.id,
    required this.branchId,
    required this.name,
    required this.type,
    required this.currency,
    this.isActive = true,
    this.cardNumber,
    this.cardLast4,
    this.cardholderName,
    this.bankName,
    this.expiryMonth,
    this.expiryYear,
    this.notes,
    this.sortOrder = 0,
    this.archivedAt,
    required this.createdAt,
  });

  /// Masked card display: '•••• 1234'. Returns null if no card_last4.
  String? get cardMasked => cardLast4 == null ? null : '•••• $cardLast4';

  /// '01/27' expiry formatted. Returns null if any part is missing.
  String? get expiryFormatted {
    if (expiryMonth == null || expiryYear == null) return null;
    final mm = expiryMonth!.toString().padLeft(2, '0');
    final yy = (expiryYear! % 100).toString().padLeft(2, '0');
    return '$mm/$yy';
  }

  @override
  List<Object?> get props => [
        id,
        branchId,
        name,
        type,
        currency,
        isActive,
        cardNumber,
        cardLast4,
        cardholderName,
        bankName,
        expiryMonth,
        expiryYear,
        notes,
        sortOrder,
        archivedAt,
      ];
}
