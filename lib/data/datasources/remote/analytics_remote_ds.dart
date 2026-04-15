import 'package:supabase_flutter/supabase_flutter.dart';

class AnalyticsRemoteDataSource {
  final SupabaseClient _client;

  AnalyticsRemoteDataSource(this._client);

  static double _r2(num n, [int decimals = 2]) {
    final p = _pow10(decimals);
    return (n.toDouble() * p).round() / p;
  }

  static double _pow10(int d) {
    var p = 1.0;
    for (var i = 0; i < d; i++) {
      p *= 10;
    }
    return p;
  }

  Future<Map<String, dynamic>> fetchAnalytics({
    String scope = 'full',
    bool excludeCounterpartyAccounts = false,
  }) async {
    return _fetchFromSupabase(
      scope: scope,
      excludeCounterpartyAccounts: excludeCounterpartyAccounts,
    );
  }

  Future<Map<String, dynamic>> _fetchFromSupabase({
    String scope = 'full',
    bool excludeCounterpartyAccounts = false,
  }) async {
    final results = <String, dynamic>{};

    if (scope == 'full' || scope == 'branches') {
      results['branches'] = await _aggregateBranches(
        excludeCounterpartyAccounts: excludeCounterpartyAccounts,
      );
    }
    if (scope == 'full' || scope == 'transfers') {
      results['transfers'] = await _aggregateTransfers();
    }
    if (scope == 'full' || scope == 'currency') {
      results['currency'] = await _aggregateCurrency();
    }
    if (scope == 'full' || scope == 'treasury') {
      results['treasury'] = await _aggregateTreasury(
        excludeCounterpartyAccounts: excludeCounterpartyAccounts,
      );
    }

    return results;
  }

  Future<List<Map<String, dynamic>>> _aggregateBranches({
    bool excludeCounterpartyAccounts = false,
  }) async {
    final branchesData = await _client.from('branches').select();

    Set<String> transitAccountIds = {};
    if (excludeCounterpartyAccounts) {
      final transitData = await _client
          .from('branch_accounts')
          .select('id')
          .eq('type', 'transit');
      transitAccountIds = (transitData as List).map((d) => d['id'] as String).toSet();
    }

    final results = <Map<String, dynamic>>[];

    for (final bDoc in branchesData as List) {
      final branchId = bDoc['id'] as String;

      final balancesData = await _client
          .from('account_balances')
          .select()
          .eq('branch_id', branchId);

      final accounts = <String, dynamic>{};
      final balancesByCurrency = <String, double>{};
      for (final bd in balancesData as List) {
        if (excludeCounterpartyAccounts && transitAccountIds.contains(bd['account_id'])) continue;
        final cur = bd['currency'] as String? ?? 'UNK';
        final bal = _r2((bd['balance'] ?? 0).toDouble());
        accounts[bd['account_id'] as String] = {'balance': bal, 'currency': cur};
        balancesByCurrency[cur] = _r2((balancesByCurrency[cur] ?? 0) + bal);
      }

      final curKeys = balancesByCurrency.keys.toList();
      final totalBalance = curKeys.length == 1 ? balancesByCurrency[curKeys.first]! : 0.0;

      final transfersData = await _client
          .from('transfers')
          .select('status')
          .eq('from_branch_id', branchId)
          .limit(500);

      int pendingCount = 0, confirmedCount = 0;
      for (final td in transfersData as List) {
        final status = td['status'] as String?;
        if (status == 'pending') pendingCount++;
        if (status == 'confirmed') confirmedCount++;
      }

      results.add({
        'branchId': branchId,
        'branchName': bDoc['name'] ?? branchId,
        'totalBalance': totalBalance,
        'balancesByCurrency': balancesByCurrency,
        'accounts': accounts,
        'pendingTransfersCount': pendingCount,
        'confirmedTransfersCount': confirmedCount,
        'totalCommissions': 0.0,
        'monthlySummary': <String, dynamic>{},
      });
    }

    return results;
  }

