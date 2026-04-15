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
  final DateTime createdAt;

  const BranchAccount({
    required this.id,
    required this.branchId,
    required this.name,
    required this.type,
    required this.currency,
    this.isActive = true,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [id, branchId, name, type, currency, isActive];
}
