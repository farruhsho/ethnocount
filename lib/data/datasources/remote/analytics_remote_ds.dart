import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/domain/entities/commission_profit.dart';

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
    // ⚠️ ВАЖНО: раньше тут был N+1 — для каждого филиала отдельные
    // запросы к account_balances и transfers. На большом числе филиалов
    // (и на Windows-клиенте) это переполняло стек сокетов и валилось как
    // «Превышен таймаут семафора». Сейчас — 3 параллельных батч-запроса,
    // группировка по branch_id выполняется на клиенте.
    final branchesFuture =
        _client.from('branches').select().timeout(_kTimeout);
    final balancesFuture =
        _client.from('account_balances').select().timeout(_kTimeout);
    final transfersFuture = _client
        .from('transfers')
        .select('status, from_branch_id')
        .order('created_at', ascending: false)
        .limit(5000)
        .timeout(_kTimeout);
    final transitFuture = excludeCounterpartyAccounts
        ? _client
            .from('branch_accounts')
            .select('id')
            .eq('type', 'transit')
            .timeout(_kTimeout)
        : Future<List<dynamic>>.value(const []);

    final results0 = await Future.wait(
      <Future<dynamic>>[
        branchesFuture,
        balancesFuture,
        transfersFuture,
        transitFuture,
      ],
    );
    final branchesData = results0[0] as List;
    final balancesData = results0[1] as List;
    final transfersData = results0[2] as List;
    final transitData = results0[3] as List;

    final transitAccountIds = <String>{
      for (final d in transitData) d['id'] as String,
    };

    // Группируем балансы по branch_id один раз.
    final balancesByBranch = <String, List<Map<String, dynamic>>>{};
    for (final bd in balancesData) {
      final m = Map<String, dynamic>.from(bd as Map);
      final bId = m['branch_id'] as String?;
      if (bId == null) continue;
      balancesByBranch.putIfAbsent(bId, () => []).add(m);
    }

    // Группируем счётчики переводов по branch_id.
    final pendingByBranch = <String, int>{};
    final confirmedByBranch = <String, int>{};
    for (final td in transfersData) {
      final m = Map<String, dynamic>.from(td as Map);
      final bId = m['from_branch_id'] as String?;
      if (bId == null) continue;
      final status = m['status'] as String?;
      if (status == 'created' || status == 'pending') {
        pendingByBranch[bId] = (pendingByBranch[bId] ?? 0) + 1;
      } else if (status == 'toDelivery' || status == 'confirmed') {
        confirmedByBranch[bId] = (confirmedByBranch[bId] ?? 0) + 1;
      }
    }

    final results = <Map<String, dynamic>>[];
    for (final bDoc in branchesData) {
      final branchId = bDoc['id'] as String;
      final accounts = <String, dynamic>{};
      final balancesByCurrency = <String, double>{};
      for (final bd in balancesByBranch[branchId] ?? const []) {
        if (excludeCounterpartyAccounts &&
            transitAccountIds.contains(bd['account_id'])) {
          continue;
        }
        final cur = bd['currency'] as String? ?? 'UNK';
        final bal = _r2((bd['balance'] ?? 0).toDouble());
        accounts[bd['account_id'] as String] =
            {'balance': bal, 'currency': cur};
        balancesByCurrency[cur] = _r2((balancesByCurrency[cur] ?? 0) + bal);
      }
      final curKeys = balancesByCurrency.keys.toList();
      final totalBalance =
          curKeys.length == 1 ? balancesByCurrency[curKeys.first]! : 0.0;

      results.add({
        'branchId': branchId,
        'branchName': bDoc['name'] ?? branchId,
        'totalBalance': totalBalance,
        'balancesByCurrency': balancesByCurrency,
        'accounts': accounts,
        'pendingTransfersCount': pendingByBranch[branchId] ?? 0,
        'confirmedTransfersCount': confirmedByBranch[branchId] ?? 0,
        'totalCommissions': 0.0,
        'monthlySummary': <String, dynamic>{},
      });
    }
    return results;
  }

  /// 20 сек на один HTTP-запрос. Меньше — на медленной сети будем падать,
  /// больше — пользователь смотрит на бесконечный лоадер.
  static const Duration _kTimeout = Duration(seconds: 20);

  Future<Map<String, dynamic>> _aggregateTransfers() async {
    final data = await _client
        .from('transfers')
        .select()
        .order('created_at', ascending: false)
        .limit(1000)
        .timeout(_kTimeout);

    int created = 0, toDelivery = 0, withCourier = 0, delivered = 0;
    double totalVolumeRaw = 0;
    final volumeByCurrency = <String, double>{};
    int totalProcessingMs = 0;
    int processedCount = 0;

    for (final t in data as List) {
      final status = t['status'] as String?;
      switch (status) {
        case 'created':
        case 'pending':
          created++;
          break;
        case 'toDelivery':
        case 'confirmed':
          toDelivery++;
          _addAmount(t, volumeByCurrency);
          totalVolumeRaw += (t['amount'] ?? 0).toDouble();
          final createdAt = DateTime.tryParse(t['created_at'] ?? '');
          final confirmedAt = DateTime.tryParse(t['confirmed_at'] ?? '');
          if (createdAt != null && confirmedAt != null) {
            totalProcessingMs += confirmedAt.difference(createdAt).inMilliseconds;
            processedCount++;
          }
          break;
        case 'withCourier':
          withCourier++;
          _addAmount(t, volumeByCurrency);
          totalVolumeRaw += (t['amount'] ?? 0).toDouble();
          break;
        case 'delivered':
        case 'issued':
          delivered++;
          _addAmount(t, volumeByCurrency);
          totalVolumeRaw += (t['amount'] ?? 0).toDouble();
          break;
      }
    }

    return {
      'totalVolume': _r2(totalVolumeRaw),
      'volumeByCurrency': volumeByCurrency,
      'totalCount': created + toDelivery + withCourier + delivered,
      'pendingCount': created,
      'confirmedCount': toDelivery,
      'issuedCount': delivered,
      'withCourierCount': withCourier,
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
        .limit(200)
        .timeout(_kTimeout);

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
    // Параллельно: balances + (опционально) transit-accounts. Никаких циклов.
    final balancesFuture =
        _client.from('account_balances').select().timeout(_kTimeout);
    final transitFuture = excludeCounterpartyAccounts
        ? _client
            .from('branch_accounts')
            .select('id')
            .eq('type', 'transit')
            .timeout(_kTimeout)
        : Future<List<dynamic>>.value(const []);
    final results = await Future.wait(<Future<dynamic>>[
      balancesFuture,
      transitFuture,
    ]);
    final balancesData = results[0] as List;
    final transitAccountIds = <String>{
      for (final d in results[1] as List) d['id'] as String,
    };

    final totalLiquidity = <String, double>{};
    for (final doc in balancesData) {
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

  /// Fetches commission profit aggregated by (branch × currency) and the
  /// per-currency totals for the same period. Calls the two RPCs added in
  /// migration 050.
  ///
  /// `start` / `end` are inclusive-exclusive — `created_at >= start AND < end`.
  /// Pass `null` to skip a bound. `branchIds` constrains visibility for
  /// accountants (creator/director pass `null` for all branches).
  Future<CommissionProfitReport> fetchCommissionProfit({
    DateTime? start,
    DateTime? end,
    List<String>? branchIds,
  }) async {
    final params = <String, dynamic>{
      'p_start': start?.toUtc().toIso8601String(),
      'p_end': end?.toUtc().toIso8601String(),
      'p_branch_ids': branchIds,
    };

    final results = await Future.wait(<Future<dynamic>>[
      _client.rpc('commission_profit_by_branch', params: params),
      _client.rpc('commission_profit_totals', params: params),
    ]);

    final rowsRaw = (results[0] as List?) ?? const [];
    final totalsRaw = (results[1] as List?) ?? const [];

    return CommissionProfitReport(
      rows: rowsRaw
          .map((m) =>
              CommissionProfitRow.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      totals: totalsRaw
          .map((m) => CommissionProfitTotal.fromMap(
              Map<String, dynamic>.from(m as Map)))
          .toList(),
      start: start,
      end: end,
    );
  }
}
