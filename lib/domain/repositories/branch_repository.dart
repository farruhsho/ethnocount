import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Repository for branch and branch-account operations.
abstract class BranchRepository {
  /// Stream of all active branches.
  Stream<List<Branch>> watchBranches();

  /// Get a single branch by ID.
  Future<Either<Failure, Branch>> getBranch(String branchId);

  /// Stream of accounts for a branch.
  Stream<List<BranchAccount>> watchBranchAccounts(String branchId);

  /// Get a single branch account.
  Future<Either<Failure, BranchAccount>> getBranchAccount(String accountId);

  /// Create a new branch (admin only).
  Future<Either<Failure, Branch>> createBranch({
    required String name,
    required String code,
    required String baseCurrency,
  });

  /// Update a branch (name, code, baseCurrency).
  Future<Either<Failure, void>> updateBranch({
    required String branchId,
    String? name,
    String? code,
    String? baseCurrency,
  });

  /// Create a new account within a branch.
  Future<Either<Failure, BranchAccount>> createBranchAccount({
    required String branchId,
    required String name,
    required AccountType type,
    required String currency,
  });

  /// Update an existing branch account.
  Future<Either<Failure, void>> updateBranchAccount({
    required String accountId,
    String? name,
    AccountType? type,
    String? currency,
  });
}
