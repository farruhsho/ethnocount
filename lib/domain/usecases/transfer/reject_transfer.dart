import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Reject an incoming inter-branch transfer.
class RejectTransferUseCase {
  final TransferRepository _repository;

  RejectTransferUseCase(this._repository);

  Future<Either<Failure, void>> call({
    required String transferId,
    required String reason,
  }) {
    return _repository.rejectTransfer(
      transferId: transferId,
      reason: reason,
    );
  }
}
