import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Pay out one tranche of a confirmed transfer.
/// Returns `true` if this tranche fully closed the transfer (status → issued).
class IssuePartialTransferUseCase {
  final TransferRepository _repository;

  IssuePartialTransferUseCase(this._repository);

  Future<Either<Failure, bool>> call({
    required String transferId,
    required double amount,
    String? note,
    String? fromAccountId,
  }) {
    return _repository.issuePartialTransfer(
      transferId: transferId,
      amount: amount,
      note: note,
      fromAccountId: fromAccountId,
    );
  }
}
