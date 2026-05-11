import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/data/datasources/remote/approval_remote_ds.dart';
import 'package:ethnocount/domain/entities/approval_request.dart';
import 'package:ethnocount/domain/repositories/approval_repository.dart';

class ApprovalRepoImpl implements ApprovalRepository {
  final ApprovalRemoteDataSource _remoteDs;

  ApprovalRepoImpl(this._remoteDs);

  @override
  Stream<List<ApprovalRequest>> watch({ApprovalStatus? status}) =>
      _remoteDs.watch(status: status);

  @override
  Future<Either<Failure, String>> request({
    required ApprovalAction action,
    required String targetId,
    required String reason,
    Map<String, dynamic> payload = const {},
  }) async {
    try {
      final id = await _remoteDs.request(
        action: action,
        targetId: targetId,
        reason: reason,
        payload: payload,
      );
      return Right(id);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> approve({
    required String approvalId,
    String? note,
  }) async {
    try {
      await _remoteDs.approve(approvalId: approvalId, note: note);
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> reject({
    required String approvalId,
    String? note,
  }) async {
    try {
      await _remoteDs.reject(approvalId: approvalId, note: note);
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }
}
