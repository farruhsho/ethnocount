import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/data/datasources/remote/audit_remote_ds.dart';
import 'package:ethnocount/domain/entities/audit_log.dart';
import 'package:ethnocount/domain/repositories/audit_repository.dart';

class AuditRepoImpl implements AuditRepository {
  final AuditRemoteDataSource _remoteDs;

  AuditRepoImpl(this._remoteDs);

  @override
  Stream<List<AuditLog>> watchAuditLogs({
    String? entityType,
    String? entityId,
    String? performedBy,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) {
    return _remoteDs.watchAuditLogs(
      entityType: entityType,
      entityId: entityId,
      performedBy: performedBy,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );
  }

  @override
  Future<Either<Failure, AuditLog>> getAuditLog(String logId) async {
    try {
      final log = await _remoteDs.getAuditLog(logId);
      return Right(log);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }
}
