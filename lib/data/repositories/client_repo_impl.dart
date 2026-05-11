import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/core/network/callable_functions.dart';
import 'package:ethnocount/data/datasources/remote/client_remote_ds.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/domain/repositories/client_repository.dart';

class ClientRepoImpl implements ClientRepository {
  final ClientRemoteDataSource _remoteDs;

  ClientRepoImpl(this._remoteDs);

  @override
  Stream<List<Client>> watchClients() => _remoteDs.watchClients();

  @override
  Stream<List<ClientBalance>> watchAllClientBalances() =>
      _remoteDs.watchAllClientBalances();

  @override
  Future<Either<Failure, Client>> getClient(String clientId) async {
    try {
      return Right(await _remoteDs.getClient(clientId));
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, ClientBalance?>> getClientBalance(
      String clientId) async {
    try {
      return Right(await _remoteDs.getClientBalance(clientId));
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Stream<List<ClientTransaction>> watchClientTransactions(
    String clientId, {
    int limit = 50,
  }) =>
      _remoteDs.watchClientTransactions(clientId, limit: limit);

  @override
  Future<Either<Failure, String>> createClient({
    required String name,
    required String phone,
    required String country,
    required String currency,
    required String branchId,
  }) async {
    try {
      final result = await _remoteDs.createClient(
        name: name,
        phone: phone,
        country: country,
        currency: currency,
        branchId: branchId,
      );
      if (result['success'] == true) {
        return Right(result['clientId'] as String);
      }
      return Left(ServerFailure(result['error']?.toString() ?? 'Failed'));
    } on CallableFunctionsException catch (e) {
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> depositClient({
    required String clientId,
    required double amount,
    String? description,
    String? currency,
  }) async {
    try {
      final result = await _remoteDs.depositClient(
        clientId: clientId,
        amount: amount,
        description: description,
        currency: currency,
      );
      if (result['success'] == true) return const Right(null);
      return Left(ServerFailure(result['error']?.toString() ?? 'Failed'));
    } on CallableFunctionsException catch (e) {
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> debitClient({
    required String clientId,
    required double amount,
    String? description,
    String? currency,
  }) async {
    try {
      final result = await _remoteDs.debitClient(
        clientId: clientId,
        amount: amount,
        description: description,
        currency: currency,
      );
      if (result['success'] == true) return const Right(null);
      return Left(ServerFailure(result['error']?.toString() ?? 'Failed'));
    } on CallableFunctionsException catch (e) {
      if (e.code == 'failed-precondition') {
        return const Left(ServerFailure('Insufficient client balance'));
      }
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, ClientConversionResult>> convertClientCurrency({
    required String clientId,
    required String fromCurrency,
    required String toCurrency,
    required double amount,
    required double rate,
    String? description,
  }) async {
    try {
      final result = await _remoteDs.convertClientCurrency(
        clientId: clientId,
        fromCurrency: fromCurrency,
        toCurrency: toCurrency,
        amount: amount,
        rate: rate,
        description: description,
      );
      if (result['success'] == true) {
        return Right(ClientConversionResult(
          conversionId: result['conversionId']?.toString() ?? '',
          fromCurrency: fromCurrency,
          toCurrency: toCurrency,
          fromAmount: (result['fromAmount'] as num?)?.toDouble() ?? amount,
          toAmount: (result['toAmount'] as num?)?.toDouble() ?? (amount * rate),
          rate: (result['rate'] as num?)?.toDouble() ?? rate,
        ));
      }
      return Left(ServerFailure(result['error']?.toString() ?? 'Failed'));
    } on CallableFunctionsException catch (e) {
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> setTelegramChatId({
    required String clientId,
    required String? chatId,
  }) async {
    try {
      await _remoteDs.setTelegramChatId(clientId: clientId, chatId: chatId);
      return const Right(null);
    } on CallableFunctionsException catch (e) {
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> sendTelegramTest({
    required String clientId,
  }) async {
    try {
      await _remoteDs.sendTelegramTest(clientId: clientId);
      return const Right(null);
    } on CallableFunctionsException catch (e) {
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }
}
