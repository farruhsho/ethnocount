import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

/// Sender-branch action: hand the cash to a courier for delivery.
/// Transitions `toDelivery` → `withCourier`.
class DispatchToCourierUseCase {
  final TransferRepository _repository;

  DispatchToCourierUseCase(this._repository);

  Future<Either<Failure, void>> call({
    required String transferId,
    String? courierName,
    String? courierPhone,
  }) {
    return _repository.dispatchToCourier(
      transferId: transferId,
      courierName: courierName,
      courierPhone: courierPhone,
    );
  }
}
