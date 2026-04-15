import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Supabase data source for branches and branch accounts.
class BranchRemoteDataSource {
  final SupabaseClient _client;

  BranchRemoteDataSource(this._client);

  /// Stream of all active branches.
  Stream<List<Branch>> watchBranches() {
    // Initial fetch + real-time updates via Supabase Realtime
    final controller = StreamController<List<Branch>>.broadcast();
    
    // Fetch initial data
    _fetchBranches().then((branches) {
      if (!controller.isClosed) controller.add(branches);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    // Subscribe to changes
    final channel = _client
        .channel('branches_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'branches',
          callback: (payload) {
            _fetchBranches().then((branches) {
              if (!controller.isClosed) controller.add(branches);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<Branch>> _fetchBranches() async {
    final data = await _client
        .from('branches')
        .select()
        .eq('is_active', true)
        .order('name');
    return (data as List).map((m) => _mapBranch(m)).toList();
  }

  /// Get a single branch.
  Future<Branch> getBranch(String branchId) async {
    final data = await _client
        .from('branches')
        .select()
        .eq('id', branchId)
        .single();
    return _mapBranch(data);
  }

  /// Stream of accounts for a branch.
  Stream<List<BranchAccount>> watchBranchAccounts(String branchId) {
    final controller = StreamController<List<BranchAccount>>.broadcast();

    _fetchBranchAccounts(branchId).then((accounts) {
      if (!controller.isClosed) controller.add(accounts);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('branch_accounts_$branchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'branch_accounts',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'branch_id',
            value: branchId,
          ),
          callback: (payload) {
            _fetchBranchAccounts(branchId).then((accounts) {
              if (!controller.isClosed) controller.add(accounts);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<BranchAccount>> _fetchBranchAccounts(String branchId) async {
    final data = await _client
        .from('branch_accounts')
        .select()
        .eq('branch_id', branchId)
        .eq('is_active', true)
        .order('name');
    return (data as List).map((m) => _mapBranchAccount(m)).toList();
  }

  /// Get a single branch account.
  Future<BranchAccount> getBranchAccount(String accountId) async {
    final data = await _client
        .from('branch_accounts')
        .select()
        .eq('id', accountId)
        .single();
    return _mapBranchAccount(data);
  }

  /// Update a branch.
  Future<void> updateBranch({
    required String branchId,
    String? name,
    String? code,
    String? baseCurrency,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (code != null) data['code'] = code;
    if (baseCurrency != null) data['base_currency'] = baseCurrency;
    if (data.isEmpty) return;
    await _client.from('branches').update(data).eq('id', branchId);
  }

  /// Create a branch document.
  Future<String> createBranch({
    required String name,
    required String code,
    required String baseCurrency,
  }) async {
    final data = await _client.from('branches').insert({
      'name': name,
      'code': code,
      'base_currency': baseCurrency,
      'is_active': true,
    }).select('id').single();
    return data['id'] as String;
  }

  /// Create a branch account and its initial balance record.
  Future<String> createBranchAccount({
    required String branchId,
    required String name,
    required AccountType type,
    required String currency,
  }) async {
    final data = await _client.from('branch_accounts').insert({
      'branch_id': branchId,
      'name': name,
      'type': type.name,
      'currency': currency,
      'is_active': true,
    }).select('id').single();

    final accountId = data['id'] as String;

    await _client.from('account_balances').insert({
      'account_id': accountId,
      'branch_id': branchId,
      'balance': 0.0,
      'currency': currency,
    });

    return accountId;
  }

  /// Update a branch account.
  Future<void> updateBranchAccount({
    required String accountId,
    String? name,
    AccountType? type,
    String? currency,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (type != null) data['type'] = type.name;
    if (currency != null) data['currency'] = currency;
    if (data.isEmpty) return;
    await _client.from('branch_accounts').update(data).eq('id', accountId);
    if (currency != null) {
      await _client.from('account_balances').update({
        'currency': currency,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('account_id', accountId);
    }
  }

  Branch _mapBranch(Map<String, dynamic> data) {
    return Branch(
      id: data['id'] ?? '',
      name: data['name'] ?? '',
      code: data['code'] ?? '',
      baseCurrency: data['base_currency'] ?? 'USD',
      isActive: data['is_active'] ?? true,
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  BranchAccount _mapBranchAccount(Map<String, dynamic> data) {
    return BranchAccount(
      id: data['id'] ?? '',
      branchId: data['branch_id'] ?? '',
      name: data['name'] ?? '',
      type: AccountType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => AccountType.cash,
      ),
      currency: data['currency'] ?? 'USD',
      isActive: data['is_active'] ?? true,
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
