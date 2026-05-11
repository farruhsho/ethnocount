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

  /// Create a new branch (creator only — via admin RPC).
  Future<Either<Failure, Branch>> createBranch({
    required String name,
    required String code,
    required String baseCurrency,
    List<String>? supportedCurrencies,
    String? address,
    String? phone,
    String? notes,
    int sortOrder,
  });

  /// Update a branch. Changes to [code] are additionally recorded in
  /// `branch_code_history`. Pass [supportedCurrencies]=null to leave the field
  /// untouched, or an empty list to reset it (server interprets as "all").
  Future<Either<Failure, void>> updateBranch({
    required String branchId,
    String? name,
    String? code,
    String? baseCurrency,
    List<String>? supportedCurrencies,
    String? address,
    String? phone,
    String? notes,
    int? sortOrder,
    String? codeChangeReason,
  });

  /// Archive / unarchive a branch (soft delete).
  Future<Either<Failure, void>> archiveBranch({
    required String branchId,
    required bool archive,
    String? reason,
  });

  /// Create a new account within a branch. Card fields are optional and
  /// only meaningful for [AccountType.card].
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
    int sortOrder,
  });

  /// Update an existing branch account. Pass [clearCardNumber] = true to
  /// explicitly wipe the stored PAN.
  Future<Either<Failure, void>> updateBranchAccount({
    required String accountId,
    String? name,
    AccountType? type,
    String? currency,
    String? cardNumber,
    bool clearCardNumber,
    String? cardholderName,
    String? bankName,
    int? expiryMonth,
    int? expiryYear,
    String? notes,
    int? sortOrder,
  });

  /// Archive / unarchive a branch account.
  Future<Either<Failure, void>> archiveBranchAccount({
    required String accountId,
    required bool archive,
  });

  /// Bulk-reorder branch accounts. `order` is a list of
  /// `{accountId: String, sortOrder: int}` maps.
  Future<Either<Failure, void>> reorderBranchAccounts({
    required String branchId,
    required List<Map<String, dynamic>> order,
  });
}
