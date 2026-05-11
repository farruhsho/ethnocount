import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/approval_request.dart';

abstract class ApprovalRepository {
  /// Поток заявок. По умолчанию только pending; для истории — pass null.
  Stream<List<ApprovalRequest>> watch({ApprovalStatus? status});

  Future<Either<Failure, String>> request({
    required ApprovalAction action,
    required String targetId,
    required String reason,
    Map<String, dynamic> payload = const {},
  });

  Future<Either<Failure, void>> approve({
    required String approvalId,
    String? note,
  });

  Future<Either<Failure, void>> reject({
    required String approvalId,
    String? note,
  });
}
