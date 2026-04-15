import 'package:equatable/equatable.dart';

/// A soft-deleted transfer record for financial auditing.
/// Stored in the `deleted_transactions` Firestore collection.
class DeletedTransaction extends Equatable {
  final String id;

  /// Original transfer document ID.
  final String originalTransferId;

  /// Human-readable transfer code (e.g. ELX-2026-000042).
  final String? transactionCode;

  final double amount;
  final String currency;
  final String fromBranchId;
  final String toBranchId;

  /// UID of the accountant who originally created the transfer.
  final String createdByUserId;

  /// Display name of the accountant who originally created the transfer.
  final String? createdByUserName;

  /// UID of the user who deleted the transfer.
  final String deletedByUserId;

  /// Display name of the user who deleted the transfer.
  final String? deletedByUserName;

  /// Why the transfer was deleted.
  final String? reason;

  /// When the transfer was deleted.
  final DateTime deletedAt;

  /// When the original transfer was created.
  final DateTime? originalCreatedAt;

  /// Full snapshot of the original transfer data for audit trail.
  final Map<String, dynamic> originalData;

  const DeletedTransaction({
    required this.id,
    required this.originalTransferId,
    this.transactionCode,
    required this.amount,
    required this.currency,
    required this.fromBranchId,
    required this.toBranchId,
    required this.createdByUserId,
    this.createdByUserName,
    required this.deletedByUserId,
    this.deletedByUserName,
    this.reason,
    required this.deletedAt,
    this.originalCreatedAt,
    this.originalData = const {},
  });

  @override
  List<Object?> get props => [
        id,
        originalTransferId,
        amount,
        currency,
        deletedByUserId,
        deletedAt,
      ];
}
