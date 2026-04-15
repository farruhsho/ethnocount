import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/transfer_part.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Supabase data source for transfers.
/// All atomic operations go through PostgreSQL RPC functions — no client-side
/// fallback needed (unlike the old Firestore version).
class TransferRemoteDataSource {
  final SupabaseClient _client;

  TransferRemoteDataSource(this._client);

  /// Stream of transfers with optional filters.
  Stream<List<Transfer>> watchTransfers({
    String? branchId,
    TransferStatus? statusFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
    int offset = 0,
  }) {
    final controller = StreamController<List<Transfer>>.broadcast();

    _fetchTransfers(
      branchId: branchId,
      statusFilter: statusFilter,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
      offset: offset,
    ).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('transfers_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'transfers',
          callback: (payload) {
            _fetchTransfers(
              branchId: branchId,
              statusFilter: statusFilter,
              startDate: startDate,
              endDate: endDate,
              limit: limit,
              offset: offset,
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

  Future<List<Transfer>> _fetchTransfers({
    String? branchId,
    TransferStatus? statusFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
    int offset = 0,
  }) async {
    var query = _client.from('transfers').select();
    if (branchId != null) {
      query = query.eq('from_branch_id', branchId);
    }
    if (statusFilter != null) {
      query = query.eq('status', statusFilter.name);
    }
    if (startDate != null) {
      query = query.gte('created_at', startDate.toIso8601String());
    }
    if (endDate != null) {
      query = query.lte('created_at', endDate.toIso8601String());
    }
    final data = await query
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return (data as List).map((m) => _mapTransfer(m)).toList();
  }

  /// Get transfers for export.
  Future<List<Transfer>> getTransfersForExport({
    String? branchId,
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) async {
    final effectiveLimit = limit ?? 10000;
    var query = _client.from('transfers').select();
    if (branchId != null) {
      query = query.eq('from_branch_id', branchId);
    }
    if (startDate != null) {
      query = query.gte('created_at', startDate.toIso8601String());
    }
    if (endDate != null) {
      final end = endDate.add(const Duration(days: 1));
      query = query.lt('created_at', end.toIso8601String());
    }
    final data = await query
        .order('created_at', ascending: false)
        .limit(effectiveLimit);
    return (data as List).map((m) => _mapTransfer(m)).toList();
  }

  /// Get a single transfer.
  Future<Transfer> getTransfer(String transferId) async {
    final data = await _client
        .from('transfers')
        .select()
        .eq('id', transferId)
        .single();
    return _mapTransfer(data);
  }

  /// Create transfer via PostgreSQL RPC (atomic).
  Future<Map<String, dynamic>> createTransfer({
    required String fromBranchId,
    required String toBranchId,
    required String fromAccountId,
    String? toAccountId,
    String? toCurrency,
    required double amount,
    required String currency,
    required double exchangeRate,
    required String commissionType,
    required double commissionValue,
    required String commissionCurrency,
    String commissionMode = 'fromSender',
    required String idempotencyKey,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
  }) async {
    final result = await _client.rpc('create_transfer', params: {
      'p_from_branch_id': fromBranchId,
      'p_to_branch_id': toBranchId,
      'p_from_account_id': fromAccountId,
      'p_to_account_id': toAccountId ?? '',
      'p_to_currency': toCurrency,
      'p_amount': amount,
      'p_currency': currency,
      'p_exchange_rate': exchangeRate,
      'p_commission_type': commissionType,
      'p_commission_value': commissionValue,
      'p_commission_currency': commissionCurrency,
      'p_commission_mode': commissionMode,
      'p_idempotency_key': idempotencyKey,
      'p_description': description,
      'p_client_id': clientId,
      'p_sender_name': senderName,
      'p_sender_phone': senderPhone,
      'p_sender_info': senderInfo,
      'p_receiver_name': receiverName,
      'p_receiver_phone': receiverPhone,
      'p_receiver_info': receiverInfo,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Confirm transfer via PostgreSQL RPC.
  Future<Map<String, dynamic>> confirmTransfer(
    String transferId, {
    String? toAccountId,
    List<MapEntry<String, double>>? toAccountSplits,
  }) async {
    // For split confirmation, we handle one account at a time
    // (simple path — full split support can be added to the SQL function)
    final result = await _client.rpc('confirm_transfer', params: {
      'p_transfer_id': transferId,
      'p_to_account_id': toAccountId,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Reject transfer via PostgreSQL RPC.
  Future<Map<String, dynamic>> rejectTransfer(
    String transferId,
    String reason,
  ) async {
    final result = await _client.rpc('reject_transfer', params: {
      'p_transfer_id': transferId,
      'p_reason': reason,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Issue transfer via PostgreSQL RPC.
  Future<Map<String, dynamic>> issueTransfer(String transferId) async {
    final result = await _client.rpc('issue_transfer', params: {
      'p_transfer_id': transferId,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Cancel transfer.
  Future<Map<String, dynamic>> cancelTransfer(String transferId) async {
    await _client.from('transfers').update({
      'status': 'cancelled',
    }).eq('id', transferId);
    return {'success': true};
  }

  /// Update transfer metadata and/or amount (pending only).
  Future<void> updateTransfer({
    required String transferId,
    double? amount,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
    String? toAccountId,
    String? toCurrency,
    double? exchangeRate,
    String? amendmentNote,
  }) async {
    final data = await _client
        .from('transfers')
        .select()
        .eq('id', transferId)
        .single();

    final status = data['status'] as String? ?? 'pending';
    final isConfirmedOrIssued = status == 'confirmed' || status == 'issued';
    if (isConfirmedOrIssued && amount != null) {
      throw Exception('Сумму принятого/выданного перевода изменить нельзя');
    }

    final updateData = <String, dynamic>{};
    final userId = _client.auth.currentUser?.id;

    if (!isConfirmedOrIssued) {
      if (amount != null) {
        final commissionType = data['commission_type'] as String? ?? 'fixed';
        final commissionValue = (data['commission_value'] ?? 0).toDouble();
        final commissionMode = data['commission_mode'] as String? ?? 'fromSender';
        final oldAmount = (data['amount'] ?? 0).toDouble();
        final oldCommission = (data['commission'] ?? 0).toDouble();
        final oldTotal = commissionMode == 'fromSender' ? oldAmount + oldCommission : oldAmount;

        final newCommission = commissionType == 'percentage'
            ? (amount * commissionValue / 100)
            : commissionValue;
        final newTotal = commissionMode == 'fromSender' ? amount + newCommission : amount;

        if ((amount - oldAmount).abs() > 0.01) {
          // Adjust balance
          final fromAccountId = data['from_account_id'] as String;
          final balData = await _client
              .from('account_balances')
              .select('balance')
              .eq('account_id', fromAccountId)
              .single();
          final current = (balData['balance'] ?? 0).toDouble();
          final adjusted = current + oldTotal - newTotal;
          if (adjusted < 0) throw Exception('Недостаточно средств на счёте отправителя');

          await _client.from('account_balances').update({
            'balance': adjusted,
            'updated_at': DateTime.now().toIso8601String(),
          }).eq('account_id', fromAccountId);

          // Reversal + new ledger entries
          final branchId = data['from_branch_id'] as String;
          final currency = data['currency'] as String;
          final code = data['transaction_code'] as String? ?? '';

          await _client.from('ledger_entries').insert({
            'branch_id': branchId,
            'account_id': fromAccountId,
            'type': 'credit',
            'amount': oldTotal,
            'currency': currency,
            'reference_type': 'transfer',
            'reference_id': transferId,
            'transaction_code': code,
            'description': 'Сторно: $code',
            'created_by': userId,
          });
          await _client.from('ledger_entries').insert({
            'branch_id': branchId,
            'account_id': fromAccountId,
            'type': 'debit',
            'amount': newTotal,
            'currency': currency,
            'reference_type': 'transfer',
            'reference_id': transferId,
            'transaction_code': code,
            'description': 'Перевод $code (ожидает подтверждения)',
            'created_by': userId,
          });
        }
        updateData['amount'] = amount;
        updateData['commission'] = newCommission;

        // Recalculate converted_amount
        final effRate = exchangeRate ?? (data['exchange_rate'] ?? 1).toDouble();
        final effComm = newCommission;
        final receiverAmt = commissionMode == 'fromTransfer'
            ? amount - effComm
            : commissionMode == 'toReceiver'
                ? amount + effComm
                : amount;
        updateData['converted_amount'] = receiverAmt * effRate;
      }
      if (toAccountId != null) updateData['to_account_id'] = toAccountId;
      if (toCurrency != null) updateData['to_currency'] = toCurrency;
      if (exchangeRate != null) updateData['exchange_rate'] = exchangeRate;
    }

    if (description != null) updateData['description'] = description;
    if (clientId != null) updateData['client_id'] = clientId;
    if (senderName != null) updateData['sender_name'] = senderName;
    if (senderPhone != null) updateData['sender_phone'] = senderPhone;
    if (senderInfo != null) updateData['sender_info'] = senderInfo;
    if (receiverName != null) updateData['receiver_name'] = receiverName;
    if (receiverPhone != null) updateData['receiver_phone'] = receiverPhone;
    if (receiverInfo != null) updateData['receiver_info'] = receiverInfo;

    if (updateData.isNotEmpty) {
      await _client.from('transfers').update(updateData).eq('id', transferId);
    }
  }

  Transfer _mapTransfer(Map<String, dynamic> data) {
    return Transfer(
      id: data['id'] ?? '',
      transactionCode: data['transaction_code'],
      fromBranchId: data['from_branch_id'] ?? '',
      toBranchId: data['to_branch_id'] ?? '',
      fromAccountId: data['from_account_id'] ?? '',
      toAccountId: data['to_account_id'] ?? '',
      amount: (data['amount'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'USD',
      transferParts: _parseTransferParts(data['transfer_parts']),
      toCurrency: data['to_currency'],
      exchangeRate: (data['exchange_rate'] ?? 1).toDouble(),
      convertedAmount: (data['converted_amount'] ?? 0).toDouble(),
      commission: (data['commission'] ?? 0).toDouble(),
      commissionCurrency: data['commission_currency'] ?? 'USD',
      commissionType: CommissionType.values.firstWhere(
        (e) => e.name == (data['commission_type'] ?? 'fixed'),
        orElse: () => CommissionType.fixed,
      ),
      commissionValue: (data['commission_value'] ?? 0).toDouble(),
      commissionMode: CommissionMode.values.firstWhere(
        (e) => e.name == (data['commission_mode'] ?? 'fromSender'),
        orElse: () => CommissionMode.fromSender,
      ),
      description: data['description'],
      clientId: data['client_id'],
      senderName: data['sender_name'],
      senderPhone: data['sender_phone'],
      senderInfo: data['sender_info'],
      receiverName: data['receiver_name'],
      receiverPhone: data['receiver_phone'],
      receiverInfo: data['receiver_info'],
      status: TransferStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => TransferStatus.pending,
      ),
      createdBy: data['created_by'] ?? '',
      confirmedBy: data['confirmed_by'],
      issuedBy: data['issued_by'],
      rejectedBy: data['rejected_by'],
      rejectionReason: data['rejection_reason'],
      idempotencyKey: data['idempotency_key'] ?? '',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
      confirmedAt: data['confirmed_at'] != null ? DateTime.tryParse(data['confirmed_at']) : null,
      issuedAt: data['issued_at'] != null ? DateTime.tryParse(data['issued_at']) : null,
      rejectedAt: data['rejected_at'] != null ? DateTime.tryParse(data['rejected_at']) : null,
      amendmentHistory: TransferAmendmentEntry.listFromJson(data['amendment_history']),
    );
  }

  List<TransferPart>? _parseTransferParts(dynamic raw) {
    if (raw == null) return null;
    if (raw is! List) return null;
    if (raw.isEmpty) return null;
    return raw
        .map((e) => TransferPart.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
