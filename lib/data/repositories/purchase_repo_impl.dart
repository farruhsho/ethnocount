import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/core/network/callable_functions.dart';
import 'package:ethnocount/data/datasources/remote/purchase_remote_ds.dart';
import 'package:ethnocount/domain/entities/purchase.dart';
import 'package:ethnocount/domain/repositories/purchase_repository.dart';

class PurchaseRepoImpl implements PurchaseRepository {
  final PurchaseRemoteDataSource _remoteDs;

  PurchaseRepoImpl(this._remoteDs);

  @override
  Stream<List<Purchase>> watchPurchases({
    String? branchId,
    String? clientId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) =>
      _remoteDs.watchPurchases(
        branchId: branchId,
        clientId: clientId,
        startDate: startDate,
        endDate: endDate,
        limit: limit,
      );

  @override
  Future<Either<Failure, String>> createPurchase({
    required String branchId,
    String? clientId,
    String? clientName,
    required String description,
    String? category,
    required double totalAmount,
    required String currency,
    required List<Map<String, dynamic>> payments,
  }) async {
    try {
      final result = await _remoteDs.createPurchase(
        branchId: branchId,
        clientId: clientId,
        clientName: clientName,
        description: description,
        category: category,
        totalAmount: totalAmount,
        currency: currency,
        payments: payments,
      );
      if (result['success'] == true) {
        return Right(result['purchaseId'] as String);
      }
      return Left(ServerFailure(result['error']?.toString() ?? 'Failed'));
    } on CallableFunctionsException catch (e) {
      if (e.code == 'failed-precondition') {
        return Left(ServerFailure(e.message));
      }
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> updatePurchase({
    required String purchaseId,
    String? description,
    String? category,
    double? totalAmount,
    List<Map<String, dynamic>>? payments,
  }) async {
    try {
      await _remoteDs.updatePurchase(
        purchaseId: purchaseId,
        description: description,
        category: category,
        totalAmount: totalAmount,
        payments: payments,
      );
      return const Right(null);
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> deletePurchase({
    required String purchaseId,
    String? reason,
  }) async {
    try {
      await _remoteDs.deletePurchase(
        purchaseId: purchaseId,
        reason: reason,
      );
      return const Right(null);
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }
}
