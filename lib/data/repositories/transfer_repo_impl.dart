import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/core/network/connectivity_service.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/transfer_issuance.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

class TransferRepoImpl implements TransferRepository {
  final TransferRemoteDataSource _remoteDs;
  final ConnectivityService _connectivity;

  TransferRepoImpl(this._remoteDs, this._connectivity);

  @override
  Stream<List<Transfer>> watchTransfers({
    String? branchId,
    TransferStatus? statusFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
    Object? startAfter,
  }) {
    return _remoteDs.watchTransfers(
      branchId: branchId,
      statusFilter: statusFilter,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );
  }

  @override
  Future<Either<Failure, Transfer>> getTransfer(String transferId) async {
    try {
      final transfer = await _remoteDs.getTransfer(transferId);
      return Right(transfer);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
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
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }

      final result = await _remoteDs.createTransfer(
        fromBranchId: fromBranchId,
        toBranchId: toBranchId,
        fromAccountId: fromAccountId,
        toAccountId: toAccountId,
        toCurrency: toCurrency,
        amount: amount,
        currency: currency,
        exchangeRate: exchangeRate,
        commissionType: commissionType,
        commissionValue: commissionValue,
        commissionCurrency: commissionCurrency,
        commissionMode: commissionMode,
        idempotencyKey: idempotencyKey,
        description: description,
        clientId: clientId,
        senderName: senderName,
        senderPhone: senderPhone,
        senderInfo: senderInfo,
        receiverName: receiverName,
        receiverPhone: receiverPhone,
        receiverInfo: receiverInfo,
      );

      if (result['success'] == true) {
        final transfer =
            await _remoteDs.getTransfer(result['transferId'] as String);
        return Right(transfer);
      }
      return Left(ServerFailure(
          result['error']?.toString() ?? 'Transfer creation failed'));
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('Duplicate') || msg.contains('already exists')) {
        return const Left(
            DuplicateTransferFailure('Duplicate transfer — already exists'));
      }
      if (msg.contains('Insufficient') || msg.contains('Недостаточно')) {
        return Left(InsufficientFundsFailure(msg));
      }
      return Left(UnexpectedFailure(msg));
    }
  }

  @override
  Future<Either<Failure, void>> confirmTransfer({
    required String transferId,
    String? toAccountId,
    List<MapEntry<String, double>>? toAccountSplits,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }

      final result = await _remoteDs.confirmTransfer(
        transferId,
        toAccountId: toAccountId,
        toAccountSplits: toAccountSplits,
      );
      if (result['success'] == true) {
        return const Right(null);
      }
      return Left(ServerFailure(
          result['error']?.toString() ?? 'Confirmation failed'));
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('not in pending')) {
        return const Left(TransferAlreadyConfirmedFailure());
      }
      return Left(UnexpectedFailure(msg));
    }
  }

  @override
  Future<Either<Failure, void>> issueTransfer({
    required String transferId,
  }) async {
    try {
      final result = await _remoteDs.issueTransfer(transferId);
      if (result['success'] != true) {
        return Left(ServerFailure(result['error']?.toString() ?? 'Failed to mark as issued'));
      }
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, bool>> issuePartialTransfer({
    required String transferId,
    required double amount,
    String? note,
    String? fromAccountId,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      if (amount <= 0) {
        return const Left(ServerFailure('Сумма выдачи должна быть больше нуля'));
      }
      final result = await _remoteDs.issueTransferPartial(
        transferId,
        amount,
        note: note,
        fromAccountId: fromAccountId,
      );
      if (result['success'] != true) {
        return Left(ServerFailure(
            result['error']?.toString() ?? 'Partial issue failed'));
      }
      return Right(result['fullyIssued'] == true);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Stream<List<TransferIssuance>> watchIssuances(String transferId) {
    return _remoteDs.watchIssuances(transferId);
  }

  @override
  Future<Either<Failure, void>> rejectTransfer({
    required String transferId,
    required String reason,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }

      final result = await _remoteDs.rejectTransfer(transferId, reason);
      if (result['success'] == true) {
        return const Right(null);
      }
      return Left(
          ServerFailure(result['error']?.toString() ?? 'Rejection failed'));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> cancelTransfer({
    required String transferId,
    String reason = '',
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }

      final result = await _remoteDs.cancelTransfer(transferId, reason: reason);
      if (result['success'] == true) {
        return const Right(null);
      }
      return Left(ServerFailure(
          result['error']?.toString() ?? 'Cancellation failed'));
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('Only pending') || msg.contains('not in pending')) {
        return const Left(TransferAlreadyConfirmedFailure());
      }
      return Left(UnexpectedFailure(msg));
    }
  }

  @override
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
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      await _remoteDs.updateTransfer(
        transferId: transferId,
        amount: amount,
        description: description,
        clientId: clientId,
        senderName: senderName,
        senderPhone: senderPhone,
        senderInfo: senderInfo,
        receiverName: receiverName,
        receiverPhone: receiverPhone,
        receiverInfo: receiverInfo,
        toAccountId: toAccountId,
        toCurrency: toCurrency,
        exchangeRate: exchangeRate,
        amendmentNote: amendmentNote,
      );
      return const Right(null);
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }
}
