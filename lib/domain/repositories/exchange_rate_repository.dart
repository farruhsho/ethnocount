import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/exchange_rate.dart';

abstract class ExchangeRateRepository {
  Stream<List<ExchangeRate>> watchRates({
    String? fromCurrency,
    String? toCurrency,
    int limit = 50,
  });

  Future<Either<Failure, ExchangeRate?>> getLatestRate(String from, String to);

  Future<Either<Failure, Map<String, dynamic>>> setRate({
    required String fromCurrency,
    required String toCurrency,
    required double rate,
  });

  Future<Either<Failure, List<String>>> getAvailableCurrencies();
}
