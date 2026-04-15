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

  /// Update purchase description, category, amount, payments.
  Future<void> updatePurchase({
    required String purchaseId,
    String? description,
    String? category,
    double? totalAmount,
    List<Map<String, dynamic>>? payments,
  }) async {
    final doc = await _client
        .from('purchases')
        .select()
        .eq('id', purchaseId)
        .single();

    final oldAmount = (doc['total_amount'] ?? 0).toDouble();
    final amountChanged = totalAmount != null && (totalAmount - oldAmount).abs() > 0.01;

    if (amountChanged || payments != null) {
      // Reverse old payments and apply new ones
      final oldPayments = (doc['payments'] as List?) ?? [];
      final newPayments = payments ?? oldPayments.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final branchId = doc['branch_id'] as String;
      final code = doc['transaction_code'] as String;
      final currency = doc['currency'] as String;
      final userId = _client.auth.currentUser!.id;

      await _reverseAndReapply(
        purchaseId: purchaseId,
        branchId: branchId,
        transactionCode: code,
        oldPayments: oldPayments,
        newPayments: newPayments,
        currency: currency,
        description: description ?? doc['description'] as String,
        userId: userId,
      );
    }

    final updateData = <String, dynamic>{};
    if (description != null) updateData['description'] = description;
    if (category != null) updateData['category'] = category.trim().isEmpty ? null : category.trim();
    if (totalAmount != null) updateData['total_amount'] = totalAmount;
    if (payments != null) updateData['payments'] = payments;
    if (updateData.isNotEmpty) {
      await _client.from('purchases').update(updateData).eq('id', purchaseId);
    }
  }

  Future<void> _reverseAndReapply({
    required String purchaseId,
    required String branchId,
    required String transactionCode,
    required List oldPayments,
    required List<Map<String, dynamic>> newPayments,
    required String currency,
    required String description,
    required String userId,
  }) async {
    // Reverse old
    for (final p in oldPayments) {
      final m = Map<String, dynamic>.from(p as Map);
      final accountId = m['accountId'] as String?;
      if (accountId == null) continue;
      final amount = (m['amount'] as num?)?.toDouble() ?? 0;

      final balData = await _client
          .from('account_balances')
          .select('balance, branch_id')
          .eq('account_id', accountId)
          .single();
      final current = (balData['balance'] ?? 0).toDouble();

      await _client.from('account_balances').update({
        'balance': current + amount,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('account_id', accountId);

      await _client.from('ledger_entries').insert({
        'branch_id': branchId,
        'account_id': accountId,
        'type': 'credit',
        'amount': amount,
        'currency': m['currency'] ?? currency,
        'reference_type': 'purchase',
        'reference_id': purchaseId,
        'transaction_code': transactionCode,
        'description': 'Сторно: $transactionCode',
        'created_by': userId,
      });
    }

    // Apply new
    for (final p in newPayments) {
      final accountId = p['accountId'] as String?;
      if (accountId == null) continue;
      final amount = (p['amount'] as num?)?.toDouble() ?? 0;

      final balData = await _client
          .from('account_balances')
          .select('balance, branch_id, currency')
          .eq('account_id', accountId)
          .single();
      final current = (balData['balance'] ?? 0).toDouble();
      if (current < amount) throw Exception('Недостаточно средств на счёте');

      await _client.from('account_balances').update({
        'balance': current - amount,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('account_id', accountId);

      await _client.from('ledger_entries').insert({
        'branch_id': balData['branch_id'] ?? branchId,
        'account_id': accountId,
        'type': 'debit',
        'amount': amount,
        'currency': balData['currency'] ?? currency,
        'reference_type': 'purchase',
        'reference_id': purchaseId,
        'transaction_code': transactionCode,
        'description': 'Покупка $transactionCode: $description',
        'created_by': userId,
      });
    }
  }

  /// Soft-delete: save to deleted_purchases, reverse ledger, remove from purchases.
  Future<void> deletePurchase({
    required String purchaseId,
    String? reason,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final doc = await _client.from('purchases').select().eq('id', purchaseId).single();
    final payments = (doc['payments'] as List?) ?? [];
    final branchId = doc['branch_id'] as String;
    final code = doc['transaction_code'] as String;
    final currency = doc['currency'] as String;

    final userDoc = await _client.from('users').select('display_name').eq('id', userId).maybeSingle();
    final deletedByName = userDoc?['display_name'] as String?;

    // Save to deleted_purchases
    await _client.from('deleted_purchases').insert({
      'original_purchase_id': purchaseId,
      'transaction_code': code,
      'branch_id': branchId,
      'client_id': doc['client_id'],
      'client_name': doc['client_name'],
      'description': doc['description'],
      'category': doc['category'],
      'total_amount': doc['total_amount'],
      'currency': currency,
      'payments': doc['payments'],
      'created_by_user_id': doc['created_by'],
      'original_created_at': doc['created_at'],
      'deleted_by_user_id': userId,
      'deleted_by_user_name': deletedByName,
      'reason': reason,
      'original_data': doc,
    });

    // Reverse ledger
    for (final p in payments) {
      final m = Map<String, dynamic>.from(p as Map);
      final accountId = m['accountId'] as String?;
      if (accountId == null) continue;
      final amount = (m['amount'] as num?)?.toDouble() ?? 0;

      final balData = await _client
          .from('account_balances')
          .select('balance, branch_id')
          .eq('account_id', accountId)
          .single();
      final current = (balData['balance'] ?? 0).toDouble();

      await _client.from('account_balances').update({
        'balance': current + amount,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('account_id', accountId);

      await _client.from('ledger_entries').insert({
        'branch_id': branchId,
        'account_id': accountId,
        'type': 'credit',
        'amount': amount,
        'currency': m['currency'] ?? currency,
        'reference_type': 'purchase',
        'reference_id': purchaseId,
        'transaction_code': code,
        'description': 'Сторно (удаление): $code',
        'created_by': userId,
      });
    }

    // Delete original
    await _client.from('purchases').delete().eq('id', purchaseId);
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
