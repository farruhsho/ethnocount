import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Supabase data source for branches and branch accounts.
///
/// All mutations go through the `public.admin_*` SECURITY DEFINER RPCs
/// introduced in migration 011. Direct table writes are blocked by RLS
/// for non-creator roles.
class BranchRemoteDataSource {
  final SupabaseClient _client;

  BranchRemoteDataSource(this._client);

  // ── Read streams ───────────────────────────────────────────────

  Stream<List<Branch>> watchBranches() {
    final controller = StreamController<List<Branch>>.broadcast();

    _fetchBranches().then((branches) {
      if (!controller.isClosed) controller.add(branches);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

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
        .order('sort_order')
        .order('name');
    return (data as List).map((m) => _mapBranch(m)).toList();
  }

  Future<Branch> getBranch(String branchId) async {
    final data = await _client
        .from('branches')
        .select()
        .eq('id', branchId)
        .single();
    return _mapBranch(data);
  }

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
        .order('sort_order')
        .order('name');
    return (data as List).map((m) => _mapBranchAccount(m)).toList();
  }

  Future<BranchAccount> getBranchAccount(String accountId) async {
    final data = await _client
        .from('branch_accounts')
        .select()
        .eq('id', accountId)
        .single();
    return _mapBranchAccount(data);
  }

  // ── Branch mutations (via admin_* RPCs) ───────────────────────

  Future<String> createBranch({
    required String name,
    required String code,
    required String baseCurrency,
    List<String>? supportedCurrencies,
    String? address,
    String? phone,
    String? notes,
    int sortOrder = 0,
  }) async {
    final result = await _client.rpc('admin_create_branch', params: {
      'p_name': name,
      'p_code': code,
      'p_base_currency': baseCurrency,
      'p_supported_currencies': supportedCurrencies,
      'p_address': address,
      'p_phone': phone,
      'p_notes': notes,
      'p_sort_order': sortOrder,
    });
    return (result as Map)['branchId'] as String;
  }

  Future<void> updateBranch({
    required String branchId,
    String? name,
    String? code,
    String? baseCurrency,
    List<String>? supportedCurrencies,
    String? address,
    String? phone,
    String? notes,
    int? sortOrder,
    String? codeChangeReason,
  }) async {
    await _client.rpc('admin_update_branch', params: {
      'p_branch_id': branchId,
      'p_name': name,
      'p_code': code,
      'p_base_currency': baseCurrency,
      'p_supported_currencies': supportedCurrencies,
      'p_address': address,
      'p_phone': phone,
      'p_notes': notes,
      'p_sort_order': sortOrder,
      'p_code_change_reason': codeChangeReason,
    });
  }

  Future<void> archiveBranch({
    required String branchId,
    required bool archive,
    String? reason,
  }) async {
    await _client.rpc('admin_archive_branch', params: {
      'p_branch_id': branchId,
      'p_archive': archive,
      'p_reason': reason,
    });
  }

  // ── Branch-account mutations (via admin_* RPCs) ───────────────

  Future<String> createBranchAccount({
    required String branchId,
    required String name,
    required AccountType type,
    required String currency,
    String? cardNumber,
    String? cardholderName,
    String? bankName,
    int? expiryMonth,
    int? expiryYear,
    String? notes,
    int sortOrder = 0,
  }) async {
    final result = await _client.rpc('admin_create_branch_account', params: {
      'p_branch_id': branchId,
      'p_name': name,
      'p_type': type.name,
      'p_currency': currency,
      'p_card_number': cardNumber,
      'p_cardholder_name': cardholderName,
      'p_bank_name': bankName,
      'p_expiry_month': expiryMonth,
      'p_expiry_year': expiryYear,
      'p_notes': notes,
      'p_sort_order': sortOrder,
    });
    return (result as Map)['accountId'] as String;
  }

  Future<void> updateBranchAccount({
    required String accountId,
    String? name,
    AccountType? type,
    String? currency,
    String? cardNumber,
    bool clearCardNumber = false,
    String? cardholderName,
    String? bankName,
    int? expiryMonth,
    int? expiryYear,
    String? notes,
    int? sortOrder,
  }) async {
    await _client.rpc('admin_update_branch_account', params: {
      'p_account_id': accountId,
      'p_name': name,
      'p_type': type?.name,
      'p_currency': currency,
      'p_card_number': cardNumber,
      'p_clear_card_number': clearCardNumber,
      'p_cardholder_name': cardholderName,
      'p_bank_name': bankName,
      'p_expiry_month': expiryMonth,
      'p_expiry_year': expiryYear,
      'p_notes': notes,
      'p_sort_order': sortOrder,
    });
  }

  Future<void> archiveBranchAccount({
    required String accountId,
    required bool archive,
  }) async {
    await _client.rpc('admin_archive_branch_account', params: {
      'p_account_id': accountId,
      'p_archive': archive,
    });
  }

  Future<void> reorderBranchAccounts({
    required String branchId,
    required List<Map<String, dynamic>> order,
  }) async {
    // order is a list of {accountId, sortOrder}
    await _client.rpc('admin_reorder_branch_accounts', params: {
      'p_branch_id': branchId,
      'p_order': order,
    });
  }

  // ── Mapping helpers ───────────────────────────────────────────

  Branch _mapBranch(Map<String, dynamic> data) {
    final rawSupported = data['supported_currencies'];
    List<String>? supported;
    if (rawSupported is List) {
      supported = rawSupported
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      if (supported.isEmpty) supported = null;
    }
    return Branch(
      id: data['id'] ?? '',
      name: data['name'] ?? '',
      code: data['code'] ?? '',
      baseCurrency: data['base_currency'] ?? 'USD',
      supportedCurrencies: supported,
      isActive: data['is_active'] ?? true,
      address: data['address'] as String?,
      phone: data['phone'] as String?,
      notes: data['notes'] as String?,
      sortOrder: (data['sort_order'] as int?) ?? 0,
      archivedAt: DateTime.tryParse(data['archived_at'] as String? ?? ''),
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
      cardNumber: data['card_number'] as String?,
      cardLast4: data['card_last4'] as String?,
      cardholderName: data['cardholder_name'] as String?,
      bankName: data['bank_name'] as String?,
      expiryMonth: (data['expiry_month'] as num?)?.toInt(),
      expiryYear: (data['expiry_year'] as num?)?.toInt(),
      notes: data['notes'] as String?,
      sortOrder: (data['sort_order'] as int?) ?? 0,
      archivedAt: DateTime.tryParse(data['archived_at'] as String? ?? ''),
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
