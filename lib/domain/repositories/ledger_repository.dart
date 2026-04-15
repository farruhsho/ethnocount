import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/ledger_entry.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Repository for ledger operations.
/// The ledger is the single source of truth for all balances.
abstract class LedgerRepository {
  /// Stream of ledger entries for a branch, optionally filtered by account.
  Stream<List<LedgerEntry>> watchLedgerEntries({
    required String branchId,
    String? accountId,
    LedgerReferenceType? referenceTypeFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
    Object? startAfter,
  });

  /// Get the cached balance for an account from accountBalances (O(1)).
  Future<Either<Failure, double>> getAccountBalance(String accountId);

  /// Get cached balances for all accounts of a branch.
  Future<Either<Failure, Map<String, double>>> getBranchBalances(
      String branchId);

  /// Stream of all account balances for real-time dashboard.
  Stream<Map<String, double>> watchAccountBalances();

  /// Get a single ledger entry.
  Future<Either<Failure, LedgerEntry>> getLedgerEntry(String entryId);
}
