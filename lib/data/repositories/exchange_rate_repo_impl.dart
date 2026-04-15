import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/data/datasources/remote/exchange_rate_remote_ds.dart';
import 'package:ethnocount/domain/entities/exchange_rate.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';

class ExchangeRateRepoImpl implements ExchangeRateRepository {
  final ExchangeRateRemoteDataSource _remote;

  ExchangeRateRepoImpl(this._remote);

  @override
  Stream<List<ExchangeRate>> watchRates({
    String? fromCurrency,
    String? toCurrency,
    int limit = 50,
  }) {
    return _remote.watchRates(
      fromCurrency: fromCurrency,
      toCurrency: toCurrency,
      limit: limit,
    );
  }

  @override
  Future<Either<Failure, ExchangeRate?>> getLatestRate(String from, String to) async {
    try {
      final rate = await _remote.getLatestRate(from, to);
      return Right(rate);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Map<String, dynamic>>> setRate({
    required String fromCurrency,
    required String toCurrency,
    required double rate,
  }) async {
    try {
      final result = await _remote.setRate(
        fromCurrency: fromCurrency,
        toCurrency: toCurrency,
        rate: rate,
      );
      return Right(result);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<String>>> getAvailableCurrencies() async {
    try {
      final list = await _remote.getAvailableCurrencies();
      return Right(list);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }
}
