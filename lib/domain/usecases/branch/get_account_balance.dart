import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/ledger_repository.dart';

/// Get the computed balance for a specific account from ledger entries.
class GetAccountBalanceUseCase {
  final LedgerRepository _repository;

  GetAccountBalanceUseCase(this._repository);

  Future<Either<Failure, double>> call(String accountId) {
    return _repository.getAccountBalance(accountId);
  }
}
