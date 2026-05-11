import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/approval_request.dart';

/// Supabase data source for the pending_approvals workflow.
///
/// Реализует realtime-стрим + три RPC: request, approve, reject.
class ApprovalRemoteDataSource {
  final SupabaseClient _client;
  ApprovalRemoteDataSource(this._client);

  Stream<List<ApprovalRequest>> watch({ApprovalStatus? status}) {
    final controller = StreamController<List<ApprovalRequest>>.broadcast();

    Future<void> push() async {
      try {
        final list = await fetch(status: status);
        if (!controller.isClosed) controller.add(list);
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      }
    }

    push();

    final channel = _client
        .channel('pending_approvals_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'pending_approvals',
          callback: (_) => push(),
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<ApprovalRequest>> fetch({ApprovalStatus? status}) async {
    final query = _client.from('pending_approvals').select();
    final filtered = status == null
        ? query
        : query.eq('status', status.toWire());
    final data = await filtered.order('requested_at', ascending: false);
    return (data as List)
        .map((e) => _map(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<String> request({
    required ApprovalAction action,
    required String targetId,
    required String reason,
    Map<String, dynamic> payload = const {},
  }) async {
    final res = await _client.rpc('request_approval', params: {
      'p_action': action.toWire(),
      'p_target_id': targetId,
      'p_payload': payload,
      'p_reason': reason,
    });
    return res.toString();
  }

  Future<void> approve({required String approvalId, String? note}) async {
    await _client.rpc('approve_request', params: {
      'p_approval_id': approvalId,
      'p_note': note,
    });
  }

  Future<void> reject({required String approvalId, String? note}) async {
    await _client.rpc('reject_request', params: {
      'p_approval_id': approvalId,
      'p_note': note,
    });
  }

  ApprovalRequest _map(Map<String, dynamic> m) {
    return ApprovalRequest(
      id: m['id'].toString(),
      action: ApprovalAction.tryFromWire(m['action']?.toString()) ??
          ApprovalAction.clientUpdate,
      targetId: m['target_id']?.toString() ?? '',
      payload: m['payload'] is Map
          ? Map<String, dynamic>.from(m['payload'] as Map)
          : const {},
      reason: m['reason']?.toString(),
      requestedBy: m['requested_by']?.toString() ?? '',
      requestedAt: DateTime.parse(m['requested_at'].toString()),
      status: ApprovalStatus.tryFromWire(m['status']?.toString()),
      reviewedBy: m['reviewed_by']?.toString(),
      reviewedAt: m['reviewed_at'] == null
          ? null
          : DateTime.tryParse(m['reviewed_at'].toString()),
      reviewNote: m['review_note']?.toString(),
      executionResult: m['execution_result'] is Map
          ? Map<String, dynamic>.from(m['execution_result'] as Map)
          : null,
    );
  }
}
