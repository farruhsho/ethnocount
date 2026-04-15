import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Update a pending transfer (amount, sender/receiver info).
class UpdateTransferUseCase {
  final TransferRepository _repository;

  UpdateTransferUseCase(this._repository);

  Future<Either<Failure, void>> call({
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
  }) {
    return _repository.updateTransfer(
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
  }
}
