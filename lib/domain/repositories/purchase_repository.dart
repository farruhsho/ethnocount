import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/purchase.dart';

abstract class PurchaseRepository {
  Stream<List<Purchase>> watchPurchases({
    String? branchId,
    String? clientId,
    DateTime? startDate,
    DateTime? endDate,
    int limit,
  });

  Future<Either<Failure, String>> createPurchase({
    required String branchId,
    String? clientId,
    String? clientName,
    required String description,
    String? category,
    required double totalAmount,
    required String currency,
    required List<Map<String, dynamic>> payments,
  });

  Future<Either<Failure, void>> updatePurchase({
    required String purchaseId,
    String? description,
    String? category,
    double? totalAmount,
    List<Map<String, dynamic>>? payments,
  });

  Future<Either<Failure, void>> deletePurchase({
    required String purchaseId,
    String? reason,
  });
}
