import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';

/// Watch all active branches.
class WatchBranchesUseCase {
  final BranchRepository _repository;

  WatchBranchesUseCase(this._repository);

  Stream<List<Branch>> call() => _repository.watchBranches();
}
