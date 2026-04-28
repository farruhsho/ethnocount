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

  Future<Either<Failure, T>> _guarded<T>(Future<T> Function() op) async {
    try {
      if (!await _connectivity.isConnected) {
        return const Left(OfflineFailure());
      }
      final result = await op();
      return Right(result);
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Branch>> createBranch({
    required String name,
    required String code,
    required String baseCurrency,
    String? address,
    String? phone,
    String? notes,
    int sortOrder = 0,
  }) =>
      _guarded(() async {
        final id = await _remoteDs.createBranch(
          name: name,
          code: code,
          baseCurrency: baseCurrency,
          address: address,
          phone: phone,
          notes: notes,
          sortOrder: sortOrder,
        );
        return await _remoteDs.getBranch(id);
      });

  @override
  Future<Either<Failure, void>> updateBranch({
    required String branchId,
    String? name,
    String? code,
    String? baseCurrency,
    String? address,
    String? phone,
    String? notes,
    int? sortOrder,
    String? codeChangeReason,
  }) =>
      _guarded(() => _remoteDs.updateBranch(
            branchId: branchId,
            name: name,
            code: code,
            baseCurrency: baseCurrency,
            address: address,
            phone: phone,
            notes: notes,
            sortOrder: sortOrder,
            codeChangeReason: codeChangeReason,
          ));

  @override
  Future<Either<Failure, void>> archiveBranch({
    required String branchId,
    required bool archive,
    String? reason,
  }) =>
      _guarded(() => _remoteDs.archiveBranch(
            branchId: branchId,
            archive: archive,
            reason: reason,
          ));

  @override
  Future<Either<Failure, BranchAccount>> createBranchAccount({
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
  }) =>
      _guarded(() async {
        final id = await _remoteDs.createBranchAccount(
          branchId: branchId,
          name: name,
          type: type,
          currency: currency,
          cardNumber: cardNumber,
          cardholderName: cardholderName,
          bankName: bankName,
          expiryMonth: expiryMonth,
          expiryYear: expiryYear,
          notes: notes,
          sortOrder: sortOrder,
        );
        return await _remoteDs.getBranchAccount(id);
      });

  @override
  Future<Either<Failure, void>> updateBranchAccount({
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
  }) =>
      _guarded(() => _remoteDs.updateBranchAccount(
            accountId: accountId,
            name: name,
            type: type,
            currency: currency,
            cardNumber: cardNumber,
            clearCardNumber: clearCardNumber,
            cardholderName: cardholderName,
            bankName: bankName,
            expiryMonth: expiryMonth,
            expiryYear: expiryYear,
            notes: notes,
            sortOrder: sortOrder,
          ));

  @override
  Future<Either<Failure, void>> archiveBranchAccount({
    required String accountId,
    required bool archive,
  }) =>
      _guarded(() => _remoteDs.archiveBranchAccount(
            accountId: accountId,
            archive: archive,
          ));

  @override
  Future<Either<Failure, void>> reorderBranchAccounts({
    required String branchId,
    required List<Map<String, dynamic>> order,
  }) =>
      _guarded(() => _remoteDs.reorderBranchAccounts(
            branchId: branchId,
            order: order,
          ));
}
