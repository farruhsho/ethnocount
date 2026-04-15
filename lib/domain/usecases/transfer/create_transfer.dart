import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Create an inter-branch transfer.
class CreateTransferUseCase {
  final TransferRepository _repository;

  CreateTransferUseCase(this._repository);

  Future<Either<Failure, Transfer>> call({
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
  }) {
    return _repository.createTransfer(
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
  }
}
