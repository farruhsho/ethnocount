import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/client.dart';

abstract class ClientRepository {
  Stream<List<Client>> watchClients();

  /// Stream of all client balances. The clients list page uses this to
  /// show the real balance amount on each row.
  Stream<List<ClientBalance>> watchAllClientBalances();

  Future<Either<Failure, Client>> getClient(String clientId);

  Future<Either<Failure, ClientBalance?>> getClientBalance(String clientId);

  Stream<List<ClientTransaction>> watchClientTransactions(
    String clientId, {
    int limit,
  });

  Future<Either<Failure, String>> createClient({
    required String name,
    required String phone,
    required String country,
    required String currency,
    required String branchId,
  });

  Future<Either<Failure, void>> depositClient({
    required String clientId,
    required double amount,
    String? description,
    String? currency,
  });

  Future<Either<Failure, void>> debitClient({
    required String clientId,
    required double amount,
    String? description,
    String? currency,
  });
}
