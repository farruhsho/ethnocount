import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Watch transfers stream with optional filters.
class WatchTransfersUseCase {
  final TransferRepository _repository;

  WatchTransfersUseCase(this._repository);

  Stream<List<Transfer>> call({
    String? branchId,
    TransferStatus? statusFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
    Object? startAfter,
  }) {
    return _repository.watchTransfers(
      branchId: branchId,
      statusFilter: statusFilter,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
      startAfter: startAfter,
    );
  }
}