  Future<Map<String, dynamic>> _aggregateTransfers() async {
    final data = await _client
        .from('transfers')
        .select()
        .order('created_at', ascending: false)
        .limit(1000);

    int pending = 0, confirmed = 0, issued = 0, rejected = 0, cancelled = 0;
    double totalVolumeRaw = 0;
    final volumeByCurrency = <String, double>{};
    int totalProcessingMs = 0;
    int processedCount = 0;

    for (final t in data as List) {
      final status = t['status'] as String?;
      switch (status) {
        case 'pending':
          pending++;
          break;
        case 'confirmed':
          confirmed++;
          _addAmount(t, volumeByCurrency);
          totalVolumeRaw += (t['amount'] ?? 0).toDouble();
          final createdAt = DateTime.tryParse(t['created_at'] ?? '');
          final confirmedAt = DateTime.tryParse(t['confirmed_at'] ?? '');
          if (createdAt != null && confirmedAt != null) {
            totalProcessingMs += confirmedAt.difference(createdAt).inMilliseconds;
            processedCount++;
          }
          break;
        case 'issued':
          issued++;
          _addAmount(t, volumeByCurrency);
          totalVolumeRaw += (t['amount'] ?? 0).toDouble();
          break;
        case 'rejected':
          rejected++;
          break;
        case 'cancelled':
          cancelled++;
          break;
      }
    }

    return {
      'totalVolume': _r2(totalVolumeRaw),
      'volumeByCurrency': volumeByCurrency,
      'totalCount': pending + confirmed + issued + rejected + cancelled,
      'pendingCount': pending,
      'confirmedCount': confirmed,
      'issuedCount': issued,
      'rejectedCount': rejected,
      'cancelledCount': cancelled,
      'totalCommissions': 0.0,
      'avgProcessingMs': processedCount > 0
          ? (totalProcessingMs / processedCount).round()
          : 0,
    };
  }

  void _addAmount(Map<String, dynamic> t, Map<String, double> buckets) {
    final cur = t['currency'] as String? ?? 'USD';
    final amt = _r2((t['amount'] ?? 0).toDouble());
    buckets[cur] = _r2((buckets[cur] ?? 0) + amt);
  }

  Future<List<Map<String, dynamic>>> _aggregateCurrency() async {
    final ratesData = await _client
        .from('exchange_rates')
        .select()
        .order('effective_at', ascending: false)
        .limit(200);

    final pairMap = <String, Map<String, dynamic>>{};

    for (final r in ratesData as List) {
      final pair = '${r['from_currency']}/${r['to_currency']}';
      final dateStr = r['effective_at'] ?? '';

      if (!pairMap.containsKey(pair)) {
        pairMap[pair] = {
          'pair': pair,
          'latestRate': (r['rate'] ?? 0).toDouble(),
          'rateHistory': <Map<String, dynamic>>[],
          'conversionVolume': 0.0,
        };
      }
      (pairMap[pair]!['rateHistory'] as List).add({'rate': r['rate'], 'date': dateStr});
    }

    return pairMap.values.toList();
  }

  Future<Map<String, dynamic>> _aggregateTreasury({
    bool excludeCounterpartyAccounts = false,
  }) async {
    final balancesData = await _client.from('account_balances').select();

    Set<String> transitAccountIds = {};
    if (excludeCounterpartyAccounts) {
      final accountsData = await _client
          .from('branch_accounts')
          .select('id')
          .eq('type', 'transit');
      transitAccountIds = (accountsData as List).map((d) => d['id'] as String).toSet();
    }

    final totalLiquidity = <String, double>{};
    for (final doc in balancesData as List) {
      if (excludeCounterpartyAccounts && transitAccountIds.contains(doc['account_id'])) continue;
      final cur = doc['currency'] as String? ?? 'UNK';
      final bal = _r2((doc['balance'] ?? 0).toDouble());
      totalLiquidity[cur] = _r2((totalLiquidity[cur] ?? 0) + bal);
    }

    return {
      'totalLiquidity': totalLiquidity,
      'capitalByBranchByCurrency': <String, Map<String, double>>{},
      'pendingLockedByCurrency': <String, double>{},
      'largeTransfers': <Map<String, dynamic>>[],
    };
  }
}
