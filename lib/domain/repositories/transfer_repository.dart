import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Repository for inter-branch transfer operations.
abstract class TransferRepository {
  /// Stream of transfers with optional filters.
  Stream<List<Transfer>> watchTransfers({
    String? branchId,
    TransferStatus? statusFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
    Object? startAfter,
  });

  /// Get a single transfer.
  Future<Either<Failure, Transfer>> getTransfer(String transferId);

  /// Create a new inter-branch transfer (calls Cloud Function).
  /// Locks funds in sender's pending-outgoing ledger account.
  /// [toAccountId] optional — бухгалтер филиала-получателя укажет при подтверждении.
  Future<Either<Failure, Transfer>> createTransfer({
    required String fromBranchId,
    required String toBranchId,
    required String fromAccountId,
    String? toAccountId,
    String? toCurrency,
    required double amount,
    required String currency,
    required double exchangeRate,
    required String commissionType,
    required double commissionValue,
    required String commissionCurrency,
    String commissionMode = 'fromSender',
    required String idempotencyKey,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
  });

  /// Confirm receipt of a transfer (receiving branch action).
  /// Atomic: debits sender, credits receiver, records commission.
  /// [toAccountId] single account (full amount) OR [toAccountSplits] multiple accounts with amounts.
  Future<Either<Failure, void>> confirmTransfer({
    required String transferId,
    String? toAccountId,
    List<MapEntry<String, double>>? toAccountSplits,
  });

  /// Reject a transfer (receiving branch action).
  /// Atomic: unlocks funds back to sender.
  Future<Either<Failure, void>> rejectTransfer({
    required String transferId,
    required String reason,
  });

  /// Mark transfer as issued (vidan) — деньги выданы получателю.
  Future<Either<Failure, void>> issueTransfer({
    required String transferId,
  });

  /// Cancel a pending transfer (sender branch action).
  Future<Either<Failure, void>> cancelTransfer({
    required String transferId,
  });

  /// Update pending transfer: amount, sender/receiver info (Creator or canManageTransfers).
  Future<Either<Failure, void>> updateTransfer({
    required String transferId,
    double? amount,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
    String? toAccountId,
    String? toCurrency,
    double? exchangeRate,
    String? amendmentNote,
  });
}

