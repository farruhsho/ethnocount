import 'package:equatable/equatable.dart';

/// System audit log entry for all financial and admin actions.
class AuditLog extends Equatable {
  final String id;
  final String action;
  final String entityType;
  final String entityId;
  final String performedBy;
  final Map<String, dynamic> details;
  final String? ipAddress;
  final DateTime createdAt;

  const AuditLog({
    required this.id,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.performedBy,
    this.details = const {},
    this.ipAddress,
    required this.createdAt,
  });

  @override
  List<Object?> get props =>
      [id, action, entityType, entityId, performedBy, createdAt];
}
