import 'package:ethnocount/domain/entities/ledger_entry.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/ledger_repository.dart';

/// Watch ledger entries for a branch/account.
class WatchLedgerUseCase {
  final LedgerRepository _repository;

  WatchLedgerUseCase(this._repository);

  Stream<List<LedgerEntry>> call({
    required String branchId,
    String? accountId,
    LedgerReferenceType? referenceTypeFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) {
    return _repository.watchLedgerEntries(
      branchId: branchId,
      accountId: accountId,
      referenceTypeFilter: referenceTypeFilter,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );
  }
}
