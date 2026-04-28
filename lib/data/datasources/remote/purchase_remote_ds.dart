import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/purchase.dart';

/// Supabase data source for purchases.
/// All atomic operations go through PostgreSQL RPC functions.
class PurchaseRemoteDataSource {
  final SupabaseClient _client;

  PurchaseRemoteDataSource(this._client);

  /// Stream of purchases with optional filters.
  Stream<List<Purchase>> watchPurchases({
    String? branchId,
    String? clientId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) {
    final controller = StreamController<List<Purchase>>.broadcast();

    _fetchPurchases(
      branchId: branchId,
      clientId: clientId,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    ).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('purchases_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'purchases',
          callback: (payload) {
            _fetchPurchases(
              branchId: branchId,
              clientId: clientId,
              startDate: startDate,
              endDate: endDate,
              limit: limit,
            ).then((list) {
              if (!controller.isClosed) controller.add(list);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<Purchase>> _fetchPurchases({
    String? branchId,
    String? clientId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) async {
    var query = _client.from('purchases').select();
    if (branchId != null) query = query.eq('branch_id', branchId);
    if (clientId != null) query = query.eq('client_id', clientId);
    if (startDate != null) query = query.gte('created_at', startDate.toIso8601String());
    if (endDate != null) query = query.lte('created_at', endDate.toIso8601String());
    final data = await query.order('created_at', ascending: false).limit(limit);
    return (data as List).map((m) => _mapPurchase(m)).toList();
  }

  /// Create a purchase via PostgreSQL RPC (atomic).
  Future<Map<String, dynamic>> createPurchase({
    required String branchId,
    String? clientId,
    String? clientName,
    required String description,
    String? category,
    required double totalAmount,
    required String currency,
    required List<Map<String, dynamic>> payments,
  }) async {
    // Convert payments to JSONB-compatible format
    final paymentsJson = payments.map((p) {
      final amt = (p['amount'] as num?)?.toDouble() ?? 0;
      return {
        'accountId': p['accountId'],
        'accountName': p['accountName'],
        'amount': amt,
        'currency': p['currency'] ?? currency,
        if (p['accountType'] != null) 'accountType': p['accountType'],
      };
    }).toList();

    final result = await _client.rpc('create_purchase', params: {
      'p_branch_id': branchId,
      'p_description': description.trim(),
      'p_total_amount': totalAmount,
      'p_currency': currency,
      'p_payments': paymentsJson,
      'p_client_id': clientId,
      'p_client_name': clientName,
      'p_category': category?.trim(),
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Update purchase via PostgreSQL RPC (atomic reverse + reapply).
  Future<void> updatePurchase({
    required String purchaseId,
    String? description,
    String? category,
    double? totalAmount,
    List<Map<String, dynamic>>? payments,
  }) async {
    await _client.rpc('update_purchase', params: {
      'p_purchase_id': purchaseId,
      'p_total_amount': totalAmount,
      'p_payments': payments,
      'p_description': description,
      'p_category': category,
    });
  }

  /// Soft-delete via PostgreSQL RPC (atomic refund + snapshot + delete).
  Future<void> deletePurchase({
    required String purchaseId,
    String? reason,
  }) async {
    await _client.rpc('delete_purchase', params: {
      'p_purchase_id': purchaseId,
      'p_reason': reason,
    });
  }

  Purchase _mapPurchase(Map<String, dynamic> data) {
    final rawPayments = (data['payments'] as List?) ?? [];

    return Purchase(
      id: data['id'] ?? '',
      transactionCode: data['transaction_code'] ?? '',
      branchId: data['branch_id'] ?? '',
      clientId: data['client_id'],
      clientName: data['client_name'],
      description: data['description'] ?? '',
      category: data['category'],
      totalAmount: (data['total_amount'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'USD',
      payments: rawPayments
          .map((e) => PurchasePayment.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      createdBy: data['created_by'] ?? '',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
