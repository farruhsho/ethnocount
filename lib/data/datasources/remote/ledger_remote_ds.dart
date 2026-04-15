import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/bank_transaction.dart';
import 'package:ethnocount/domain/entities/commission.dart';
import 'package:ethnocount/domain/entities/ledger_entry.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Supabase data source for ledger entries.
class LedgerRemoteDataSource {
  final SupabaseClient _client;

  LedgerRemoteDataSource(this._client);

  /// Stream of ledger entries for a branch.
  Stream<List<LedgerEntry>> watchLedgerEntries({
    required String branchId,
    String? accountId,
    LedgerReferenceType? referenceTypeFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) {
    final controller = StreamController<List<LedgerEntry>>.broadcast();

    _fetchLedgerEntries(
      branchId: branchId,
      accountId: accountId,
      referenceTypeFilter: referenceTypeFilter,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    ).then((entries) {
      if (!controller.isClosed) controller.add(entries);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('ledger_$branchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'ledger_entries',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'branch_id',
            value: branchId,
          ),
          callback: (payload) {
            _fetchLedgerEntries(
              branchId: branchId,
              accountId: accountId,
              referenceTypeFilter: referenceTypeFilter,
              startDate: startDate,
              endDate: endDate,
              limit: limit,
            ).then((entries) {
              if (!controller.isClosed) controller.add(entries);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<LedgerEntry>> _fetchLedgerEntries({
    required String branchId,
    String? accountId,
    LedgerReferenceType? referenceTypeFilter,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    var query = _client.from('ledger_entries').select().eq('branch_id', branchId);
    if (accountId != null) {
      query = query.eq('account_id', accountId);
    }
    if (referenceTypeFilter != null) {
      query = query.eq('reference_type', referenceTypeFilter.name);
    }
    if (startDate != null) {
      query = query.gte('created_at', startDate.toIso8601String());
    }
    if (endDate != null) {
      query = query.lte('created_at', endDate.toIso8601String());
    }
    final data = await query
        .order('created_at', ascending: false)
        .limit(limit);
    return (data as List).map((m) => _mapLedgerEntry(m)).toList();
  }

  /// Get all ledger entries for an account (for balance computation).
  Future<List<LedgerEntry>> getEntriesForAccount(String accountId) async {
    final data = await _client
        .from('ledger_entries')
        .select()
        .eq('account_id', accountId);
    return (data as List).map((m) => _mapLedgerEntry(m)).toList();
  }

  /// Get all ledger entries for all accounts in a branch.
  Future<List<LedgerEntry>> getEntriesForBranch(String branchId) async {
    final data = await _client
        .from('ledger_entries')
        .select()
        .eq('branch_id', branchId);
    return (data as List).map((m) => _mapLedgerEntry(m)).toList();
  }

  /// Get ledger entries for export with optional date range and row limit.
  Future<List<LedgerEntry>> getEntriesForExport({
    required String branchId,
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) async {
    var query = _client.from('ledger_entries').select().eq('branch_id', branchId);
    if (startDate != null) {
      query = query.gte('created_at', startDate.toIso8601String());
    }
    if (endDate != null) {
      final end = endDate.add(const Duration(days: 1));
      query = query.lt('created_at', end.toIso8601String());
    }
    final data = await query
        .order('created_at', ascending: true)
        .limit(limit ?? 10000);
    return (data as List).map((m) => _mapLedgerEntry(m)).toList();
  }

  /// Get commissions for export with optional date range.
  Future<List<Commission>> getCommissionsForExport({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    var query = _client.from('commissions').select();
    if (startDate != null) {
      query = query.gte('created_at', startDate.toIso8601String());
    }
    if (endDate != null) {
      final end = endDate.add(const Duration(days: 1));
      query = query.lt('created_at', end.toIso8601String());
    }
    final data = await query
        .order('created_at', ascending: false)
        .limit(2000);
    return (data as List).map((m) => _mapCommission(m)).toList();
  }

  Commission _mapCommission(Map<String, dynamic> data) {
    return Commission(
      id: data['id'] ?? '',
      transferId: data['transfer_id'] ?? '',
      amount: (data['amount'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'USD',
      type: data['type'] ?? 'fixed',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  /// Read cached balance from account_balances table (O(1) read).
  Future<double> getCachedAccountBalance(String accountId) async {
    final data = await _client
        .from('account_balances')
        .select('balance')
        .eq('account_id', accountId)
        .maybeSingle();
    if (data == null) return 0.0;
    return (data['balance'] ?? 0).toDouble();
  }

  /// Read cached balances for all accounts of a branch.
  Future<Map<String, double>> getCachedBranchBalances(String branchId) async {
    final data = await _client
        .from('account_balances')
        .select()
        .eq('branch_id', branchId);
    final balances = <String, double>{};
    for (final row in data as List) {
      balances[row['account_id'] as String] = (row['balance'] ?? 0).toDouble();
    }
    return balances;
  }

  /// Stream of account balances for real-time dashboard updates.
  Stream<Map<String, double>> watchAccountBalances() {
    final controller = StreamController<Map<String, double>>.broadcast();

    _fetchAllBalances().then((b) {
      if (!controller.isClosed) controller.add(b);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('account_balances_all')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'account_balances',
          callback: (payload) {
            _fetchAllBalances().then((b) {
              if (!controller.isClosed) controller.add(b);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<Map<String, double>> _fetchAllBalances() async {
    final data = await _client.from('account_balances').select();
    final balances = <String, double>{};
    for (final row in data as List) {
      balances[row['account_id'] as String] = (row['balance'] ?? 0).toDouble();
    }
    return balances;
  }

  /// Get a single ledger entry.
  Future<LedgerEntry> getLedgerEntry(String entryId) async {
    final data = await _client
        .from('ledger_entries')
        .select()
        .eq('id', entryId)
        .single();
    return _mapLedgerEntry(data);
  }

  /// Create an adjustment/opening-balance ledger entry and update the balance.
  Future<void> adjustAccountBalance({
    required String branchId,
    required String accountId,
    required double amount,
    required String currency,
    required String type,
    required String referenceType,
    required String description,
    required String createdBy,
  }) async {
    // Create ledger entry
    await _client.from('ledger_entries').insert({
      'branch_id': branchId,
      'account_id': accountId,
      'type': type,
      'amount': amount,
      'currency': currency,
      'reference_type': referenceType,
      'reference_id': '',
      'description': description,
      'created_by': createdBy,
    });

    // Update balance
    final delta = type == 'credit' ? amount : -amount;
    final balData = await _client
        .from('account_balances')
        .select('balance')
        .eq('account_id', accountId)
        .maybeSingle();
    final current = balData != null ? (balData['balance'] ?? 0).toDouble() : 0.0;

    await _client.from('account_balances').upsert({
      'account_id': accountId,
      'branch_id': branchId,
      'balance': current + delta,
      'currency': currency,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Stream of balances for all accounts of a specific branch.
  Stream<Map<String, double>> watchBranchBalances(String branchId) {
    final controller = StreamController<Map<String, double>>.broadcast();

    _fetchBranchBalances(branchId).then((b) {
      if (!controller.isClosed) controller.add(b);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('balances_$branchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'account_balances',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'branch_id',
            value: branchId,
          ),
          callback: (payload) {
            _fetchBranchBalances(branchId).then((b) {
              if (!controller.isClosed) controller.add(b);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<Map<String, double>> _fetchBranchBalances(String branchId) async {
    final data = await _client
        .from('account_balances')
        .select()
        .eq('branch_id', branchId);
    final balances = <String, double>{};
    for (final row in data as List) {
      balances[row['account_id'] as String] = (row['balance'] ?? 0).toDouble();
    }
    return balances;
  }

  /// Import bank transactions as ledger entries.
  Future<int> importBankTransactions({
    required String branchId,
    required String accountId,
    required List<BankTransaction> transactions,
    required String createdBy,
    String? categoryPrefix,
  }) async {
    var count = 0;
    for (final tx in transactions) {
      final type = tx.isCredit ? 'credit' : 'debit';
      var desc = tx.description;
      if (categoryPrefix != null && categoryPrefix.isNotEmpty) {
        desc = '[$categoryPrefix] $desc';
      }
      if (tx.counterpartyRaw != null && tx.counterpartyRaw!.isNotEmpty) {
        desc = '$desc (${tx.counterpartyRaw})';
      }
      await adjustAccountBalance(
        branchId: branchId,
        accountId: accountId,
        amount: tx.amount,
        currency: tx.currency,
        type: type,
        referenceType: 'bankImport',
        description: desc,
        createdBy: createdBy,
      );
      count++;
    }
    return count;
  }

  LedgerEntry _mapLedgerEntry(Map<String, dynamic> data) {
    return LedgerEntry(
      id: data['id'] ?? '',
      branchId: data['branch_id'] ?? '',
      accountId: data['account_id'] ?? '',
      type: LedgerEntryType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => LedgerEntryType.debit,
      ),
      amount: (data['amount'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'USD',
      referenceType: LedgerReferenceType.values.firstWhere(
        (e) => e.name == data['reference_type'],
        orElse: () => LedgerReferenceType.adjustment,
      ),
      referenceId: data['reference_id'] ?? '',
      description: data['description'] ?? '',
      createdBy: data['created_by'] ?? '',
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
