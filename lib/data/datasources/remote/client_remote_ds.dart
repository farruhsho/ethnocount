import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/client.dart';

/// Supabase data source for client accounts.
/// All atomic operations go through PostgreSQL RPC functions.
class ClientRemoteDataSource {
  final SupabaseClient _client;

  ClientRemoteDataSource(this._client);

  /// Stream of all active clients ordered by name.
  Stream<List<Client>> watchClients({String? search}) {
    final controller = StreamController<List<Client>>.broadcast();

    _fetchClients().then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('clients_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'clients',
          callback: (payload) {
            _fetchClients().then((list) {
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

  Future<List<Client>> _fetchClients() async {
    final data = await _client
        .from('clients')
        .select()
        .eq('is_active', true)
        .order('name');
    return (data as List).map((e) => _mapClient(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Get a single client.
  Future<Client> getClient(String clientId) async {
    final data = await _client
        .from('clients')
        .select()
        .eq('id', clientId)
        .single();
    return _mapClient(data);
  }

  /// Stream of all client balances (one row per client). Used by the
  /// clients list to show the actual balance per row instead of just the
  /// configured wallet currencies.
  Stream<List<ClientBalance>> watchAllClientBalances() {
    final controller = StreamController<List<ClientBalance>>.broadcast();

    _fetchAllClientBalances().then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('client_balances_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'client_balances',
          callback: (payload) {
            _fetchAllClientBalances().then((list) {
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

  Future<List<ClientBalance>> _fetchAllClientBalances() async {
    final data = await _client.from('client_balances').select();
    return (data as List).map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return _mapClientBalance(m['client_id'] as String? ?? '', m);
    }).toList();
  }

  ClientBalance _mapClientBalance(String clientId, Map<String, dynamic> data) {
    final primaryCur = data['currency'] as String? ?? 'USD';
    final rawBalances = data['balances'];
    var balances = <String, double>{};

    if (rawBalances is Map) {
      for (final e in rawBalances.entries) {
        final v = e.value;
        if (v is num) balances['${e.key}'] = _round(v.toDouble(), 2);
      }
    }

    final single = _round((data['balance'] as num?)?.toDouble() ?? 0.0, 2);
    if (balances.isEmpty) {
      balances = {primaryCur: single};
    } else if (!balances.containsKey(primaryCur)) {
      balances[primaryCur] = single;
    }

    return ClientBalance(
      clientId: clientId,
      balance: balances[primaryCur] ?? single,
      currency: primaryCur,
      balancesByCurrency: balances,
      updatedAt: DateTime.tryParse(data['updated_at'] ?? '') ?? DateTime.now(),
    );
  }

  /// Get client balance.
  Future<ClientBalance?> getClientBalance(String clientId) async {
    final data = await _client
        .from('client_balances')
        .select()
        .eq('client_id', clientId)
        .maybeSingle();
    if (data == null) return null;
    return _mapClientBalance(clientId, data);
  }

  /// Stream of client transactions.
  Stream<List<ClientTransaction>> watchClientTransactions(
    String clientId, {
    int limit = 50,
  }) {
    final controller = StreamController<List<ClientTransaction>>.broadcast();

    _fetchClientTransactions(clientId, limit: limit).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('client_tx_$clientId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'client_transactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'client_id',
            value: clientId,
          ),
          callback: (payload) {
            _fetchClientTransactions(clientId, limit: limit).then((list) {
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

  Future<List<ClientTransaction>> _fetchClientTransactions(
    String clientId, {
    int limit = 50,
  }) async {
    final data = await _client
        .from('client_transactions')
        .select()
        .eq('client_id', clientId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (data as List).map((e) => _mapTransaction(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Create client via PostgreSQL RPC (atomic).
  Future<Map<String, dynamic>> createClient({
    required String name,
    required String phone,
    required String country,
    required String currency,
    required String branchId,
  }) async {
    final result = await _client.rpc('create_client', params: {
      'p_name': name,
      'p_phone': phone,
      'p_country': country,
      'p_currency': currency,
      'p_branch_id': branchId,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Deposit to client account via PostgreSQL RPC.
  Future<Map<String, dynamic>> depositClient({
    required String clientId,
    required double amount,
    String? description,
    String? currency,
  }) async {
    final result = await _client.rpc('deposit_client', params: {
      'p_client_id': clientId,
      'p_amount': amount,
      'p_description': description ?? 'Пополнение счёта',
      'p_currency': currency,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Debit client account via PostgreSQL RPC.
  Future<Map<String, dynamic>> debitClient({
    required String clientId,
    required double amount,
    String? description,
    String? currency,
  }) async {
    final result = await _client.rpc('debit_client', params: {
      'p_client_id': clientId,
      'p_amount': amount,
      'p_description': description ?? 'Списание со счёта',
      'p_currency': currency,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  double _round(double value, int decimals) {
    final factor = _powerOfTen(decimals);
    return (value * factor).round() / factor;
  }

  double _powerOfTen(int n) {
    double r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }

  Client _mapClient(Map<String, dynamic> data) {
    final cur = data['currency'] as String? ?? 'USD';
    final wcRaw = data['wallet_currencies'];
    List<String> walletCurrencies;
    if (wcRaw is List) {
      walletCurrencies = wcRaw.map((e) => '$e').toList();
    } else {
      walletCurrencies = [cur];
    }
    return Client(
      id: data['id'] ?? '',
      clientCode: data['client_code'] ?? '',
      name: data['name'] ?? '',
      phone: data['phone'] ?? '',
      country: data['country'] ?? '',
      currency: cur,
      branchId: data['branch_id'] as String?,
      walletCurrencies: walletCurrencies,
      isActive: data['is_active'] ?? true,
      createdBy: data['created_by'] ?? '',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  ClientTransaction _mapTransaction(Map<String, dynamic> data) {
    return ClientTransaction(
      id: data['id'] ?? '',
      clientId: data['client_id'] ?? '',
      type: data['type'] ?? 'deposit',
      amount: (data['amount'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'USD',
      description: data['description'],
      createdBy: data['created_by'] ?? '',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
