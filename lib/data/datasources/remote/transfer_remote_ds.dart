import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/transfer_issuance.dart';
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
    String? query,
    int limit = 50,
    int offset = 0,
  }) {
    final controller = StreamController<List<Transfer>>.broadcast();

    _fetchTransfers(
      branchId: branchId,
      statusFilter: statusFilter,
      startDate: startDate,
      endDate: endDate,
      query: query,
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
              query: query,
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
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    var q = _client.from('transfers').select();
    if (branchId != null) {
      q = q.eq('from_branch_id', branchId);
    }
    if (statusFilter != null) {
      q = q.eq('status', statusFilter.name);
    }
    if (startDate != null) {
      q = q.gte('created_at', startDate.toIso8601String());
    }
    if (endDate != null) {
      q = q.lte('created_at', endDate.toIso8601String());
    }
    final search = query?.trim() ?? '';
    if (search.isNotEmpty) {
      final esc = search.replaceAll(',', ' ').replaceAll('%', '');
      final like = '%$esc%';
      final filters = <String>[
        'transaction_code.ilike.$like',
        'sender_name.ilike.$like',
        'sender_phone.ilike.$like',
        'sender_info.ilike.$like',
        'receiver_name.ilike.$like',
        'receiver_phone.ilike.$like',
        'receiver_info.ilike.$like',
        'description.ilike.$like',
      ];
      final asNum = double.tryParse(esc.replaceAll(' ', ''));
      if (asNum != null) {
        filters.add('amount.eq.$asNum');
        filters.add('converted_amount.eq.$asNum');
      }
      q = q.or(filters.join(','));
    }
    final data = await q
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

  /// Lookup the most recent transfer with a matching phone for either the
  /// sender or receiver side. Used by `CreateTransferPage` to autofill name
  /// and currency hints when the operator types a phone number that has
  /// already been used. Returns `null` if nothing matches or [phone] is too
  /// short to be meaningful.
  ///
  /// [side] = 'sender' looks at `sender_phone`; 'receiver' at `receiver_phone`.
  Future<TransferContactSnapshot?> findContactByPhone({
    required String phone,
    required String side,
  }) async {
    final cleaned = phone.trim();
    if (cleaned.length < 4) return null; // too short to be a real number
    final col = side == 'sender' ? 'sender_phone' : 'receiver_phone';
    final nameCol = side == 'sender' ? 'sender_name' : 'receiver_name';
    final infoCol = side == 'sender' ? 'sender_info' : 'receiver_info';

    final data = await _client
        .from('transfers')
        .select('$col, $nameCol, $infoCol, currency')
        .eq(col, cleaned)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    return TransferContactSnapshot(
      phone: cleaned,
      name: data[nameCol] as String?,
      info: data[infoCol] as String?,
      currency: data['currency'] as String?,
    );
  }

  /// Поиск контактов из истории переводов: совпадение по части телефона ИЛИ
  /// по части ФИО. Возвращает до [limit] последних уникальных контактов для
  /// выпадающего списка автозаполнения.
  ///
  /// [side] = 'sender' ищет в `sender_*`, 'receiver' — в `receiver_*`.
  Future<List<TransferContactSnapshot>> searchContacts({
    required String query,
    required String side,
    int limit = 8,
  }) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final col = side == 'sender' ? 'sender_phone' : 'receiver_phone';
    final nameCol = side == 'sender' ? 'sender_name' : 'receiver_name';
    final infoCol = side == 'sender' ? 'sender_info' : 'receiver_info';

    // Подготовка pattern:
    //  • экранируем % и _ для ilike (это wildcards в LIKE)
    //  • убираем символы, которые ломают PostgREST `.or()` синтаксис:
    //    запятая = разделитель фильтров, скобки/кавычки = маркеры. Без
    //    этой санитизации поиск по «Иванов, С.» падает на 400.
    final sanitized = q.replaceAll(RegExp(r'[,()"\\\\]'), ' ').trim();
    if (sanitized.length < 2) return const [];
    final escaped =
        sanitized.replaceAll('%', r'\%').replaceAll('_', r'\_');
    final pattern = '%$escaped%';

    // Берём с запасом, потом дедуплицируем по телефону на клиенте.
    final data = await _client
        .from('transfers')
        .select('$col, $nameCol, $infoCol, currency, created_at')
        .or('$col.ilike.$pattern,$nameCol.ilike.$pattern')
        .order('created_at', ascending: false)
        .limit(limit * 4);

    final seen = <String>{};
    final out = <TransferContactSnapshot>[];
    for (final row in (data as List)) {
      final m = Map<String, dynamic>.from(row as Map);
      final phone = (m[col] as String?)?.trim() ?? '';
      if (phone.isEmpty) continue;
      if (!seen.add(phone)) continue;
      out.add(TransferContactSnapshot(
        phone: phone,
        name: (m[nameCol] as String?)?.trim(),
        info: (m[infoCol] as String?)?.trim(),
        currency: m['currency'] as String?,
      ));
      if (out.length >= limit) break;
    }
    return out;
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
    String? commissionAccountId,
    required String idempotencyKey,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
    double? buyRate,
    double? sellRate,
    String? baseCurrency,
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
      'p_commission_account_id': commissionAccountId,
      'p_buy_rate': ?buyRate,
      'p_sell_rate': ?sellRate,
      if (baseCurrency != null && baseCurrency.isNotEmpty)
        'p_base_currency': baseCurrency,
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

  /// Mark transfer as dispatched to courier — sender branch operation.
  /// Moves status from `toDelivery` → `withCourier`.
  Future<Map<String, dynamic>> dispatchToCourier(
    String transferId, {
    String? courierName,
    String? courierPhone,
  }) async {
    final result = await _client.rpc('dispatch_transfer_to_courier', params: {
      'p_transfer_id': transferId,
      'p_courier_name': courierName,
      'p_courier_phone': courierPhone,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Issue transfer via PostgreSQL RPC (full remaining amount).
  Future<Map<String, dynamic>> issueTransfer(String transferId) async {
    final result = await _client.rpc('issue_transfer', params: {
      'p_transfer_id': transferId,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Issue a single tranche of a confirmed transfer. Pass `amount` in
  /// receiver currency. The transfer flips to `issued` only when cumulative
  /// tranches reach the credited amount.
  ///
  /// [fromAccountId] — счёт получающего филиала, с которого реально вышли
  /// деньги (карта/наличные кассы). Сохраняется в `transfer_issuances` и
  /// показывается в истории выдач.
  Future<Map<String, dynamic>> issueTransferPartial(
    String transferId,
    double amount, {
    String? note,
    String? fromAccountId,
  }) async {
    final result = await _client.rpc('issue_transfer_partial', params: {
      'p_transfer_id': transferId,
      'p_amount': amount,
      'p_note': note,
      'p_from_account_id': fromAccountId,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Fetch all payout tranches for a transfer, oldest → newest.
  Future<List<TransferIssuance>> fetchIssuances(String transferId) async {
    final data = await _client
        .from('transfer_issuances')
        .select()
        .eq('transfer_id', transferId)
        .order('issued_at', ascending: true);
    return (data as List)
        .map((m) => TransferIssuance.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
  }

  /// Realtime stream of payout tranches for a single transfer.
  Stream<List<TransferIssuance>> watchIssuances(String transferId) {
    final controller = StreamController<List<TransferIssuance>>.broadcast();

    fetchIssuances(transferId).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('transfer_issuances_$transferId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'transfer_issuances',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'transfer_id',
            value: transferId,
          ),
          callback: (_) {
            fetchIssuances(transferId).then((list) {
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

  /// Update transfer metadata and/or amount (pending only).
  /// Amount changes are routed through `update_transfer_amount` RPC for atomicity.
  /// Other metadata updates use plain REST (no balance impact).
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
    if (amount != null) {
      await _client.rpc('update_transfer_amount', params: {
        'p_transfer_id': transferId,
        'p_new_amount': amount,
        'p_new_exchange_rate': exchangeRate,
        'p_amendment_note': amendmentNote,
      });
    }

    final updateData = <String, dynamic>{};
    if (amount == null && exchangeRate != null) {
      updateData['exchange_rate'] = exchangeRate;
    }
    if (toAccountId != null) updateData['to_account_id'] = toAccountId;
    if (toCurrency != null) updateData['to_currency'] = toCurrency;
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

  /// Полная замена финансов pending (created) перевода через
  /// `replace_pending_transfer` RPC. Атомарно: refund старого debit,
  /// debit с нового счёта в новой валюте/комиссии, перерасчёт converted_amount.
  Future<Map<String, dynamic>> replacePendingTransfer({
    required String transferId,
    String? fromAccountId,
    double? amount,
    String? currency,
    String? toCurrency,
    double? exchangeRate,
    String? commissionType,
    double? commissionValue,
    String? commissionCurrency,
    String? commissionMode,
    String? toAccountId,
    String? description,
    String? clientId,
    String? senderName,
    String? senderPhone,
    String? senderInfo,
    String? receiverName,
    String? receiverPhone,
    String? receiverInfo,
    String? amendmentNote,
    String? commissionAccountId,
    double? buyRate,
    double? sellRate,
    String? baseCurrency,
  }) async {
    final result = await _client.rpc('replace_pending_transfer', params: {
      'p_transfer_id': transferId,
      'p_from_account_id': fromAccountId,
      'p_amount': amount,
      'p_currency': currency,
      'p_to_currency': toCurrency,
      'p_exchange_rate': exchangeRate,
      'p_commission_type': commissionType,
      'p_commission_value': commissionValue,
      'p_commission_currency': commissionCurrency,
      'p_commission_mode': commissionMode,
      'p_to_account_id': toAccountId,
      'p_description': description,
      'p_client_id': clientId,
      'p_sender_name': senderName,
      'p_sender_phone': senderPhone,
      'p_sender_info': senderInfo,
      'p_receiver_name': receiverName,
      'p_receiver_phone': receiverPhone,
      'p_receiver_info': receiverInfo,
      'p_amendment_note': amendmentNote,
      'p_commission_account_id': commissionAccountId,
      'p_buy_rate': ?buyRate,
      'p_sell_rate': ?sellRate,
      if (baseCurrency != null && baseCurrency.isNotEmpty)
        'p_base_currency': baseCurrency,
    });
    return Map<String, dynamic>.from(result as Map);
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
      commissionAccountId: (data['commission_account_id'] as String?)?.isEmpty == true
          ? null
          : data['commission_account_id'] as String?,
      description: data['description'],
      clientId: data['client_id'],
      senderName: data['sender_name'],
      senderPhone: data['sender_phone'],
      senderInfo: data['sender_info'],
      receiverName: data['receiver_name'],
      receiverPhone: data['receiver_phone'],
      receiverInfo: data['receiver_info'],
      status: _parseStatus(data['status']),
      createdBy: data['created_by'] ?? '',
      confirmedBy: data['confirmed_by'],
      dispatchedBy: data['dispatched_by'],
      courierName: data['courier_name'],
      courierPhone: data['courier_phone'],
      issuedBy: data['issued_by'],
      idempotencyKey: data['idempotency_key'] ?? '',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
      confirmedAt: data['confirmed_at'] != null ? DateTime.tryParse(data['confirmed_at']) : null,
      dispatchedAt: data['dispatched_at'] != null ? DateTime.tryParse(data['dispatched_at']) : null,
      issuedAt: data['issued_at'] != null ? DateTime.tryParse(data['issued_at']) : null,
      amendmentHistory: TransferAmendmentEntry.listFromJson(data['amendment_history']),
      issuedAmount: (data['issued_amount'] ?? 0).toDouble(),
      viaCounterpartyId: (data['via_counterparty_id'] as String?)?.isEmpty == true
          ? null
          : data['via_counterparty_id'] as String?,
      buyRate: (data['buy_rate'] as num?)?.toDouble(),
      sellRate: (data['sell_rate'] as num?)?.toDouble(),
      baseCurrency: data['base_currency'] as String?,
      spreadProfit: (data['spread_profit'] as num?)?.toDouble(),
    );
  }

  /// Понимает и новые, и старые имена статусов из БД.
  /// Старые `pending`, `confirmed`, `issued` маппятся на новые `created`,
  /// `toDelivery`, `delivered` пока миграция не применена везде.
  TransferStatus _parseStatus(dynamic raw) {
    final name = (raw ?? '').toString();
    switch (name) {
      case 'created':
      case 'pending':
        return TransferStatus.created;
      case 'toDelivery':
      case 'to_delivery':
      case 'confirmed':
        return TransferStatus.toDelivery;
      case 'withCourier':
      case 'with_courier':
        return TransferStatus.withCourier;
      case 'delivered':
      case 'issued':
        return TransferStatus.delivered;
      default:
        return TransferStatus.created;
    }
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

/// Lightweight snapshot returned by [TransferRemoteDataSource.findContactByPhone].
/// Used to prefill name + currency on the transfer form when an operator types
/// a previously-seen phone number.
class TransferContactSnapshot {
  const TransferContactSnapshot({
    required this.phone,
    this.name,
    this.info,
    this.currency,
  });

  final String phone;
  final String? name;
  final String? info;
  final String? currency;
}
