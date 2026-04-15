import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/audit_log.dart';

/// Supabase data source for system audit logs.
class AuditRemoteDataSource {
  final SupabaseClient _client;

  AuditRemoteDataSource(this._client);

  /// Stream of audit logs.
  Stream<List<AuditLog>> watchAuditLogs({
    String? entityType,
    String? entityId,
    String? performedBy,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) {
    final controller = StreamController<List<AuditLog>>.broadcast();

    _fetchAuditLogs(
      entityType: entityType,
      entityId: entityId,
      performedBy: performedBy,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    ).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    // Audit logs don't need real-time updates, but for consistency:
    controller.onCancel = () {};

    return controller.stream;
  }

  Future<List<AuditLog>> _fetchAuditLogs({
    String? entityType,
    String? entityId,
    String? performedBy,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    var query = _client.from('audit_logs').select();
    if (entityType != null) query = query.eq('entity_type', entityType);
    if (entityId != null) query = query.eq('entity_id', entityId);
    if (performedBy != null) query = query.eq('performed_by', performedBy);
    if (startDate != null) query = query.gte('created_at', startDate.toIso8601String());
    if (endDate != null) query = query.lte('created_at', endDate.toIso8601String());
    final data = await query.order('created_at', ascending: false).limit(limit);
    return (data as List).map((e) => _mapAuditLog(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Get a single audit log entry.
  Future<AuditLog> getAuditLog(String logId) async {
    final data = await _client
        .from('audit_logs')
        .select()
        .eq('id', logId)
        .single();
    return _mapAuditLog(data);
  }

  AuditLog _mapAuditLog(Map<String, dynamic> data) {
    return AuditLog(
      id: data['id'] ?? '',
      action: data['action'] ?? '',
      entityType: data['entity_type'] ?? '',
      entityId: data['entity_id'] ?? '',
      performedBy: data['performed_by'] ?? '',
      details: Map<String, dynamic>.from(data['details'] ?? {}),
      ipAddress: data['ip_address'],
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
