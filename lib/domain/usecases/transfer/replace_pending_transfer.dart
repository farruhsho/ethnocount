import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Полное редактирование pending (created) перевода — все финансовые
/// и метаданные поля одновременно, как при создании.
class ReplacePendingTransferUseCase {
  final TransferRepository _repository;

  ReplacePendingTransferUseCase(this._repository);

  Future<Either<Failure, void>> call({
    required String transferId,
    String? fromAccountId,
    double? amount,
    String? currency,
    String? toCurrency,
    double? exchangeRate,
    String? commissionType,
    double? commissionValue,
    String? commissionCurrency,
    String? commissionMode,
    String? toAccountId,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
    String? amendmentNote,
    String? commissionAccountId,
    double? buyRate,
    double? sellRate,
    String? baseCurrency,
  }) {
    return _repository.replacePendingTransfer(
      transferId: transferId,
      fromAccountId: fromAccountId,
      amount: amount,
      currency: currency,
      toCurrency: toCurrency,
      exchangeRate: exchangeRate,
      commissionType: commissionType,
      commissionValue: commissionValue,
      commissionCurrency: commissionCurrency,
      commissionMode: commissionMode,
      toAccountId: toAccountId,
      description: description,
      clientId: clientId,
      senderName: senderName,
      senderPhone: senderPhone,
      senderInfo: senderInfo,
      receiverName: receiverName,
      receiverPhone: receiverPhone,
      receiverInfo: receiverInfo,
      amendmentNote: amendmentNote,
      commissionAccountId: commissionAccountId,
      buyRate: buyRate,
      sellRate: sellRate,
      baseCurrency: baseCurrency,
    );
  }
}
