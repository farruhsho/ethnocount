import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/audit_log.dart';

/// Repository for system audit log operations.
abstract class AuditRepository {
  /// Stream of audit logs with optional filters.
  Stream<List<AuditLog>> watchAuditLogs({
    String? entityType,
    String? entityId,
    String? performedBy,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  });

  /// Get a single audit log entry.
  Future<Either<Failure, AuditLog>> getAuditLog(String logId);
}
