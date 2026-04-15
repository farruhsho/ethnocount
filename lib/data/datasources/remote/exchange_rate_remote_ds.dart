import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/exchange_rate.dart';

class ExchangeRateRemoteDataSource {
  final SupabaseClient _client;

  ExchangeRateRemoteDataSource(this._client);

  Stream<List<ExchangeRate>> watchRates({
    String? fromCurrency,
    String? toCurrency,
    int limit = 50,
  }) {
    final controller = StreamController<List<ExchangeRate>>.broadcast();

    _fetchRates(fromCurrency: fromCurrency, toCurrency: toCurrency, limit: limit).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('exchange_rates_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'exchange_rates',
          callback: (payload) {
            _fetchRates(fromCurrency: fromCurrency, toCurrency: toCurrency, limit: limit).then((list) {
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

  Future<List<ExchangeRate>> _fetchRates({
    String? fromCurrency,
    String? toCurrency,
    int limit = 50,
  }) async {
    var query = _client.from('exchange_rates').select();
    if (fromCurrency != null) query = query.eq('from_currency', fromCurrency);
    if (toCurrency != null) query = query.eq('to_currency', toCurrency);
    final data = await query.order('effective_at', ascending: false).limit(limit);
    return (data as List).map((e) => _mapRate(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<ExchangeRate?> getLatestRate(String from, String to) async {
    final data = await _client
        .from('exchange_rates')
        .select()
        .eq('from_currency', from)
        .eq('to_currency', to)
        .order('effective_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    return _mapRate(data);
  }

  Future<Map<String, dynamic>> setRate({
    required String fromCurrency,
    required String toCurrency,
    required double rate,
  }) async {
    final result = await _client.rpc('set_exchange_rate', params: {
      'p_from_currency': fromCurrency,
      'p_to_currency': toCurrency,
      'p_rate': rate,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<String>> getAvailableCurrencies() async {
    final data = await _client
        .from('exchange_rates')
        .select('from_currency, to_currency')
        .order('effective_at', ascending: false)
        .limit(100);

    final currencies = <String>{};
    for (final row in data as List) {
      currencies.add(row['from_currency'] as String);
      currencies.add(row['to_currency'] as String);
    }

    if (currencies.isEmpty) {
      return ['USD', 'USDT', 'RUB', 'UZS', 'KGS', 'TRY', 'KZT', 'TJS', 'CNY', 'AED'];
    }
    return currencies.toList()..sort();
  }

  ExchangeRate _mapRate(Map<String, dynamic> data) {
    return ExchangeRate(
      id: data['id'] ?? '',
      fromCurrency: data['from_currency'] ?? '',
      toCurrency: data['to_currency'] ?? '',
      rate: (data['rate'] ?? 0).toDouble(),
      setBy: data['set_by'] ?? '',
      effectiveAt: DateTime.tryParse(data['effective_at'] ?? '') ?? DateTime.now(),
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
