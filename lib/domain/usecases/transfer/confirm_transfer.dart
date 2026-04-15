import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Confirm receipt of an incoming inter-branch transfer.
class ConfirmTransferUseCase {
  final TransferRepository _repository;

  ConfirmTransferUseCase(this._repository);

  Future<Either<Failure, void>> call({
    required String transferId,
    String? toAccountId,
    List<MapEntry<String, double>>? toAccountSplits,
  }) {
    return _repository.confirmTransfer(
      transferId: transferId,
      toAccountId: toAccountId,
      toAccountSplits: toAccountSplits,
    );
  }
}
