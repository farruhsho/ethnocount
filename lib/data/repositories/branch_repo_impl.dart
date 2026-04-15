import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/core/network/connectivity_service.dart';
import 'package:ethnocount/data/datasources/remote/branch_remote_ds.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';

class BranchRepoImpl implements BranchRepository {
  final BranchRemoteDataSource _remoteDs;
  final ConnectivityService _connectivity;

  BranchRepoImpl(this._remoteDs, this._connectivity);

  @override
  Stream<List<Branch>> watchBranches() => _remoteDs.watchBranches();

  @override
  Future<Either<Failure, Branch>> getBranch(String branchId) async {
    try {
      final branch = await _remoteDs.getBranch(branchId);
      return Right(branch);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Stream<List<BranchAccount>> watchBranchAccounts(String branchId) =>
      _remoteDs.watchBranchAccounts(branchId);

  @override
  Future<Either<Failure, BranchAccount>> getBranchAccount(
      String accountId) async {
    try {
      final account = await _remoteDs.getBranchAccount(accountId);
      return Right(account);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Branch>> createBranch({
    required String name,
    required String code,
    required String baseCurrency,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      final id = await _remoteDs.createBranch(
        name: name,
        code: code,
        baseCurrency: baseCurrency,
      );
      final branch = await _remoteDs.getBranch(id);
      return Right(branch);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> updateBranch({
    required String branchId,
    String? name,
    String? code,
    String? baseCurrency,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      await _remoteDs.updateBranch(
        branchId: branchId,
        name: name,
        code: code,
        baseCurrency: baseCurrency,
      );
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, BranchAccount>> createBranchAccount({
    required String branchId,
    required String name,
    required AccountType type,
    required String currency,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      final id = await _remoteDs.createBranchAccount(
        branchId: branchId,
        name: name,
        type: type,
        currency: currency,
      );
      final account = await _remoteDs.getBranchAccount(id);
      return Right(account);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> updateBranchAccount({
    required String accountId,
    String? name,
    AccountType? type,
    String? currency,
  }) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      await _remoteDs.updateBranchAccount(
        accountId: accountId,
        name: name,
        type: type,
        currency: currency,
      );
      return const Right(null);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }
}
