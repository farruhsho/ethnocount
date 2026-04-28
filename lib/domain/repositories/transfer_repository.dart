import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/transfer_issuance.dart';
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

  /// Mark transfer as fully issued — pays out the entire remaining balance
  /// in a single tranche. Equivalent to [issuePartialTransfer] with the
  /// outstanding amount.
  Future<Either<Failure, void>> issueTransfer({
    required String transferId,
  });

  /// Pay out one tranche of a confirmed transfer. The transfer flips to
  /// `issued` only when cumulative tranches reach the credited amount.
  /// Returns `true` if this tranche fully closed the transfer.
  Future<Either<Failure, bool>> issuePartialTransfer({
    required String transferId,
    required double amount,
    String? note,
  });

  /// Realtime stream of payout tranches for a single transfer.
  Stream<List<TransferIssuance>> watchIssuances(String transferId);

  /// Cancel a pending transfer (sender branch action).
  /// Atomic: refunds sender + writes compensating ledger credit.
  Future<Either<Failure, void>> cancelTransfer({
    required String transferId,
    String reason = '',
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

