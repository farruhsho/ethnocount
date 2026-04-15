import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Mark a confirmed transfer as issued (vidan) — деньги выданы получателю.
class IssueTransferUseCase {
  final TransferRepository _repository;

  IssueTransferUseCase(this._repository);

  Future<Either<Failure, void>> call({required String transferId}) {
    return _repository.issueTransfer(transferId: transferId);
  }
}
