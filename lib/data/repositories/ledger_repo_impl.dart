import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';
import 'package:ethnocount/domain/entities/ledger_entry.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/ledger_repository.dart';

class LedgerRepoImpl implements LedgerRepository {
  final LedgerRemoteDataSource _remoteDs;

  LedgerRepoImpl(this._remoteDs);

  @override
  Stream<List<LedgerEntry>> watchLedgerEntries({
    required String branchId,
    String? accountId,
    LedgerReferenceType? referenceTypeFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
    Object? startAfter,
  }) {
    return _remoteDs.watchLedgerEntries(
      branchId: branchId,
      accountId: accountId,
      referenceTypeFilter: referenceTypeFilter,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );
  }

  @override
  Future<Either<Failure, double>> getAccountBalance(
      String accountId) async {
    try {
      final balance = await _remoteDs.getCachedAccountBalance(accountId);
      return Right(balance);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Map<String, double>>> getBranchBalances(
      String branchId) async {
    try {
      final balances = await _remoteDs.getCachedBranchBalances(branchId);
      return Right(balances);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Stream<Map<String, double>> watchAccountBalances() {
    return _remoteDs.watchAccountBalances();
  }

  @override
  Future<Either<Failure, LedgerEntry>> getLedgerEntry(
      String entryId) async {
    try {
      final entry = await _remoteDs.getLedgerEntry(entryId);
      return Right(entry);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }
}
